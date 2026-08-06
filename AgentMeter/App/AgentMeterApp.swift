import AppKit
import AgentMeterCore
import ServiceManagement
import SwiftUI
import UserNotifications

@main
struct AgentMeterApp: App {
    @NSApplicationDelegateAdaptor(AgentMeterAppDelegate.self) private var appDelegate

    var body: some Scene {
        Settings {
            SettingsView(model: appDelegate.model)
        }
    }
}

@MainActor
private final class AgentMeterAppDelegate: NSObject, NSApplicationDelegate {
    let model = UsageViewModel()
    private var statusBarController: StatusBarController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusBarController = StatusBarController(model: model)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}

@MainActor
private final class StatusBarController: NSObject {
    private let model: UsageViewModel
    private let statusItem: NSStatusItem
    private let popover = NSPopover()
    private var labelHostingView: NSHostingView<StatusBarLabel>?

    init(model: UsageViewModel) {
        self.model = model
        statusItem = NSStatusBar.system.statusItem(
            withLength: StatusBarLabel.preferredWidth(agentCount: model.agents.count)
        )
        super.init()

        let panel = UsagePanel(model: model)
        popover.behavior = .transient
        popover.animates = true
        popover.contentSize = NSSize(width: 440, height: 620)
        popover.contentViewController = NSHostingController(rootView: panel)

        guard let button = statusItem.button else { return }
        button.title = ""
        button.image = nil
        button.target = self
        button.action = #selector(togglePopover(_:))
        button.sendAction(on: [.leftMouseUp])

        let hostingView = NSHostingView(rootView: StatusBarLabel(model: model))
        hostingView.translatesAutoresizingMaskIntoConstraints = false
        button.addSubview(hostingView)
        NSLayoutConstraint.activate([
            hostingView.leadingAnchor.constraint(equalTo: button.leadingAnchor),
            hostingView.trailingAnchor.constraint(equalTo: button.trailingAnchor),
            hostingView.topAnchor.constraint(equalTo: button.topAnchor),
            hostingView.bottomAnchor.constraint(equalTo: button.bottomAnchor),
        ])
        labelHostingView = hostingView
    }

    @objc private func togglePopover(_ sender: NSStatusBarButton) {
        if popover.isShown {
            popover.performClose(sender)
        } else {
            popover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }
}

@MainActor
final class UsageViewModel: ObservableObject {
    enum AgentState {
        case loading
        case fresh(UsageSnapshot)
        case stale(UsageSnapshot)
        case signedOut
        case unsupported
        case error(String)

        var snapshot: UsageSnapshot? {
            switch self {
            case let .fresh(snapshot), let .stale(snapshot): snapshot
            default: nil
            }
        }
    }

    struct AgentDisplay: Identifiable {
        let id: String
        let name: String
        let menuName: String
        let symbol: String
        let cliName: String
        var state: AgentState
        var isInstalled: Bool
    }

    @Published private(set) var agents: [AgentDisplay]
    @Published private(set) var refreshingIDs: Set<String> = []
    @Published var showUsedPercent: Bool
    @Published var refreshInterval: RefreshInterval
    @Published var appearance: AppearanceChoice
    @Published var notificationsEnabled: Bool
    @Published var notificationThreshold: NotificationThreshold
    @Published private(set) var notificationStatus = "未確認"
    @Published private(set) var launchAtLoginStatus = "未設定"
    @Published var launchAtLoginEnabled = false

    private let defaults = UserDefaults.standard
    private var providers: [String: any UsageProvider] = [:]
    private var caches: [String: UsageCache] = [:]
    private var notificationPolicies: [String: UsageNotificationPolicy] = [:]
    private var refreshTask: Task<Void, Never>?
    private var lifecycleObservers: [NSObjectProtocol] = []

