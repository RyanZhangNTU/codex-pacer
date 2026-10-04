import XCTest
@testable import PacerCore

final class CodexDiagnosticTests: XCTestCase {
    func testSensitiveFieldsAreRedactedButFailureRemainsUseful() {
        let input = """
        HTTP 403: workspace rejected. Authorization: Bearer secret-bearer-value
        {"access_token":"secret-access-value","refreshToken":"secret-refresh-value","email":"ryan@example.test","account_id":"account-private"}
        OPENAI_API_KEY=sk-proj-1234567890abcdef
        https://example.test/login?code=private-code&state=opaque
        """
        let result = CodexDiagnosticText.sanitized(input)
        XCTAssertTrue(result.contains("HTTP 403: workspace rejected"))
        for secret in ["secret-bearer-value", "secret-access-value", "secret-refresh-value", "ryan@example.test",
                       "account-private", "sk-proj-1234567890abcdef", "private-code"] {
            XCTAssertFalse(result.contains(secret), secret)
        }
    }
    func testTerminalControlCodesAndLargeLogsAreBounded() {
        let result = CodexDiagnosticText.sanitized("\u{001B}[31mConnection refused\u{001B}[0m\n" + String(repeating: "x", count: 20_000), limit: 120)
        XCTAssertTrue(result.hasPrefix("Connection refused"))
        XCTAssertFalse(result.contains("\u{001B}"))
        XCTAssertLessThan(result.count, 160)
    }
    func testRepeatedSanitizationDoesNotAccumulateRedactionMarkers() {
        let input = "HTTP 403: access_token=private-value Authorization: Bearer private-bearer OPENAI_API_KEY=sk-proj-1234567890abcdef"
        let once = CodexDiagnosticText.sanitized(input)
        XCTAssertEqual(CodexDiagnosticText.sanitized(once), once)
        XCTAssertFalse(once.contains("]]"))
        XCTAssertFalse(once.contains(L10n.text("redaction.hidden") + " " + L10n.text("redaction.hidden")))
    }
    func testRpcAndTimeoutDescriptionsNameTheFailingOperation() {
        let failure = CodexClientError.server(method: "account/rateLimits/read", code: -32601, message: "Method not found")
        XCTAssertTrue(failure.localizedDescription.contains("account/rateLimits/read"))
        XCTAssertTrue(failure.localizedDescription.contains("-32601"))
        XCTAssertTrue(failure.localizedDescription.contains("Method not found"))
        XCTAssertTrue(failure.localizedDescription.contains(L10n.text("cli.unsupported_method")))
        let timeout = CodexClientError.timeout(method: "initialize", seconds: 8)
        XCTAssertTrue(timeout.localizedDescription.contains("initialize"))
        XCTAssertTrue(timeout.localizedDescription.contains("8"))
    }
}
