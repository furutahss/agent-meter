import Foundation

/// Developer ID beta 向けの読み取り専用 app-server プロバイダー。
public actor AppServerProvider: UsageProvider {
    public nonisolated let identity = ProviderIdentity(name: "app-server", version: "spike-0.1.0")

    private let executableURL: URL
    private let arguments: [String]
    private let timeout: Duration
    private var process: Process?
    private var input: FileHandle?
    private var reader: Task<Void, Never>?
    private var nextRequestID = 1
    private var pending: [Int: CheckedContinuation<Data, Error>] = [:]
    private var updateContinuation: AsyncStream<UsageSnapshot>.Continuation?
    private var lastSnapshot: UsageSnapshot?

    public init(executableURL: URL, arguments: [String] = ["app-server", "--stdio"], timeout: Duration = .seconds(10)) {
        self.executableURL = executableURL
        self.arguments = arguments
        self.timeout = timeout
    }

    public func connect() async throws {
        if process?.isRunning == true { return }
        guard FileManager.default.isExecutableFile(atPath: executableURL.path) else {
            throw UsageProviderError.executableNotFound
        }

        let newProcess = Process()
        let stdin = Pipe()
        let stdout = Pipe()
        let stderr = Pipe()
        newProcess.executableURL = executableURL
        newProcess.arguments = arguments
        newProcess.standardInput = stdin
        newProcess.standardOutput = stdout
        newProcess.standardError = stderr
        newProcess.terminationHandler = { [weak self] finished in
            Task { await self?.processDidExit(status: finished.terminationStatus) }
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

        let response = try await request(method: "initialize", params: [
            "clientInfo": ["name": "agent-meter-spike", "version": "0.1.0"],
            "capabilities": ["experimentalApi": true],
        ])
        guard (try JSONSerialization.jsonObject(with: response)) is [String: Any] else { throw UsageProviderError.unsupportedResponse }
        try sendNotification(method: "initialized")
    }

    public func fetchSnapshot() async throws -> UsageSnapshot {
        try Task.checkCancellation()
        try await connect()
        let response = try await request(method: "account/rateLimits/read", params: [:])
        guard let json = try JSONSerialization.jsonObject(with: response) as? [String: Any] else { throw UsageProviderError.unsupportedResponse }
        let snapshot = try AppServerResponseDecoder.decode(json, fetchedAt: .now, provider: identity)
        lastSnapshot = snapshot
        return snapshot
    }

    public func updates() async -> AsyncStream<UsageSnapshot> {
        AsyncStream { continuation in
            updateContinuation = continuation
            continuation.onTermination = { [weak self] _ in
                Task { await self?.clearUpdates() }
            }
        }
    }

    public func disconnect() async {
        reader?.cancel()
        reader = nil
        input?.closeFile()
        input = nil
        if let process, process.isRunning { process.terminate() }
        self.process = nil
        failPending(with: UsageProviderError.processExited(-1))
        updateContinuation?.finish()
        updateContinuation = nil
    }

    private func request(method: String, params: [String: Any]) async throws -> Data {
        try Task.checkCancellation()
        let id = nextRequestID
        nextRequestID += 1
        let payload = try JSONSerialization.data(withJSONObject: ["id": id, "method": method, "params": params]) + Data([0x0A])
        return try await withCheckedThrowingContinuation { continuation in
            pending[id] = continuation
            do {
                guard let input else { throw UsageProviderError.processExited(-1) }
                input.write(payload)
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

    private func sendNotification(method: String) throws { try send(["method": method, "params": [:]]) }

    private func send(_ object: [String: Any]) throws {
        guard let input else { throw UsageProviderError.processExited(-1) }
        let data = try JSONSerialization.data(withJSONObject: object)
        input.write(data + Data([0x0A]))
    }

    private func receive(line: String) {
        guard let data = line.data(using: .utf8), let message = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        if let id = message["id"] as? Int, let continuation = pending.removeValue(forKey: id) {
            if let error = message["error"] as? [String: Any] {
                let code = error["code"] as? Int
                continuation.resume(throwing: code == 401 ? UsageProviderError.signedOut : UsageProviderError.protocolError("rpc"))
            } else if let result = message["result"], JSONSerialization.isValidJSONObject(result), let data = try? JSONSerialization.data(withJSONObject: result) {
                continuation.resume(returning: data)
            } else {
                continuation.resume(throwing: UsageProviderError.unsupportedResponse)
            }
            return
        }
        guard message["method"] as? String == "account/rateLimits/updated",
              let params = message["params"] as? [String: Any],
              let snapshot = try? AppServerResponseDecoder.decode(params, fetchedAt: .now, provider: identity) else { return }
        let merged = lastSnapshot.map { UsageSnapshotMerger.merge(current: $0, update: snapshot) } ?? snapshot
        lastSnapshot = merged
        updateContinuation?.yield(merged)
    }

    private func processDidExit(status: Int32) {
        process = nil
        failPending(with: UsageProviderError.processExited(status))
    }

    private func failPending(with error: Error) {
        let values = pending.values
        pending.removeAll()
        for continuation in values { continuation.resume(throwing: error) }
    }

    private func clearUpdates() { updateContinuation = nil }
}

enum AppServerResponseDecoder {
    static func decode(_ result: [String: Any], fetchedAt: Date, provider: ProviderIdentity) throws -> UsageSnapshot {
        let rateLimits = result["rateLimits"] as? [String: Any]
        var buckets = rateLimits.map { [$0] } ?? []
        if let byID = result["rateLimitsByLimitId"] as? [String: Any] {
            buckets = byID.compactMap { key, value in
                guard var bucket = value as? [String: Any] else { return nil }
                bucket["limitId"] = bucket["limitId"] ?? key
                return bucket
            }
        }
        guard !buckets.isEmpty else { throw UsageProviderError.unsupportedResponse }
        let limits = buckets.enumerated().map { index, bucket in
            UsageLimit(
                id: bucket["limitId"] as? String ?? "limit-\(index + 1)",
                displayName: bucket["limitName"] as? String,
                primary: decodeWindow(bucket["primary"]),
                secondary: decodeWindow(bucket["secondary"]),
                reachedReason: bucket["rateLimitReachedType"] as? String
            )
        }
        let credits = rateLimits?["credits"] as? [String: Any]
        return UsageSnapshot(
            fetchedAt: fetchedAt,
            provider: provider,
            limits: limits,
            planType: rateLimits?["planType"] as? String,
            creditsBalance: credits?["balance"] as? String,
            creditsAreUnlimited: credits?["unlimited"] as? Bool
        )
    }

    private static func decodeWindow(_ value: Any?) -> UsageWindow? {
        guard let json = value as? [String: Any], let used = json["usedPercent"] as? Int else { return nil }
        return UsageWindow(
            usedPercent: min(max(used, 0), 100),
            durationMinutes: json["windowDurationMins"] as? Int,
            resetsAt: (json["resetsAt"] as? Double).map(Date.init(timeIntervalSince1970:))
        )
    }
}