    init() {
        showUsedPercent = defaults.bool(forKey: "showUsedPercent")
        refreshInterval = RefreshInterval(rawValue: defaults.string(forKey: "refreshInterval") ?? "5") ?? .fiveMinutes
        appearance = AppearanceChoice(rawValue: defaults.string(forKey: "appearance") ?? "system") ?? .system
        notificationsEnabled = defaults.bool(forKey: "notificationsEnabled")
        notificationThreshold = NotificationThreshold(rawValue: defaults.integer(forKey: "notificationThreshold")) ?? .twenty

        let codexURL = Self.findCLI(named: "codex")
        let antigravityURL = Self.findCLI(named: "agy")
        agents = [
            AgentDisplay(id: "codex", name: "Codex", menuName: "Codex", symbol: "chevron.left.forwardslash.chevron.right", cliName: "codex", state: codexURL == nil ? .error("Codex CLI が見つかりません。") : .loading, isInstalled: codexURL != nil),
            AgentDisplay(id: "antigravity", name: "Antigravity", menuName: "AGY", symbol: "sparkles", cliName: "agy", state: antigravityURL == nil ? .error("Antigravity CLI（agy）が見つかりません。") : .loading, isInstalled: antigravityURL != nil),
        ]

        let support = Self.applicationSupportURL()
        if let codexURL { providers["codex"] = AppServerProvider(executableURL: codexURL) }
        if let antigravityURL {
            providers["antigravity"] = AntigravityCLIProvider(
                executableURL: antigravityURL,
                workingDirectoryURL: support.appendingPathComponent("AntigravityWorkspace", isDirectory: true)
            )
        }
        for agent in agents {
            caches[agent.id] = UsageCache(fileURL: support.appendingPathComponent("usage-\(agent.id).json"))
            notificationPolicies[agent.id] = UsageNotificationPolicy(threshold: notificationThreshold.rawValue)
        }

        observeSystemEvents()
        refreshNotificationStatus()
        refreshLaunchAtLoginStatus()
        scheduleRefresh()
        Task { [weak self] in
            await self?.restoreCachedSnapshots()
            self?.refreshAll()
        }
    }

    var menuAccessibilitySummary: String {
        agents.map { agent in
            let amounts = agent.state.snapshot.map(Self.remainingValues(in:)) ?? []
            let value = amounts.prefix(2).map { "\($0)%" }.joined(separator: "、")
            return "\(agent.name) \(value.isEmpty ? "取得待ち" : value)"
        }.joined(separator: "。")
    }

    var isRefreshing: Bool { !refreshingIDs.isEmpty }

    func refreshAll() {
        for agent in agents where agent.isInstalled { refresh(agentID: agent.id) }
    }

    func refresh(agentID: String) {
        guard !refreshingIDs.contains(agentID), let provider = providers[agentID] else { return }
        refreshingIDs.insert(agentID)
        if state(for: agentID)?.snapshot == nil { setState(.loading, for: agentID) }

        Task { @MainActor [weak self] in
            guard let self else { return }
            defer { refreshingIDs.remove(agentID) }
            do {
                let snapshot = try await provider.fetchSnapshot()
                setState(.fresh(snapshot), for: agentID)
                if let cache = caches[agentID] { try? await cache.save(snapshot) }
                sendNotifications(for: snapshot, agentID: agentID)
            } catch {
                receive(error: error, agentID: agentID)
            }
        }
    }

    func saveSettings() {
        defaults.set(showUsedPercent, forKey: "showUsedPercent")
        defaults.set(refreshInterval.rawValue, forKey: "refreshInterval")
        defaults.set(appearance.rawValue, forKey: "appearance")
        defaults.set(notificationsEnabled, forKey: "notificationsEnabled")
        defaults.set(notificationThreshold.rawValue, forKey: "notificationThreshold")
        for agent in agents {
            notificationPolicies[agent.id] = UsageNotificationPolicy(threshold: notificationThreshold.rawValue)
        }
        scheduleRefresh()
    }

