import Darwin
import Foundation

/// Claude Code CLI の対話画面 `/usage` を読み取るプロバイダー。
/// 認証ファイルには直接触れず、CLI 自身が取得・表示したクォータだけを解析する。
public actor ClaudeCLIProvider: UsageProvider {
    public nonisolated let identity = ProviderIdentity(name: "Claude Code", version: "interactive-usage-v1")

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
        var dismissedExtensionNotice = false
        var lastSentUsageAt: ContinuousClock.Instant?

        while ContinuousClock.now < deadline {
            try Task.checkCancellation()
            let output = terminal.transcript

            // 1. プロジェクト信頼確認ダイアログの承認（アプリ専用の一時ディレクトリのため承認してよい）
            if (output.localizedCaseInsensitiveContains("trust this folder") ||
                output.localizedCaseInsensitiveContains("trust the contents of this project") ||
                output.localizedCaseInsensitiveContains("Yes, I trust this folder") ||
                output.localizedCaseInsensitiveContains("1.yes")) && !trustedWorkspace {
                try await Task.sleep(for: .milliseconds(300))
                terminal.write("\r")
                trustedWorkspace = true
            }

            // 2. VS Code 拡張機能の案内などのキー入力待ちを解除
            if output.contains("Press Enter to continue") && !dismissedExtensionNotice {
                try await Task.sleep(for: .milliseconds(300))
                terminal.write("\r")
                dismissedExtensionNotice = true
            }

            // 3. プロンプトが表示されたら /usage を送信（未応答なら一定間隔でリトライ）
            let isPromptReady = output.contains("auto mode") ||
                                output.contains("❯") ||
                                output.contains("Try \"") ||
                                output.contains("Try '") ||
                                output.contains("? for shortcuts")
            if isPromptReady {
                let shouldSend: Bool
                if let lastSent = lastSentUsageAt {
                    shouldSend = ContinuousClock.now > lastSent.advanced(by: .seconds(3))
                } else {
                    shouldSend = true
                }
                if shouldSend {
                    try await Task.sleep(for: .milliseconds(500))
                    terminal.write("/usage\r")
                    lastSentUsageAt = .now
                }
            }

            // 4. 使用量情報の描画完了検知
            if lastSentUsageAt != nil {
                let isUsageRendered = (output.contains("Current session") && output.contains("Current week")) ||
                                      output.contains("Usage credits") ||
                                      output.contains("What's contributing") ||
                                      output.contains("limits promo")
                if isUsageRendered {
                    // 全行の描画完了を少し待機
                    try await Task.sleep(for: .milliseconds(1200))
                    break
                }
            }

            try await Task.sleep(for: .milliseconds(200))
        }

        let finalOutput = terminal.transcript
        if (finalOutput.localizedCaseInsensitiveContains("not signed in") ||
            finalOutput.localizedCaseInsensitiveContains("Sign in to Claude Code") ||
            finalOutput.localizedCaseInsensitiveContains("Auth error")) &&
            !finalOutput.contains("Current session") &&
            !finalOutput.contains("Current week") {
            throw UsageProviderError.signedOut
        }

        guard finalOutput.contains("Current session") ||
              finalOutput.contains("Current week") ||
              finalOutput.contains("Plan usage") else {
            if ContinuousClock.now >= deadline {
                throw UsageProviderError.timedOut
            }
            throw UsageProviderError.unsupportedResponse
        }

        return try ClaudeUsageDecoder.decode(
            finalOutput,
            fetchedAt: .now,
            provider: identity
        )
    }

    public func updates() async -> AsyncStream<UsageSnapshot> {
        AsyncStream { $0.finish() }
    }

    public func disconnect() async {}
}

