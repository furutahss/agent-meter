import Foundation
import XCTest
@testable import AgentMeterCore

final class CoreLifecycleTests: XCTestCase {
    private let provider = ProviderIdentity(name: "test", version: "1")

    func testWindowClampsAndCalculatesRemaining() {
        XCTAssertEqual(UsageWindow(usedPercent: -2).usedPercent, 0)
        XCTAssertEqual(UsageWindow(usedPercent: 121).remainingPercent, 0)
    }

    func testFreshnessBoundaries() {
        let now = Date(timeIntervalSince1970: 100_000)
        XCTAssertEqual(UsageFreshness.status(of: snapshot(at: now.addingTimeInterval(-899)), now: now), .fresh)
        XCTAssertEqual(UsageFreshness.status(of: snapshot(at: now.addingTimeInterval(-901)), now: now), .stale)
        XCTAssertEqual(UsageFreshness.status(of: snapshot(at: now.addingTimeInterval(-86_401)), now: now), .expired)
    }

    func testSparseUpdatePreservesMissingFieldsAndAddsLimit() {
        let current = UsageSnapshot(
            fetchedAt: .distantPast,
            provider: provider,
            limits: [UsageLimit(id: "main", displayName: "Main", primary: UsageWindow(usedPercent: 20), secondary: UsageWindow(usedPercent: 30))],
            planType: "plus"
        )
        let update = UsageSnapshot(
            fetchedAt: .now,
            provider: provider,
            limits: [UsageLimit(id: "main", primary: UsageWindow(usedPercent: 40)), UsageLimit(id: "extra", primary: UsageWindow(usedPercent: 10))]
        )
        let merged = UsageSnapshotMerger.merge(current: current, update: update)
        XCTAssertEqual(merged.limits.map(\.id), ["main", "extra"])
        XCTAssertEqual(merged.limits[0].displayName, "Main")
        XCTAssertEqual(merged.limits[0].primary?.usedPercent, 40)
        XCTAssertEqual(merged.limits[0].secondary?.usedPercent, 30)
        XCTAssertEqual(merged.planType, "plus")
    }

    func testCacheRoundTripAndRemoval() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("usage.json")
        let cache = UsageCache(fileURL: url)
        let value = snapshot(at: .now)
        try await cache.save(value)
        let loaded = try await cache.load()
        XCTAssertEqual(loaded, value)
        try await cache.remove()
        let removed = try await cache.load()
        XCTAssertNil(removed)
    }

    func testCacheContainsOnlyUsageSnapshotFields() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("usage.json")
        let cache = UsageCache(fileURL: url)
        try await cache.save(snapshot(at: .now))

        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        XCTAssertEqual(Set(json.keys), ["fetchedAt", "provider", "limits"])
        XCTAssertFalse(json.description.localizedCaseInsensitiveContains("token"))
        XCTAssertFalse(json.description.localizedCaseInsensitiveContains("authorization"))
        XCTAssertFalse(json.description.localizedCaseInsensitiveContains("password"))

        try await cache.remove()
    }

    func testBackoffCapsAtFifteenMinutesAndResets() {
        var backoff = RefreshBackoff()
        for _ in 0..<5 { backoff.registerFailure() }
        XCTAssertEqual(backoff.baseDelay, .seconds(15 * 60))
        backoff.registerSuccess()
        XCTAssertEqual(backoff.consecutiveFailures, 0)
        XCTAssertEqual(backoff.baseDelay, .seconds(60))
    }

    func testProviderTimeoutDoesNotHang() async {
        let appServer = AppServerProvider(
            executableURL: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "while IFS= read -r line; do :; done"],
            timeout: .milliseconds(50)
        )
        do {
            _ = try await appServer.fetchSnapshot()
            XCTFail("timeout expected")
        } catch let error as UsageProviderError {
            XCTAssertEqual(error, .timedOut)
        } catch {
            XCTFail("unexpected error: \(error)")
        }
        await appServer.disconnect()
    }

    private func snapshot(at date: Date) -> UsageSnapshot {
        UsageSnapshot(fetchedAt: date, provider: provider, limits: [UsageLimit(id: "main", primary: UsageWindow(usedPercent: 10))])
    }
}
