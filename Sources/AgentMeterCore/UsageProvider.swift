import Foundation

public struct ProviderIdentity: Sendable, Codable, Equatable {
    public let name: String
    public let version: String

    public init(name: String, version: String) {
        self.name = name
        self.version = version
    }
}

public struct UsageWindow: Sendable, Codable, Equatable {
    public let usedPercent: Int
    public let durationMinutes: Int?
    public let resetsAt: Date?

    public init(usedPercent: Int, durationMinutes: Int? = nil, resetsAt: Date? = nil) {
        self.usedPercent = min(max(usedPercent, 0), 100)
        self.durationMinutes = durationMinutes.flatMap { $0 >= 0 ? $0 : nil }
        self.resetsAt = resetsAt
    }

    public var remainingPercent: Int { 100 - usedPercent }
}

public struct UsageLimit: Sendable, Codable, Equatable, Identifiable {
    public let id: String
    public let displayName: String?
    public let primary: UsageWindow?
    public let secondary: UsageWindow?
    public let reachedReason: String?

    public init(id: String, displayName: String? = nil, primary: UsageWindow? = nil, secondary: UsageWindow? = nil, reachedReason: String? = nil) {
        self.id = id
        self.displayName = displayName
        self.primary = primary
        self.secondary = secondary
        self.reachedReason = reachedReason
    }
}

public struct UsageSnapshot: Sendable, Codable, Equatable {
    public let fetchedAt: Date
    public let provider: ProviderIdentity
    public let limits: [UsageLimit]
    public let planType: String?
    public let creditsBalance: String?
    public let creditsAreUnlimited: Bool?

    public init(fetchedAt: Date, provider: ProviderIdentity, limits: [UsageLimit], planType: String? = nil, creditsBalance: String? = nil, creditsAreUnlimited: Bool? = nil) {
        self.fetchedAt = fetchedAt
        self.provider = provider
        self.limits = limits
        self.planType = planType
        self.creditsBalance = creditsBalance
        self.creditsAreUnlimited = creditsAreUnlimited
    }
}

public protocol UsageProvider: Sendable {
    var identity: ProviderIdentity { get }
    func connect() async throws
    func fetchSnapshot() async throws -> UsageSnapshot
    func updates() async -> AsyncStream<UsageSnapshot>
    func disconnect() async
}

public enum UsageProviderError: Error, Sendable, Equatable, LocalizedError {
    case executableNotFound
    case processExited(Int32)
    case timedOut
    case signedOut
    case unsupportedResponse
    case protocolError(String)

    public var errorDescription: String? {
        switch self {
        case .executableNotFound: "エージェントCLIが見つかりません。"
        case .processExited: "エージェントCLIとの接続が終了しました。"
        case .timedOut: "エージェントCLIの応答がタイムアウトしました。"
        case .signedOut: "エージェントCLIにログインしていません。"
        case .unsupportedResponse: "このCLIの使用量応答形式には対応していません。"
        case .protocolError: "エージェントCLIとの通信に失敗しました。"
        }
    }
}

public enum UsageFreshness: Sendable, Equatable {
    case fresh
    case stale
    case expired

    public static func status(of snapshot: UsageSnapshot, now: Date = .now) -> Self {
        let age = now.timeIntervalSince(snapshot.fetchedAt)
        if age > 24 * 60 * 60 { return .expired }
        if age > 15 * 60 { return .stale }
        return .fresh
    }
}

/// app-server から届く部分更新を、最後に成功した完全スナップショットへ安全に重ねる。
public enum UsageSnapshotMerger {
    public static func merge(current: UsageSnapshot, update: UsageSnapshot) -> UsageSnapshot {
        var limits = Dictionary(uniqueKeysWithValues: current.limits.map { ($0.id, $0) })
        for incoming in update.limits {
            guard let existing = limits[incoming.id] else {
                limits[incoming.id] = incoming
                continue
            }
            limits[incoming.id] = UsageLimit(
                id: incoming.id,
                displayName: incoming.displayName ?? existing.displayName,
                primary: incoming.primary ?? existing.primary,
                secondary: incoming.secondary ?? existing.secondary,
                reachedReason: incoming.reachedReason ?? existing.reachedReason
            )
        }
        let orderedIDs = current.limits.map(\.id) + update.limits.map(\.id).filter { limits[$0] != nil && !current.limits.map(\.id).contains($0) }
        return UsageSnapshot(
            fetchedAt: update.fetchedAt,
            provider: update.provider,
            limits: orderedIDs.compactMap { limits[$0] },
            planType: update.planType ?? current.planType,
            creditsBalance: update.creditsBalance ?? current.creditsBalance,
            creditsAreUnlimited: update.creditsAreUnlimited ?? current.creditsAreUnlimited
        )
    }
}