public enum ClaudeUsageDecoder {
    public static func decode(
        _ terminalOutput: String,
        fetchedAt: Date,
        provider: ProviderIdentity,
        calendar: Calendar = .current,
        timeZone: TimeZone = .current
    ) throws -> UsageSnapshot {
        let text = stripTerminalControls(from: terminalOutput)

        // 1. プラン種別の判定
        var planType: String? = nil
        let planPattern = #"Claude\s+(Pro|Max|Team|Enterprise|Free)"#
        if let planRegex = try? NSRegularExpression(pattern: planPattern, options: .caseInsensitive),
           let match = planRegex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
           let range = Range(match.range, in: text) {
            planType = String(text[range])
        }

        // 2. クレジット情報の判定
        var creditsBalance: String? = nil
        let creditsAreUnlimited: Bool? = nil
        if text.localizedCaseInsensitiveContains("Usage credits are off") || text.localizedCaseInsensitiveContains("credits are off") {
            creditsBalance = "オフ"
        } else if text.localizedCaseInsensitiveContains("Usage credits are on") || text.localizedCaseInsensitiveContains("credits are on") {
            creditsBalance = "オン"
        }
        let creditsPattern = #"Usage credits:\s*(\$[0-9]+(?:\.[0-9]+)?)"#
        if let regex = try? NSRegularExpression(pattern: creditsPattern, options: .caseInsensitive),
           let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
           let range = Range(match.range(at: 1), in: text) {
            creditsBalance = String(text[range])
        }

        // 3. 制限定義テーブル
        let knownDefinitions: [(header: String, id: String, name: String, durationMinutes: Int)] = [
            (header: "Current session", id: "claude-session", name: "セッション（5時間）", durationMinutes: 5 * 60),
            (header: "Current week (all models)", id: "claude-week-all", name: "週次（全モデル）", durationMinutes: 7 * 24 * 60),
            (header: "Current week (Sonnet only)", id: "claude-week-sonnet", name: "週次（Sonnet）", durationMinutes: 7 * 24 * 60),
            (header: "Current week (Opus only)", id: "claude-week-opus", name: "週次（Opus）", durationMinutes: 7 * 24 * 60),
        ]

        var limits: [UsageLimit] = []
        var processedHeaders = Set<String>()

        for def in knownDefinitions {
            if let window = decodeWindow(
                named: def.header,
                in: text,
                durationMinutes: def.durationMinutes,
                fetchedAt: fetchedAt,
                calendar: calendar,
                timeZone: timeZone
            ) {
                limits.append(UsageLimit(id: def.id, displayName: def.name, primary: window))
                processedHeaders.insert(def.header)
            }
        }

        // 未知の "Current week (...)" モデル制限の動的検出
        let dynamicPattern = #"Current week \(([^)]+)\)"#
        if let dynRegex = try? NSRegularExpression(pattern: dynamicPattern) {
            let matches = dynRegex.matches(in: text, range: NSRange(text.startIndex..., in: text))
            for match in matches {
                guard let fullRange = Range(match.range, in: text),
                      let modelRange = Range(match.range(at: 1), in: text) else { continue }
                let fullHeader = String(text[fullRange])
                if processedHeaders.contains(fullHeader) { continue }
                let modelName = String(text[modelRange])
                if let window = decodeWindow(
                    named: fullHeader,
                    in: text,
                    durationMinutes: 7 * 24 * 60,
                    fetchedAt: fetchedAt,
                    calendar: calendar,
                    timeZone: timeZone
                ) {
                    let sanitizedId = "claude-week-\(modelName.lowercased().replacingOccurrences(of: " ", with: "-"))"
                    limits.append(UsageLimit(id: sanitizedId, displayName: "週次（\(modelName)）", primary: window))
                    processedHeaders.insert(fullHeader)
                }
            }
        }

        guard !limits.isEmpty else {
            throw UsageProviderError.unsupportedResponse
        }

        return UsageSnapshot(
            fetchedAt: fetchedAt,
            provider: provider,
            limits: limits,
            planType: planType,
            creditsBalance: creditsBalance,
            creditsAreUnlimited: creditsAreUnlimited
        )
    }

    private static func decodeWindow(
        named name: String,
        in fullText: String,
        durationMinutes: Int,
        fetchedAt: Date,
        calendar: Calendar,
        timeZone: TimeZone
    ) -> UsageWindow? {
        var searchRange = fullText.startIndex..<fullText.endIndex
        var ranges: [Range<String.Index>] = []
        while let found = fullText.range(of: name, range: searchRange) {
            ranges.append(found)
            searchRange = found.upperBound..<fullText.endIndex
        }
        // print("[DEBUG] name=\(name) ranges=\(ranges.count)")

        for nameRange in ranges.reversed() {
            let remainder = String(fullText[nameRange.upperBound...])
            let section = String(remainder.prefix(250))

            // 使用率のパース（例: "0%used", "15% used", "100% used"）
            let percentPattern = #"([0-9]+(?:\.[0-9]+)?)\s*%\s*used"#
            guard let percentRegex = try? NSRegularExpression(pattern: percentPattern, options: .caseInsensitive),
                  let match = percentRegex.firstMatch(in: section, range: NSRange(section.startIndex..., in: section)),
                  let percentRange = Range(match.range(at: 1), in: section),
                  let usedValue = Double(section[percentRange]) else {
                continue
            }

            let usedPercent = Int(usedValue.rounded())
            let resetDate = parseResetDate(in: section, fetchedAt: fetchedAt, calendar: calendar, fallbackTimeZone: timeZone)

            return UsageWindow(
                usedPercent: usedPercent,
                durationMinutes: durationMinutes,
                resetsAt: resetDate
            )
        }

        return nil
    }

