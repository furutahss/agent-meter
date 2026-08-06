import AgentMeterCore
import XCTest

final class AgentMeterTests: XCTestCase {
    func testProviderIdentityPreservesValues() {
        let identity = ProviderIdentity(name: "demo", version: "1.0")
        XCTAssertEqual(identity.name, "demo")
        XCTAssertEqual(identity.version, "1.0")
    }

    func testNotificationPolicySuppressesDuplicatesAndRearmsAfterRecovery() {
        var policy = UsageNotificationPolicy(threshold: 20)
        let provider = ProviderIdentity(name: "test", version: "1")
        func snapshot(used: Int) -> UsageSnapshot {
            UsageSnapshot(
                fetchedAt: .now,
                provider: provider,
                limits: [UsageLimit(id: "primary", primary: UsageWindow(usedPercent: used, durationMinutes: 300, resetsAt: Date(timeIntervalSince1970: 100)))])
        }

        XCTAssertTrue(policy.alerts(for: snapshot(used: 70)).isEmpty)
        XCTAssertEqual(policy.alerts(for: snapshot(used: 80)).map(\.remainingPercent), [20])
        XCTAssertTrue(policy.alerts(for: snapshot(used: 85)).isEmpty)
        XCTAssertTrue(policy.alerts(for: snapshot(used: 60)).isEmpty)
        XCTAssertEqual(policy.alerts(for: snapshot(used: 90)).map(\.remainingPercent), [10])
    }
}
