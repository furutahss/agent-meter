import Darwin
import Foundation

/// Antigravity CLI の対話画面 `/usage` を読み取るプロバイダー。
/// 認証ファイルには触れず、CLI 自身が取得・表示したクォータだけを解析する。
public actor AntigravityCLIProvider: UsageProvider {
    public nonisolated let identity = ProviderIdentity(name: "Antigravity CLI", version: "interactive-usage-v1")

    private let executableURL: URL
    private let workingDirectoryURL: URL
    private let timeout: Duration

    public init(executableURL: URL, workingDirectoryURL: URL, timeout: Duration = .seconds(30)) {
        self.executableURL = executableURL
        self.workingDirectoryURL = workingDirectoryURL
        self.timeout = timeout
    }

    public func connect() async throws {
        guard FileManager.default.isExecutableFile(atPath: executableURL.path) else {
            throw UsageProviderError.executableNotFound
        }
    }

    public func fetchSnapshot() async throws -> UsageSnapshot {
        try await connect()
        try FileManager.default.createDirectory(at: workingDirectoryURL, withIntermediateDirectories: true)

        let terminal = try PseudoTerminalProcess(
            executableURL: executableURL,
            currentDirectoryURL: workingDirectoryURL
        )
        defer { terminal.stop() }
        try terminal.start()

        let deadline = ContinuousClock.now.advanced(by: timeout)
        var trustedWorkspace = false
        while ContinuousClock.now < deadline {
            try Task.checkCancellation()
            let output = terminal.transcript
            if output.contains("Do you trust the contents of this project?") && !trustedWorkspace {
                // アプリ専用の空ディレクトリだけを作業領域として使うため、自動承認してよい。
                terminal.write("\r")
                trustedWorkspace = true
            }
            if output.contains("? for shortcuts") { break }
            if output.localizedCaseInsensitiveContains("not signed in") && output.contains("sign in") {
                // 起動直後にも一時的に表示されるため、期限まではログイン完了を待つ。
            }
            try await Task.sleep(for: .milliseconds(200))
        }

        guard terminal.transcript.contains("? for shortcuts") else {
            if terminal.transcript.localizedCaseInsensitiveContains("not signed in") {
                throw UsageProviderError.signedOut
            }
            throw UsageProviderError.timedOut
        }

        terminal.write("/usage\r")
        while ContinuousClock.now < deadline {
            try Task.checkCancellation()
            if terminal.transcript.contains("Models & Quota") { break }
            try await Task.sleep(for: .milliseconds(200))
        }
        guard terminal.transcript.contains("Models & Quota") else {
            throw UsageProviderError.unsupportedResponse
        }

        // 小さい疑似端末でも全グループを収集できるよう下端までスクロールする。
        terminal.write("\u{1B}[6~")
        try await Task.sleep(for: .milliseconds(500))
        terminal.write("\u{1B}[6~")
        try await Task.sleep(for: .milliseconds(500))
        terminal.write("\u{1B}[4~")
        try await Task.sleep(for: .milliseconds(500))

        return try AntigravityUsageDecoder.decode(
            terminal.transcript,
            fetchedAt: .now,
            provider: identity
        )
    }

    public func updates() async -> AsyncStream<UsageSnapshot> {
        AsyncStream { $0.finish() }
    }

    public func disconnect() async {}
}

public enum AntigravityUsageDecoder {
    public static func decode(
        _ terminalOutput: String,
        fetchedAt: Date,
        provider: ProviderIdentity
    ) throws -> UsageSnapshot {
        let text = stripTerminalControls(from: terminalOutput)
        let definitions = [
            (header: "GEMINI MODELS", id: "gemini", name: "Gemini モデル"),
            (header: "CLAUDE AND GPT MODELS", id: "claude-gpt", name: "Claude / GPT モデル"),
        ]
        var limits: [UsageLimit] = []

        for (index, definition) in definitions.enumerated() {
            guard let start = text.range(of: definition.header, options: .backwards)?.lowerBound else { continue }
            let end: String.Index
            if index + 1 < definitions.count,
               let next = text.range(of: definitions[index + 1].header, range: start..<text.endIndex)?.lowerBound {
                end = next
            } else {
                end = text.endIndex
            }
            let block = String(text[start..<end])
            if let weekly = decodeWindow(named: "Weekly Limit Remaining", in: block, durationMinutes: 7 * 24 * 60, fetchedAt: fetchedAt) {
                limits.append(UsageLimit(id: "\(definition.id)-weekly", displayName: "\(definition.name)・週次", primary: weekly))
            }
            if let fiveHour = decodeWindow(named: "Five Hour Limit Remaining", in: block, durationMinutes: 5 * 60, fetchedAt: fetchedAt) {
                limits.append(UsageLimit(id: "\(definition.id)-five-hour", displayName: "\(definition.name)・5時間", primary: fiveHour))
            }
        }

        guard !limits.isEmpty else { throw UsageProviderError.unsupportedResponse }
        return UsageSnapshot(fetchedAt: fetchedAt, provider: provider, limits: limits)
    }

