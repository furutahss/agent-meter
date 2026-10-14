import Testing
import Foundation
@testable import AgentMeterCore

struct ClaudeUsageDecoderTests {
    private let provider = ProviderIdentity(name: "Claude Code", version: "test")

    @Test
    func testDecodesCapturedOutputSuccessfully() throws {
        let terminalOutput = """
        ╭───Claude Code v2.1.239─────────────────────────────────────────────────────────────────────────────╮
        │ Sonnet 5 · Claude Pro · furuta@example.com's Organization                                          │
        ╰────────────────────────────────────────────────────────────────────────────────────────────────────╯
        Settings Status Config Usage Stats
        Session
        Total cost:            $0.0000
        Total duration (API):  0s
        Total duration (wall): 1s
        Total code changes:    0 lines added, 0 lines removed
        Usage:                 0 input, 0 output, 0 cache read, 0 cache write

        Current session                                                  0% used
        Resets 12:49am (Asia/Tokyo)

        Current week (all models)                                                   0% used
        Resets Aug 28 at 2:59am (Asia/Tokyo)
        +50% weekly limits promo through Aug 31 · clau.de/cc-50-promo

        Usage credits
        Usage credits are off · /usage-credits to turn them on
        """

        let baseDate = Date(timeIntervalSince1970: 1724320000) // 2024-08-22 approx
        let tokyoTZ = TimeZone(identifier: "Asia/Tokyo")!
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = tokyoTZ

        let snapshot = try ClaudeUsageDecoder.decode(
            terminalOutput,
            fetchedAt: baseDate,
            provider: provider,
            calendar: cal,
            timeZone: tokyoTZ
        )

        #expect(snapshot.provider.name == "Claude Code")
        #expect(snapshot.planType == "Claude Pro")
        #expect(snapshot.creditsBalance == "オフ")
        #expect(snapshot.limits.count == 2)

        let sessionLimit = snapshot.limits.first { $0.id == "claude-session" }
        #expect(sessionLimit != nil)
        #expect(sessionLimit?.displayName == "セッション（5時間）")
        #expect(sessionLimit?.primary?.usedPercent == 0)
        #expect(sessionLimit?.primary?.remainingPercent == 100)
        #expect(sessionLimit?.primary?.durationMinutes == 300)
        #expect(sessionLimit?.primary?.resetsAt != nil)

        let weekLimit = snapshot.limits.first { $0.id == "claude-week-all" }
        #expect(weekLimit != nil)
        #expect(weekLimit?.displayName == "週次（全モデル）")
        #expect(weekLimit?.primary?.usedPercent == 0)
        #expect(weekLimit?.primary?.remainingPercent == 100)
        #expect(weekLimit?.primary?.durationMinutes == 10080)
        #expect(weekLimit?.primary?.resetsAt != nil)
    }

    @Test
    func testDecodesMultipleModelsAndCustomCredits() throws {
        let output = """
        Claude Max · team-workspace
        Current session                                                  45% used
        Resets 3:00pm (America/New_York)

        Current week (all models)                                        70% used
        Resets Sep 2 at 11:30pm (America/New_York)

        Current week (Sonnet only)                                       20% used
        Resets Sep 2 at 11:30pm (America/New_York)

        Current week (Opus only)                                         90% used
        Resets Sep 2 at 11:30pm (America/New_York)

        Usage credits: $25.50
        """

        let baseDate = Date(timeIntervalSince1970: 1725000000)
        let nyTZ = TimeZone(identifier: "America/New_York")!
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = nyTZ

        let snapshot = try ClaudeUsageDecoder.decode(
            output,
            fetchedAt: baseDate,
            provider: provider,
            calendar: cal,
            timeZone: nyTZ
        )

        #expect(snapshot.planType == "Claude Max")
        #expect(snapshot.creditsBalance == "$25.50")
        #expect(snapshot.limits.count == 4)

        let sessionLimit = snapshot.limits.first { $0.id == "claude-session" }
        #expect(sessionLimit?.primary?.usedPercent == 45)
        #expect(sessionLimit?.primary?.remainingPercent == 55)

        let opusLimit = snapshot.limits.first { $0.id == "claude-week-opus" }
        #expect(opusLimit?.primary?.usedPercent == 90)
        #expect(opusLimit?.primary?.remainingPercent == 10)
    }

    @Test
    func testRejectsUnrelatedOutput() {
        let output = "Welcome to your shell! No limits here."
        #expect(throws: UsageProviderError.unsupportedResponse) {
            try ClaudeUsageDecoder.decode(
                output,
                fetchedAt: .now,
                provider: provider
            )
        }
    }
}