public struct RefreshBackoff: Sendable, Equatable {
    public private(set) var consecutiveFailures = 0
    public init() {}

    public mutating func registerFailure() { consecutiveFailures += 1 }
    public mutating func registerSuccess() { consecutiveFailures = 0 }

    /// jitterを適用する前の遅延秒数。1, 2, 4, 8, 15分で上限となる。
    public var baseDelay: Duration {
        if consecutiveFailures >= 5 { return .seconds(15 * 60) }
        let minutes = 1 << max(consecutiveFailures - 1, 0)
        return .seconds(minutes * 60)
    }
}

/// 残量通知の重複抑止と再武装を、UIやOSの通知権限から独立して判定する。
public struct UsageNotificationPolicy: Sendable, Equatable {
    public struct Alert: Sendable, Equatable, Identifiable {
        public let id: String
        public let limitName: String
        public let remainingPercent: Int

        public init(id: String, limitName: String, remainingPercent: Int) {
            self.id = id
            self.limitName = limitName
            self.remainingPercent = remainingPercent
        }
    }

    public let threshold: Int
    private var armedIDs: Set<String> = []

    public init(threshold: Int) {
        self.threshold = min(max(threshold, 0), 100)
    }

    /// 同じ制限・リセット時刻・閾値の通知は一度だけ送る。残量が閾値より回復すると再武装する。
    public mutating func alerts(for snapshot: UsageSnapshot) -> [Alert] {
        snapshot.limits.flatMap { limit in
            [limit.primary, limit.secondary].compactMap { window in
                guard let window else { return nil }
                let key = notificationID(limitID: limit.id, window: window)
                if window.remainingPercent > threshold {
                    armedIDs.remove(key)
                    return nil
                }
                guard !armedIDs.contains(key) else { return nil }
                armedIDs.insert(key)
                return Alert(id: key, limitName: limit.displayName ?? limit.id, remainingPercent: window.remainingPercent)
            }
        }
    }

    private func notificationID(limitID: String, window: UsageWindow) -> String {
        let reset = window.resetsAt?.timeIntervalSince1970.description ?? "no-reset"
        return "\(limitID)-\(window.durationMinutes ?? 0)-\(reset)-\(threshold)"
    }
}

public actor UsageCache {
    private let fileURL: URL

    public init(fileURL: URL) { self.fileURL = fileURL }

    public func load() throws -> UsageSnapshot? {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
        return try JSONDecoder().decode(UsageSnapshot.self, from: Data(contentsOf: fileURL))
    }

    public func save(_ snapshot: UsageSnapshot) throws {
        let data = try JSONEncoder().encode(snapshot)
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: fileURL, options: .atomic)
    }

    public func remove() throws {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        try FileManager.default.removeItem(at: fileURL)
    }
}

/// 同時に要求された更新を一つのprovider呼び出しへ集約する。
public actor UsageRefreshCoordinator {
    private let provider: any UsageProvider
    private var inFlight: Task<UsageSnapshot, Error>?
    private var latest: UsageSnapshot?

    public init(provider: any UsageProvider) { self.provider = provider }

    public func refresh() async throws -> UsageSnapshot {
        if let inFlight { return try await inFlight.value }
        let provider = provider
        let task = Task { try await provider.fetchSnapshot() }
        inFlight = task
        defer { inFlight = nil }
        let snapshot = try await task.value
        latest = snapshot
        return snapshot
    }

    public func cancel() {
        inFlight?.cancel()
        inFlight = nil
    }

    public func cachedSnapshot() -> UsageSnapshot? { latest }
}
