import Foundation
import XCTest
@testable import AgentMeterCore

final class AntigravityUsageDecoderTests: XCTestCase {
    func testDecodesBothModelGroupsAndResetDurations() throws {
        let fetchedAt = Date(timeIntervalSince1970: 1_000)
        let output = """
        \u{001B}[2J└ Models & Quota
        GEMINI MODELS
          Models within this group: Gemini Flash, Gemini Pro
          Weekly Limit Remaining
            [████] 95.85%
            96% remaining · Refreshes in 25h 31m
          Five Hour Limit Remaining
            [████] 99.41%
            99% remaining · Refreshes in 4h 57m
        CLAUDE AND GPT MODELS
          Models within this group: Claude Opus, Claude Sonnet, GPT-OSS
          Weekly Limit Remaining
            [████] 80.00%
            80% remaining · Refreshes in 2d 3h
          Five Hour Limit Remaining
            [████] 100.00%
            Quota available
        """

        let snapshot = try AntigravityUsageDecoder.decode(
            output,
            fetchedAt: fetchedAt,
            provider: ProviderIdentity(name: "Antigravity CLI", version: "test")
        )

        XCTAssertEqual(snapshot.limits.map(\.id), [
            "gemini-weekly", "gemini-five-hour", "claude-gpt-weekly", "claude-gpt-five-hour",
        ])
        XCTAssertEqual(snapshot.limits[0].primary?.remainingPercent, 96)
        XCTAssertEqual(snapshot.limits[0].primary?.resetsAt, fetchedAt.addingTimeInterval(25 * 60 * 60 + 31 * 60))
        XCTAssertEqual(snapshot.limits[1].primary?.remainingPercent, 99)
        XCTAssertEqual(snapshot.limits[2].primary?.remainingPercent, 80)
        XCTAssertEqual(snapshot.limits[2].primary?.resetsAt, fetchedAt.addingTimeInterval(2 * 24 * 60 * 60 + 3 * 60 * 60))
        XCTAssertEqual(snapshot.limits[3].primary?.remainingPercent, 100)
        XCTAssertNil(snapshot.limits[3].primary?.resetsAt)
    }

    func testRejectsUnrelatedTerminalOutput() {
        XCTAssertThrowsError(
            try AntigravityUsageDecoder.decode(
                "Antigravity CLI is ready",
                fetchedAt: .now,
                provider: ProviderIdentity(name: "Antigravity CLI", version: "test")
            )
        )
    }
}