    private static func parseResetDate(
        in section: String,
        fetchedAt: Date,
        calendar: Calendar,
        fallbackTimeZone: TimeZone
    ) -> Date? {
        let resetPattern = #"Resets\s+([^\r\n\+\*]+)"#
        guard let resetRegex = try? NSRegularExpression(pattern: resetPattern, options: .caseInsensitive),
              let match = resetRegex.firstMatch(in: section, range: NSRange(section.startIndex..., in: section)),
              let rawRange = Range(match.range(at: 1), in: section) else {
            return nil
        }
        let rawStr = String(section[rawRange]).trimmingCharacters(in: .whitespacesAndNewlines)

        // タイムゾーンの抽出（例: "(Asia/Tokyo)"）
        var targetTimeZone = fallbackTimeZone
        let tzPattern = #"\(([^)]+)\)"#
        if let tzRegex = try? NSRegularExpression(pattern: tzPattern),
           let tzMatch = tzRegex.firstMatch(in: rawStr, range: NSRange(rawStr.startIndex..., in: rawStr)),
           let tzRange = Range(tzMatch.range(at: 1), in: rawStr) {
            let tzName = String(rawStr[tzRange])
            if let tz = TimeZone(identifier: tzName) ?? TimeZone(abbreviation: tzName) {
                targetTimeZone = tz
            }
        }

        var cal = calendar
        cal.timeZone = targetTimeZone

        let monthMap: [String: Int] = [
            "jan": 1, "feb": 2, "mar": 3, "apr": 4, "may": 5, "jun": 6,
            "jul": 7, "aug": 8, "sep": 9, "oct": 10, "nov": 11, "dec": 12
        ]

        // パターン1: 日付＋時刻（例: "Aug 28 at 2:59am", "Aug 28 at 3am"）
        let dateTimePattern = #"([A-Za-z]{3,9})\s+([0-9]{1,2})\s+at\s+([0-9]{1,2})(?::([0-9]{2}))?\s*(am|pm)"#
        if let regex = try? NSRegularExpression(pattern: dateTimePattern, options: .caseInsensitive),
           let dtMatch = regex.firstMatch(in: rawStr, range: NSRange(rawStr.startIndex..., in: rawStr)),
           let mRange = Range(dtMatch.range(at: 1), in: rawStr),
           let dRange = Range(dtMatch.range(at: 2), in: rawStr),
           let hRange = Range(dtMatch.range(at: 3), in: rawStr),
           let ampmRange = Range(dtMatch.range(at: 5), in: rawStr) {
            let monthStr = String(rawStr[mRange]).prefix(3).lowercased()
            guard let month = monthMap[monthStr],
                  let day = Int(rawStr[dRange]),
                  let hourRaw = Int(rawStr[hRange]) else { return nil }
            let minute: Int
            if dtMatch.range(at: 4).location != NSNotFound, let minRange = Range(dtMatch.range(at: 4), in: rawStr) {
                minute = Int(rawStr[minRange]) ?? 0
            } else {
                minute = 0
            }
            let isPM = rawStr[ampmRange].lowercased() == "pm"
            let hour = isPM ? (hourRaw == 12 ? 12 : hourRaw + 12) : (hourRaw == 12 ? 0 : hourRaw)

            let year = cal.component(.year, from: fetchedAt)
            var components = DateComponents(calendar: cal, timeZone: targetTimeZone, year: year, month: month, day: day, hour: hour, minute: minute, second: 0)
            if let date = cal.date(from: components) {
                if date < fetchedAt.addingTimeInterval(-180 * 24 * 3600) {
                    components.year = year + 1
                    return cal.date(from: components)
                }
                return date
            }
        }

        // パターン2: 時刻のみ（例: "12:50am", "3:00pm", "3am"）
        let timePattern = #"([0-9]{1,2})(?::([0-9]{2}))?\s*(am|pm)"#
        if let regex = try? NSRegularExpression(pattern: timePattern, options: .caseInsensitive),
           let tMatch = regex.firstMatch(in: rawStr, range: NSRange(rawStr.startIndex..., in: rawStr)),
           let hRange = Range(tMatch.range(at: 1), in: rawStr),
           let ampmRange = Range(tMatch.range(at: 3), in: rawStr) {
            guard let hourRaw = Int(rawStr[hRange]) else { return nil }
            let minute: Int
            if tMatch.range(at: 2).location != NSNotFound, let minRange = Range(tMatch.range(at: 2), in: rawStr) {
                minute = Int(rawStr[minRange]) ?? 0
            } else {
                minute = 0
            }
            let isPM = rawStr[ampmRange].lowercased() == "pm"
            let hour = isPM ? (hourRaw == 12 ? 12 : hourRaw + 12) : (hourRaw == 12 ? 0 : hourRaw)

            let year = cal.component(.year, from: fetchedAt)
            let month = cal.component(.month, from: fetchedAt)
            let day = cal.component(.day, from: fetchedAt)
            let components = DateComponents(calendar: cal, timeZone: targetTimeZone, year: year, month: month, day: day, hour: hour, minute: minute, second: 0)
            if let date = cal.date(from: components) {
                if date < fetchedAt.addingTimeInterval(-60) {
                    return cal.date(byAdding: .day, value: 1, to: date)
                }
                return date
            }
        }

        // パターン3: 相対時間（例: "3h 20m", "45m"）
        return parseDuration(rawStr).map { fetchedAt.addingTimeInterval($0) }
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
            "\u{001B}\\[[0-9;?<=>]*[ -/]*[@-~a-zA-Z]",
            "\u{001B}\\][^\u{0007}\u{001B}]*(?:\u{0007}|\u{001B}\\\\)",
            "\u{001B}[()][A-Za-z0-9]",
            "\u{001B}[>=<]",
        ]
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            result = regex.stringByReplacingMatches(in: result, range: NSRange(result.startIndex..., in: result), withTemplate: "")
        }
        return result.replacingOccurrences(of: "\u{0008}", with: "")
    }
}