    func applyNotificationPreference() {
        saveSettings()
        guard notificationsEnabled else { return }
        notificationStatus = "権限を確認中"
        SystemNotificationService.shared.requestAuthorization()
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() }
            else { try SMAppService.mainApp.unregister() }
        } catch {
            launchAtLoginStatus = "変更できませんでした: \(error.localizedDescription)"
        }
        refreshLaunchAtLoginStatus()
    }

    private func restoreCachedSnapshots() async {
        for agent in agents {
            guard let cache = caches[agent.id],
                  let snapshot = try? await cache.load(),
                  UsageFreshness.status(of: snapshot) != .expired else { continue }
            setState(.stale(snapshot), for: agent.id)
        }
    }

    private func receive(error: Error, agentID: String) {
        if let snapshot = state(for: agentID)?.snapshot {
            setState(.stale(snapshot), for: agentID)
            return
        }
        if case UsageProviderError.signedOut = error {
            setState(.signedOut, for: agentID)
        } else if case UsageProviderError.unsupportedResponse = error {
            setState(.unsupported, for: agentID)
        } else {
            setState(.error(error.localizedDescription), for: agentID)
        }
    }

    private func sendNotifications(for snapshot: UsageSnapshot, agentID: String) {
        guard notificationsEnabled,
              var policy = notificationPolicies[agentID],
              let agentName = agents.first(where: { $0.id == agentID })?.name else { return }
        for alert in policy.alerts(for: snapshot) {
            SystemNotificationService.shared.deliver(alert, agentName: agentName)
        }
        notificationPolicies[agentID] = policy
    }

    private func state(for agentID: String) -> AgentState? {
        agents.first(where: { $0.id == agentID })?.state
    }

    private func setState(_ state: AgentState, for agentID: String) {
        guard let index = agents.firstIndex(where: { $0.id == agentID }) else { return }
        agents[index].state = state
    }

    private func scheduleRefresh() {
        refreshTask?.cancel()
        guard let seconds = refreshInterval.seconds else { return }
        refreshTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(seconds))
                guard !Task.isCancelled else { return }
                self?.refreshAll()
            }
        }
    }

    private func observeSystemEvents() {
        let center = NotificationCenter.default
        lifecycleObservers = [
            center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.refreshAll() }
            },
            center.addObserver(forName: NSNotification.Name.NSSystemTimeZoneDidChange, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.refreshAll() }
            },
        ]
    }

    private func refreshNotificationStatus() {
        notificationStatus = notificationsEnabled ? "有効（macOSの通知設定を使用）" : "無効"
    }

    private func refreshLaunchAtLoginStatus() {
        launchAtLoginEnabled = SMAppService.mainApp.status == .enabled
        launchAtLoginStatus = switch SMAppService.mainApp.status {
        case .enabled: "有効"
        case .notRegistered: "無効"
        case .requiresApproval: "システム設定で承認が必要"
        case .notFound: "アプリケーションが見つかりません"
        @unknown default: "不明"
        }
    }

    private static func applicationSupportURL() -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("AgentMeter", isDirectory: true)
    }

    private static func findCLI(named name: String) -> URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let pathEntries = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map(String.init)
        let candidates = pathEntries.map { URL(fileURLWithPath: $0).appendingPathComponent(name) }
            + ["/opt/homebrew/bin/\(name)", "/usr/local/bin/\(name)", "\(home)/.local/bin/\(name)"].map(URL.init(fileURLWithPath:))
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    fileprivate static func minimumRemaining(in snapshot: UsageSnapshot) -> Int {
        let values = remainingValues(in: snapshot)
        return values.min() ?? 0
    }

    fileprivate static func remainingValues(in snapshot: UsageSnapshot) -> [Int] {
        snapshot.limits
            .flatMap { [$0.primary, $0.secondary].compactMap { $0?.remainingPercent } }
            .sorted()
    }
}

enum RefreshInterval: String, CaseIterable, Identifiable {
    case oneMinute = "1", fiveMinutes = "5", fifteenMinutes = "15", thirtyMinutes = "30", manual
    var id: String { rawValue }
    var title: String {
        switch self {
        case .oneMinute: "1分"
        case .fiveMinutes: "5分"
        case .fifteenMinutes: "15分"
        case .thirtyMinutes: "30分"
        case .manual: "手動"
        }
    }
    var seconds: Double? {
        switch self {
        case .oneMinute: 60
        case .fiveMinutes: 300
        case .fifteenMinutes: 900
        case .thirtyMinutes: 1800
        case .manual: nil
        }
    }
}

enum NotificationThreshold: Int, CaseIterable, Identifiable {
    case fifty = 50, twenty = 20, ten = 10, zero = 0
    var id: Int { rawValue }
    var title: String { "残量 \(rawValue)% 以下" }
}

enum AppearanceChoice: String, CaseIterable, Identifiable {
    case system, light, dark
    var id: String { rawValue }
    var title: String {
        switch self {
        case .system: "システム設定"
        case .light: "ライト"
        case .dark: "ダーク"
        }
    }
    var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }
}

