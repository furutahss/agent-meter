import XCTest
@testable import AgentMeterCore

final class AppServerResponseDecoderTests: XCTestCase {
    func testGeneratedSchemaFixtureDecodesAndClampsValues() throws {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "rate-limits-0.144.1", withExtension: "json"))
        let result = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])

        let snapshot = try AppServerResponseDecoder.decode(
            result,
            fetchedAt: Date(timeIntervalSince1970: 0),
            provider: ProviderIdentity(name: "fixture", version: "0.144.1")
        )

        XCTAssertEqual(snapshot.limits.count, 2)
        XCTAssertEqual(snapshot.limits.first(where: { $0.id == "codex" })?.primary?.usedPercent, 34)
        XCTAssertEqual(snapshot.limits.first(where: { $0.id == "extra_pool" })?.primary?.usedPercent, 100)
        XCTAssertEqual(snapshot.planType, "plus")
    }

    func testOneHundredFixtureDecodesDoNotLeakState() throws {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "rate-limits-0.144.1", withExtension: "json"))
        let result = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        for _ in 0..<100 {
            let snapshot = try AppServerResponseDecoder.decode(result, fetchedAt: .now, provider: ProviderIdentity(name: "fixture", version: "0.144.1"))
            XCTAssertEqual(snapshot.limits.count, 2)
        }
    }

    func testOlderCLICompatibilityFixtureDecodes() throws {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "rate-limits-0.142.5", withExtension: "json"))
        let result = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        let snapshot = try AppServerResponseDecoder.decode(result, fetchedAt: .now, provider: ProviderIdentity(name: "fixture", version: "0.142.5"))
        XCTAssertEqual(snapshot.limits.first?.id, "codex")
        XCTAssertEqual(snapshot.limits.first?.primary?.usedPercent, 25)
    }

    func testMissingRateLimitsIsUnsupported() {
        XCTAssertThrowsError(try AppServerResponseDecoder.decode([:], fetchedAt: .now, provider: ProviderIdentity(name: "fixture", version: "0")))
    }
}
