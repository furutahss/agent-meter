import XCTest
@testable import AgentMeterCore

final class DiagnosticRedactorTests: XCTestCase {
    func testSensitiveValuesAreNotRetained() {
        let input = "Authorization: Bearer secret-value email=user@example.com path=/Users/test/.codex/auth.json"
        let output = DiagnosticRedactor.redact(input)
        XCTAssertFalse(output.contains("secret-value"))
        XCTAssertFalse(output.contains("user@example.com"))
        XCTAssertFalse(output.contains("/Users/test"))
    }
}