@MainActor
private final class SystemNotificationService {
    static let shared = SystemNotificationService()
    private let center = UNUserNotificationCenter.current()

    func requestAuthorization() {
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    func deliver(_ alert: UsageNotificationPolicy.Alert, agentName: String) {
        let content = UNMutableNotificationContent()
        content.title = "Agent Meter · \(agentName)"
        content.body = "\(alert.limitName)の残量が\(alert.remainingPercent)%になりました。"
        content.sound = .default
        center.add(UNNotificationRequest(identifier: "\(agentName)-\(alert.id)", content: content, trigger: nil))
    }
}

private struct StatusBarLabel: View {
    @ObservedObject var model: UsageViewModel

    var body: some View {
        HStack(spacing: 5) {
            Image(nsImage: NSApplication.shared.applicationIconImage)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
                .frame(width: 18, height: 18)

            HStack(spacing: 5) {
                ForEach(columnStartIndexes, id: \.self) { startIndex in
                    VStack(spacing: 2) {
                        ForEach(agents(inColumnStartingAt: startIndex)) { agent in
                            StatusAgentBar(agent: agent)
                        }
                    }
                }
            }
        }
        .padding(.horizontal, 2)
        .frame(height: 22)
        .allowsHitTesting(false)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Agent Meter。\(model.menuAccessibilitySummary)")
    }

    static func preferredWidth(agentCount: Int) -> CGFloat {
        let columns = max(1, Int(ceil(Double(agentCount) / 2)))
        return 29 + CGFloat(columns * 42) + CGFloat(max(0, columns - 1) * 5)
    }

    private var columnStartIndexes: [Int] {
        Array(stride(from: 0, to: model.agents.count, by: 2))
    }

    private func agents(inColumnStartingAt startIndex: Int) -> [UsageViewModel.AgentDisplay] {
        Array(model.agents[startIndex..<min(startIndex + 2, model.agents.count)])
    }
}

private struct StatusAgentBar: View {
    let agent: UsageViewModel.AgentDisplay

    var body: some View {
        HStack(spacing: 2) {
            Image(systemName: agent.symbol)
                .font(.system(size: 6, weight: .bold))
                .frame(width: 8, height: 7)
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.18))
                if let remainingPercent {
                    Capsule()
                        .fill(Color.green)
                        .frame(width: 28 * CGFloat(remainingPercent) / 100)
                }
            }
            .frame(width: 28, height: 4)
        }
        .frame(width: 38, height: 8)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
    }

    private var remainingPercent: Int? {
        agent.state.snapshot.map(UsageViewModel.minimumRemaining(in:))
    }

    private var accessibilityLabel: String {
        if let remainingPercent { return "\(agent.name) 残量 \(remainingPercent)パーセント" }
        return "\(agent.name) 取得待ち"
    }
}

private struct UsagePanel: View {
    @ObservedObject var model: UsageViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(nsImage: NSApplication.shared.applicationIconImage)
                    .resizable().aspectRatio(contentMode: .fit)
                    .frame(width: 24, height: 24)
                Text("Agent Meter").font(.headline)
                Spacer()
                if model.isRefreshing { ProgressView().controlSize(.small) }
            }

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(model.agents) { agent in
                        AgentUsageSection(agent: agent, showUsedPercent: model.showUsedPercent) {
                            model.refresh(agentID: agent.id)
                        }
                    }
                }
                .padding(.vertical, 2)
            }
            .frame(maxHeight: 570)

            Divider()
            HStack {
                Button { model.refreshAll() } label: { Label("すべて更新", systemImage: "arrow.clockwise") }
                    .keyboardShortcut("r")
                    .disabled(model.isRefreshing)
                Spacer()
                Button {
                    SettingsWindowPresenter.shared.show(model: model)
                } label: {
                    Label("設定", systemImage: "gear")
                }
                Button { NSApplication.shared.terminate(nil) } label: { Label("終了", systemImage: "power") }
                    .keyboardShortcut("q")
            }
            .controlSize(.small)
        }
        .padding()
        .frame(width: 440)
        .preferredColorScheme(model.appearance.colorScheme)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Agent Meter メニュー")
    }
}

@MainActor
private final class SettingsWindowPresenter {
    static let shared = SettingsWindowPresenter()
    private var windowController: NSWindowController?

