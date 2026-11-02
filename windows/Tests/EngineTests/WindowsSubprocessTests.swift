#if os(Windows)
import Foundation
import XCTest
@testable import PacerCore

final class WindowsSubprocessTests: XCTestCase {
    func testOwnedChildCapturesBoundedOutputAndReportsFailure() async throws {
        let system = ProcessInfo.processInfo.environment["SystemRoot"] ?? "C:\\Windows"
        let command = URL(fileURLWithPath: system).appendingPathComponent("System32/cmd.exe")
        let result = await WindowsSubprocess.capture(executable: command,
            arguments: ["/d", "/c", "echo pacer-fixture"], timeout: 3, limit: 1024)
        XCTAssertEqual(result.map { String(decoding: $0, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) }, "pacer-fixture")
        let failed = await WindowsSubprocess.capture(executable: command,
            arguments: ["/d", "/c", "exit 7"], timeout: 3, limit: 1024)
        XCTAssertNil(failed)
    }

    func testIPv6NormalizationRejectsShellSyntax() {
        XCTAssertEqual(WindowsIP.normalizedIPv6("2001:0db8::1"), "2001:db8::1")
        XCTAssertNil(WindowsIP.normalizedIPv6("::1 & ignored"))
        XCTAssertFalse(ClaudeSSHRouteResolver.validDestination("host;ignored"))
    }
}
#endif
