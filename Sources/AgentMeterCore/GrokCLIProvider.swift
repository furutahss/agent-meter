import Foundation

/// Grok CLI の請求情報を読み取るプロバイダー。
/// 認証ファイルには触れず、`grok agent --no-leader stdio` が返す現在期間の使用率だけを使う。
/// 対話セッションは作らない。共有 leader にも接続しない。
public actor GrokCLIProvider: UsageProvider {
    public nonisolated let identity = ProviderIdentity(name: "Grok", version: "billing-v1")

    private let executableURL: URL
    private let workingDirectoryURL: URL
    private let timeout: Duration
    private var process: Process?
    private var input: FileHandle?
    private var reader: Task<Void, Never>?
    private var nextRequestID = 1
    private var pending: [Int: CheckedContinuation<Data, Error>] = [:]
    private var ready = false

    public init(executableURL: URL, workingDirectoryURL: URL, timeout: Duration = .seconds(30)) {
        self.executableURL = executableURL
        self.workingDirectoryURL = workingDirectoryURL
        self.timeout = timeout
    }

    public func connect() async throws {
        if process?.isRunning == true, ready { return }
        if process != nil { await disconnect() }
        guard FileManager.default.isExecutableFile(atPath: executableURL.path) else {
            throw UsageProviderError.executableNotFound
        }
        try FileManager.default.createDirectory(at: workingDirectoryURL, withIntermediateDirectories: true)

        let newProcess = Process()
        let stdin = Pipe()
        let stdout = Pipe()
        let stderr = Pipe()
        newProcess.executableURL = executableURL
        newProcess.arguments = ["agent", "--no-leader", "stdio"]
        newProcess.currentDirectoryURL = workingDirectoryURL
        newProcess.standardInput = stdin
        newProcess.standardOutput = stdout
        newProcess.standardError = stderr
        newProcess.terminationHandler = { [weak self] finished in
            Task { await self?.processDidExit(status: finished.terminationStatus) }
        }
        stderr.fileHandleForReading.readabilityHandler = { handle in
            _ = handle.availableData
        }
        do {
            try newProcess.run()
        } catch {
            throw UsageProviderError.executableNotFound
        }
        process = newProcess
        input = stdin.fileHandleForWriting
        reader = Task { [weak self] in
            do {
                for try await line in stdout.fileHandleForReading.bytes.lines {
                    await self?.receive(line: line)
                }
            } catch {
                await self?.processDidExit(status: -1)
            }
        }

        let response: Data
        do {
            response = try await request(method: "initialize", params: [
                "protocolVersion": 1,
                "clientInfo": ["name": "agent-meter", "version": "1.0.0"],
                "clientCapabilities": [
                    "fs": ["readTextFile": true, "writeTextFile": true],
                    "terminal": true,
                ],
            ])
        } catch {
            await disconnect()
            throw error
        }
        guard (try JSONSerialization.jsonObject(with: response)) is [String: Any] else {
            await disconnect()
            throw UsageProviderError.unsupportedResponse
        }
        do {
            try sendNotification(method: "initialized")
        } catch {
            await disconnect()
            throw error
        }
        ready = true
    }

    public func fetchSnapshot() async throws -> UsageSnapshot {
        try Task.checkCancellation()
        try await connect()
        let response = try await request(method: "_x.ai/billing", params: [:])
        guard let json = try JSONSerialization.jsonObject(with: response) as? [String: Any] else {
            throw UsageProviderError.unsupportedResponse
        }
        return try GrokBillingDecoder.decode(json, fetchedAt: .now, provider: identity)
    }

    public func updates() async -> AsyncStream<UsageSnapshot> {
        AsyncStream { $0.finish() }
    }

    public func disconnect() async {
        ready = false
        reader?.cancel()
        reader = nil
        input?.closeFile()
        input = nil
        if let process, process.isRunning { process.terminate() }
        self.process = nil
        failPending(with: UsageProviderError.processExited(-1))
    }

    private func request(method: String, params: [String: Any]) async throws -> Data {
        try Task.checkCancellation()
        let id = nextRequestID
        nextRequestID += 1
        let payload: [String: Any] = ["jsonrpc": "2.0", "id": id, "method": method, "params": params]
        return try await withCheckedThrowingContinuation { continuation in
            pending[id] = continuation
            do {
                try send(payload)
                scheduleTimeout(for: id)
            } catch {
                pending.removeValue(forKey: id)
                continuation.resume(throwing: error)
            }
        }
    }

    private func scheduleTimeout(for id: Int) {
        let timeout = timeout
        Task.detached { [weak self] in
            try? await Task.sleep(for: timeout)
            await self?.timeoutRequest(id)
        }
    }

    private func timeoutRequest(_ id: Int) {
        pending.removeValue(forKey: id)?.resume(throwing: UsageProviderError.timedOut)
    }

    private func sendNotification(method: String) throws {
        try send(["jsonrpc": "2.0", "method": method, "params": [:]])
    }

    private func send(_ object: [String: Any]) throws {
        guard let input else { throw UsageProviderError.processExited(-1) }
        let data = try JSONSerialization.data(withJSONObject: object)
        input.write(data + Data([0x0A]))
    }

    private func receive(line: String) {
        guard let data = line.data(using: .utf8),
              let message = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let id = message["id"] as? Int,
              let continuation = pending.removeValue(forKey: id) else { return }
        if let error = message["error"] as? [String: Any] {
            continuation.resume(throwing: mapRPCError(error))
        } else if let result = message["result"],
                  JSONSerialization.isValidJSONObject(result),
                  let data = try? JSONSerialization.data(withJSONObject: result) {
            continuation.resume(returning: data)
        } else {
            continuation.resume(throwing: UsageProviderError.unsupportedResponse)
        }
    }

    private func mapRPCError(_ error: [String: Any]) -> UsageProviderError {
        let code = error["code"] as? Int
        let message = (error["message"] as? String) ?? ""
        if code == 401
            || message.localizedCaseInsensitiveContains("authentication required")
            || message.localizedCaseInsensitiveContains("not signed in")
            || message.localizedCaseInsensitiveContains("sign in") {
            return .signedOut
        }
        if code == -32601 { return .unsupportedResponse }
        return .protocolError("rpc")
    }

    private func processDidExit(status: Int32) {
        ready = false
        process = nil
        failPending(with: UsageProviderError.processExited(status))
    }

    private func failPending(with error: Error) {
        let values = pending.values
        pending.removeAll()
        for continuation in values { continuation.resume(throwing: error) }
    }
}