    func show(model: UsageViewModel) {
        let controller: NSWindowController
        if let windowController {
            controller = windowController
        } else {
            let hostingController = NSHostingController(rootView: SettingsView(model: model))
            let window = NSWindow(contentViewController: hostingController)
            window.title = "Agent Meter 設定"
            window.styleMask = [.titled, .closable, .miniaturizable]
            window.setContentSize(NSSize(width: 500, height: 560))
            window.isReleasedWhenClosed = false
            window.collectionBehavior = [.moveToActiveSpace]
            window.center()
            controller = NSWindowController(window: window)
            windowController = controller
        }

        NSApplication.shared.activate(ignoringOtherApps: true)
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
    }
}

private struct AgentUsageSection: View {
    let agent: UsageViewModel.AgentDisplay
    let showUsedPercent: Bool
    let refresh: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                ZStack {
                    RoundedRectangle(cornerRadius: 8).fill(.quaternary)
                    Image(systemName: agent.symbol).font(.system(size: 16, weight: .semibold))
                }
                .frame(width: 32, height: 32)
                VStack(alignment: .leading, spacing: 1) {
                    Text(agent.name).font(.headline)
                    Text(agent.cliName).font(.caption.monospaced()).foregroundStyle(.secondary)
                }
                Spacer()
                AgentStateBadge(state: agent.state)
            }

            switch agent.state {
            case .loading:
                HStack { ProgressView().controlSize(.small); Text("使用量を取得中…") }
                    .foregroundStyle(.secondary)
            case let .fresh(snapshot), let .stale(snapshot):
                SnapshotView(snapshot: snapshot, state: agent.state, showUsedPercent: showUsedPercent)
            case .signedOut:
                ErrorStateView(message: "\(agent.cliName) でログインしてください。", action: refresh)
            case .unsupported:
                ErrorStateView(message: "このバージョンの使用量表示形式には未対応です。", action: refresh)
            case let .error(message):
                ErrorStateView(message: message, action: refresh)
            }
        }
        .padding(12)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(.separator.opacity(0.45)))
    }
}

private struct SnapshotView: View {
    let snapshot: UsageSnapshot
    let state: UsageViewModel.AgentState
    let showUsedPercent: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            ForEach(snapshot.limits) { limit in
                if let primary = limit.primary {
                    LimitRow(name: displayName(for: limit, window: primary), window: primary, showUsedPercent: showUsedPercent)
                }
                if let secondary = limit.secondary {
                    LimitRow(name: "\(limit.displayName ?? limit.id)・第2制限", window: secondary, showUsedPercent: showUsedPercent)
                }
            }
            if let plan = snapshot.planType { LabeledContent("プラン", value: plan) }
            if snapshot.creditsAreUnlimited == true { LabeledContent("クレジット", value: "無制限") }
            else if let balance = snapshot.creditsBalance { LabeledContent("クレジット", value: balance) }
            HStack {
                Text("最終更新").font(.caption)
                Spacer()
                Text(snapshot.fetchedAt, format: .dateTime.month().day().hour().minute())
                    .font(.caption).foregroundStyle(.secondary)
            }
            if case .stale = state {
                Label("前回取得したデータです", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(.orange)
            }
        }
    }

    private func displayName(for limit: UsageLimit, window: UsageWindow) -> String {
        let name = limit.displayName ?? limit.id
        guard !name.contains("時間"), !name.contains("週次"), let minutes = window.durationMinutes else { return name }
        if minutes % (7 * 24 * 60) == 0 { return "\(name)・\(minutes / (7 * 24 * 60))週" }
        if minutes % 60 == 0 { return "\(name)・\(minutes / 60)時間" }
        return "\(name)・\(minutes)分"
    }
}

