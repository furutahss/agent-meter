import Testing
import Foundation
@testable import AgentMeterCore

struct GrokBillingDecoderTests {
    private let provider = ProviderIdentity(name: "Grok", version: "test")

    @Test
    func testDecodesWeeklyAllowance() throws {
        let json = """
        {
          "config": {
            "creditUsagePercent": 42.4,
            "currentPeriod": {
              "type": "USAGE_PERIOD_TYPE_WEEKLY",
              "start": "2026-10-08T16:35:26.184658+00:00",
              "end": "2026-10-15T16:35:26.184658+00:00"
            },
            "onDemandCap": { "val": 0 },
            "onDemandUsed": { "val": 0 },
            "prepaidBalance": { "val": 0 },
            "billingPeriodEnd": "2026-10-15T16:35:26.184658+00:00"
          },
          "subscription_tier": "X Premium"
        }
        """
        let snapshot = try decode(json)

        #expect(snapshot.provider.name == "Grok")
        #expect(snapshot.planType == "X Premium")
        #expect(snapshot.creditsBalance == nil)
        #expect(snapshot.limits.count == 1)

        let weekly = snapshot.limits[0]
        #expect(weekly.id == "grok-weekly")
        #expect(weekly.displayName == "週次")
        #expect(weekly.primary?.usedPercent == 42)
        #expect(weekly.primary?.remainingPercent == 58)
        #expect(weekly.primary?.durationMinutes == 7 * 24 * 60)
        let expectedReset = try #require(date("2026-10-15T16:35:26Z"))
        let actualReset = try #require(weekly.primary?.resetsAt)
        #expect(abs(actualReset.timeIntervalSince(expectedReset)) < 1)
    }

    @Test
    func testDecodesMonthlyOnDemandAndPrepaidCredits() throws {
        let json = """
        {
          "config": {
            "creditUsagePercent": 15.6,
            "currentPeriod": {
              "type": "USAGE_PERIOD_TYPE_MONTHLY",
              "start": "2026-10-01T00:00:00Z",
              "end": "2026-11-01T00:00:00Z"
            },
            "onDemandCap": { "val": 50 },
            "onDemandUsed": { "val": 12.5 },
            "prepaidBalance": { "val": "10.5" }
          },
          "subscription_tier": "SuperGrok"
        }
        """
        let snapshot = try decode(json)

        #expect(snapshot.planType == "SuperGrok")
        #expect(snapshot.creditsBalance == "$10.50")
        #expect(snapshot.limits.map(\.id) == ["grok-monthly", "grok-on-demand"])
        #expect(snapshot.limits[0].primary?.usedPercent == 16)
        #expect(snapshot.limits[0].primary?.durationMinutes == 31 * 24 * 60)
        #expect(snapshot.limits[1].displayName == "従量課金")
        #expect(snapshot.limits[1].primary?.usedPercent == 25)
    }

    @Test
    func testRejectsResponseWithoutUsage() {
        #expect(throws: UsageProviderError.unsupportedResponse) {
            try decode(#"{"subscription_tier":"X Premium"}"#)
        }
        #expect(throws: UsageProviderError.unsupportedResponse) {
            try decode(#"{"config":{}}"#)
        }
    }

    private func decode(_ json: String) throws -> UsageSnapshot {
        let data = Data(json.utf8)
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        return try GrokBillingDecoder.decode(object, fetchedAt: Date(timeIntervalSince1970: 1_791_952_000), provider: provider)
    }

    private func date(_ value: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: value)
    }
}