    private static func decodeWindow(named name: String, in block: String, durationMinutes: Int, fetchedAt: Date) -> UsageWindow? {
        guard let titleRange = block.range(of: name) else { return nil }
        let remainder = String(block[titleRange.upperBound...])
        let nextTitleOffsets = ["Weekly Limit Remaining", "Five Hour Limit Remaining"]
            .compactMap { remainder.range(of: $0)?.lowerBound }
        let end = nextTitleOffsets.min() ?? remainder.endIndex
        let section = String(remainder[..<end])

        let percentPattern = #"([0-9]+(?:\.[0-9]+)?)%"#
        guard let percentRegex = try? NSRegularExpression(pattern: percentPattern),
              let match = percentRegex.firstMatch(in: section, range: NSRange(section.startIndex..., in: section)),
              let percentRange = Range(match.range(at: 1), in: section),
              let remaining = Double(section[percentRange]) else { return nil }

        let resetDate: Date?
        let resetPattern = #"Refreshes in\s+([^\r\n]+)"#
        if let regex = try? NSRegularExpression(pattern: resetPattern),
           let match = regex.firstMatch(in: section, range: NSRange(section.startIndex..., in: section)),
           let range = Range(match.range(at: 1), in: section) {
            resetDate = parseDuration(String(section[range])).map { fetchedAt.addingTimeInterval($0) }
        } else {
            resetDate = nil
        }

        return UsageWindow(
            usedPercent: Int((100 - remaining).rounded()),
            durationMinutes: durationMinutes,
            resetsAt: resetDate
        )
    }

    private static func parseDuration(_ value: String) -> TimeInterval? {
        let pattern = #"([0-9]+)\s*([dhm])"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let matches = regex.matches(in: value, range: NSRange(value.startIndex..., in: value))
        guard !matches.isEmpty else { return nil }
        return matches.reduce(0) { total, match in
            guard let numberRange = Range(match.range(at: 1), in: value),
                  let unitRange = Range(match.range(at: 2), in: value),
                  let number = Double(value[numberRange]) else { return total }
            let multiplier: Double = switch value[unitRange] {
            case "d": 24 * 60 * 60
            case "h": 60 * 60
            default: 60
            }
            return total + number * multiplier
        }
    }

    private static func stripTerminalControls(from value: String) -> String {
        var result = value
        let patterns = [
            #"\u{001B}\[[0-?]*[ -/]*[@-~]"#,
            #"\u{001B}\][^\u{0007}]*(?:\u{0007}|\u{001B}\\)"#,
        ]
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            result = regex.stringByReplacingMatches(in: result, range: NSRange(result.startIndex..., in: result), withTemplate: "")
        }
        return result.replacingOccurrences(of: "\u{0008}", with: "")
    }
}

private final class TerminalTranscript: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()

    func append(_ incoming: Data) {
        guard !incoming.isEmpty else { return }
        lock.lock()
        data.append(incoming)
        if data.count > 1_500_000 { data.removeFirst(data.count - 1_500_000) }
        lock.unlock()
    }

    var text: String {
        lock.lock()
        defer { lock.unlock() }
        return String(decoding: data, as: UTF8.self)
    }
}

private final class PseudoTerminalProcess: @unchecked Sendable {
    private let executableURL: URL
    private let currentDirectoryURL: URL
    private let process = Process()
    private let transcriptStore = TerminalTranscript()
    private var master: FileHandle?
    private var slaveDescriptor: Int32 = -1

    init(executableURL: URL, currentDirectoryURL: URL) throws {
        self.executableURL = executableURL
        self.currentDirectoryURL = currentDirectoryURL

        var masterDescriptor: Int32 = -1
        var slaveDescriptor: Int32 = -1
        var size = winsize(ws_row: 80, ws_col: 120, ws_xpixel: 0, ws_ypixel: 0)
        guard openpty(&masterDescriptor, &slaveDescriptor, nil, nil, &size) == 0 else {
            throw UsageProviderError.protocolError("pty")
        }
        master = FileHandle(fileDescriptor: masterDescriptor, closeOnDealloc: true)
        self.slaveDescriptor = slaveDescriptor
    }

    var transcript: String { transcriptStore.text }

    func start() throws {
        guard let master else { throw UsageProviderError.protocolError("pty") }
        let slave = FileHandle(fileDescriptor: slaveDescriptor, closeOnDealloc: false)
        process.executableURL = executableURL
        process.currentDirectoryURL = currentDirectoryURL
        process.standardInput = slave
        process.standardOutput = slave
        process.standardError = slave
        var environment = ProcessInfo.processInfo.environment
        environment["TERM"] = "xterm-256color"
        environment["COLUMNS"] = "120"
        environment["LINES"] = "80"
        process.environment = environment
        master.readabilityHandler = { [transcriptStore] handle in
            transcriptStore.append(handle.availableData)
        }
        do {
            try process.run()
            close(slaveDescriptor)
            slaveDescriptor = -1
        } catch {
            master.readabilityHandler = nil
            close(slaveDescriptor)
            slaveDescriptor = -1
            throw UsageProviderError.executableNotFound
        }
    }

    func write(_ value: String) {
        guard let data = value.data(using: .utf8) else { return }
        try? master?.write(contentsOf: data)
    }

    func stop() {
        write("\u{1B}")
        write("/exit\r")
        if process.isRunning { process.terminate() }
        master?.readabilityHandler = nil
        if slaveDescriptor >= 0 { close(slaveDescriptor) }
        slaveDescriptor = -1
        try? master?.close()
        master = nil
    }
}