private struct LimitRow: View {
    let name: String
    let window: UsageWindow
    let showUsedPercent: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(name).font(.subheadline.weight(.semibold))
                Spacer()
                Text("\(showUsedPercent ? window.usedPercent : window.remainingPercent)%")
                    .font(.title3.monospacedDigit().weight(.bold))
                    .foregroundStyle(tint)
            }
            ProgressView(value: Double(showUsedPercent ? window.usedPercent : window.remainingPercent), total: 100)
                .tint(tint)
            if let resetsAt = window.resetsAt {
                Text("リセット: \(resetsAt, format: .relative(presentation: .named))（\(resetsAt, format: .dateTime.month().day().hour().minute())）")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Text("リセット時刻はCLIから提供されていません")
                    .font(.caption).foregroundStyle(.tertiary)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(name)、\(showUsedPercent ? "使用量" : "残量") \(showUsedPercent ? window.usedPercent : window.remainingPercent)パーセント")
    }

    private var tint: Color {
        switch window.remainingPercent {
        case 0: .red
        case 1..<20: .orange
        case 20...50: .yellow
        default: .accentColor
        }
    }
}

private struct AgentStateBadge: View {
    let state: UsageViewModel.AgentState

    var body: some View {
        let presentation = presentation
        Label(presentation.text, systemImage: presentation.symbol)
            .font(.caption).foregroundStyle(presentation.color)
    }

    private var presentation: (text: String, symbol: String, color: Color) {
        switch state {
        case .loading: ("接続中", "arrow.triangle.2.circlepath", .secondary)
        case let .fresh(snapshot):
            UsageViewModel.minimumRemaining(in: snapshot) == 0
                ? ("上限到達", "xmark.circle.fill", .red)
                : ("最新", "checkmark.circle.fill", .green)
        case .stale: ("古いデータ", "exclamationmark.triangle.fill", .orange)
        case .signedOut: ("未ログイン", "person.crop.circle.badge.exclamationmark", .orange)
        case .unsupported: ("非対応", "exclamationmark.triangle", .orange)
        case .error: ("エラー", "xmark.circle", .red)
        }
    }
}

private struct ErrorStateView: View {
    let message: String
    let action: () -> Void

    var body: some View {
        HStack(alignment: .top) {
            Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)
            Text(message).font(.caption).foregroundStyle(.secondary)
            Spacer()
            Button("再試行", action: action).controlSize(.small)
        }
    }
}

private struct SettingsView: View {
    @ObservedObject var model: UsageViewModel

    var body: some View {
        Form {
            Section("接続") {
                ForEach(model.agents) { agent in
                    LabeledContent {
                        Label(agent.isInstalled ? "検出済み" : "未検出", systemImage: agent.isInstalled ? "checkmark.circle.fill" : "xmark.circle")
                            .foregroundStyle(agent.isInstalled ? .green : .secondary)
                    } label: {
                        Label(agent.name, systemImage: agent.symbol)
                    }
                }
                Text("CLIのログイン状態を利用します。認証トークンやアカウント情報は保存しません。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("表示") {
                Toggle("使用量を表示（オフの場合は残量）", isOn: $model.showUsedPercent)
                Picker("外観", selection: $model.appearance) {
                    ForEach(AppearanceChoice.allCases) { Text($0.title).tag($0) }
                }
            }
            Section("更新") {
                Picker("更新間隔", selection: $model.refreshInterval) {
                    ForEach(RefreshInterval.allCases) { Text($0.title).tag($0) }
                }
            }
            Section("通知") {
                Toggle("残量が少ないときに通知", isOn: $model.notificationsEnabled)
                Picker("通知の閾値", selection: $model.notificationThreshold) {
                    ForEach(NotificationThreshold.allCases) { Text($0.title).tag($0) }
                }
                .disabled(!model.notificationsEnabled)
                Text("通知: \(model.notificationStatus)").font(.caption).foregroundStyle(.secondary)
            }
            Section("システム") {
                Toggle("ログイン時に起動", isOn: $model.launchAtLoginEnabled)
                Text("ログイン項目: \(model.launchAtLoginStatus)").font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding()
        .frame(width: 480)
        .onChange(of: model.showUsedPercent) { _, _ in model.saveSettings() }
        .onChange(of: model.refreshInterval) { _, _ in model.saveSettings() }
        .onChange(of: model.appearance) { _, _ in model.saveSettings() }
        .onChange(of: model.notificationThreshold) { _, _ in model.saveSettings() }
        .onChange(of: model.notificationsEnabled) { _, _ in model.applyNotificationPreference() }
        .onChange(of: model.launchAtLoginEnabled) { _, enabled in model.setLaunchAtLogin(enabled) }
        .accessibilityLabel("Agent Meter 設定")
    }
}