enum GrokBillingDecoder {
    static func decode(_ result: [String: Any], fetchedAt: Date, provider: ProviderIdentity) throws -> UsageSnapshot {
        guard let config = result["config"] as? [String: Any],
              let used = finiteDouble(config["creditUsagePercent"]) else {
            throw UsageProviderError.unsupportedResponse
        }

        let period = config["currentPeriod"] as? [String: Any]
        let periodType = period?["type"] as? String
        let periodStart = parseDate(period?["start"])
        let resetsAt = parseDate(period?["end"]) ?? parseDate(config["billingPeriodEnd"])
        let duration = durationMinutes(type: periodType, start: periodStart, end: resetsAt)
        let identity = limitIdentity(for: periodType)
        var limits = [
            UsageLimit(
                id: identity.id,
                displayName: identity.name,
                primary: UsageWindow(
                    usedPercent: Int(used.rounded()),
                    durationMinutes: duration,
                    resetsAt: resetsAt
                )
            ),
        ]

        if let cap = money(config["onDemandCap"]),
           cap > 0,
           let onDemandUsed = money(config["onDemandUsed"]),
           cap.isFinite, onDemandUsed.isFinite {
            let percent = Int((min(max(onDemandUsed / cap, 0), 1) * 100).rounded())
            limits.append(UsageLimit(
                id: "grok-on-demand",
                displayName: "従量課金",
                primary: UsageWindow(usedPercent: percent, durationMinutes: duration, resetsAt: resetsAt)
            ))
        }

        let prepaid = money(config["prepaidBalance"])
        let credits = prepaid.flatMap { $0 > 0 && $0.isFinite ? formatDollars($0) : nil }
        return UsageSnapshot(
            fetchedAt: fetchedAt,
            provider: provider,
            limits: limits,
            planType: result["subscription_tier"] as? String,
            creditsBalance: credits
        )
    }

    private static func limitIdentity(for periodType: String?) -> (id: String, name: String) {
        let type = periodType?.uppercased() ?? ""
        if type.contains("WEEK") { return ("grok-weekly", "週次") }
        if type.contains("MONTH") { return ("grok-monthly", "月次") }
        return ("grok-period", "使用量")
    }

    private static func durationMinutes(type: String?, start: Date?, end: Date?) -> Int? {
        if let start, let end, end >= start {
            return Int(end.timeIntervalSince(start) / 60)
        }
        let normalized = type?.uppercased() ?? ""
        if normalized.contains("WEEK") { return 7 * 24 * 60 }
        if normalized.contains("MONTH") { return 30 * 24 * 60 }
        return nil
    }

    private static func money(_ value: Any?) -> Double? {
        if let object = value as? [String: Any] { return finiteDouble(object["val"]) }
        return finiteDouble(value)
    }

    private static func finiteDouble(_ value: Any?) -> Double? {
        let number: Double?
        if let value = value as? Double {
            number = value
        } else if let value = value as? Int {
            number = Double(value)
        } else if let value = value as? NSNumber {
            number = value.doubleValue
        } else if let value = value as? String {
            number = Double(value)
        } else {
            number = nil
        }
        guard let number, number.isFinite else { return nil }
        return number
    }

    private static func formatDollars(_ value: Double) -> String {
        String(format: "$%.2f", value)
    }

    private static func parseDate(_ value: Any?) -> Date? {
        guard let string = value as? String else { return nil }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: string) { return date }
        let trimmed = string.replacingOccurrences(
            of: #"(\.\d{3})\d+"#,
            with: "$1",
            options: .regularExpression
        )
        if let date = fractional.date(from: trimmed) { return date }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        let stripped = string.replacingOccurrences(of: #"\.\d+"#, with: "", options: .regularExpression)
        return plain.date(from: stripped)
    }
}
