@testable import PacerEngineSupport
#if os(Windows)
import Foundation
import XCTest
import ucrt
@testable import PacerCore

final class WindowsSubprocessTests: XCTestCase {
    private var command: URL {
        let system = ProcessInfo.processInfo.environment["SystemRoot"] ?? "C:\\Windows"
        return URL(fileURLWithPath: system).appendingPathComponent("System32/cmd.exe")
    }

    /// swift-subprocess 1.0 opened `NUL` through the C runtime for every run's
    /// `.none` input and `.discarded` error and never released the descriptor.
    /// Periodic captures used up the runtime's 8,192 descriptors and the engine
    /// stopped. Each kept descriptor raises the lowest free one by one.
    func testCapturesKeepNoRuntimeDescriptors() async throws {
        func lowestFreeDescriptor() -> Int32 {
            var descriptor: Int32 = -1
            guard _sopen_s(&descriptor, "NUL", _O_RDONLY, _SH_DENYNO, 0) == 0 else { return -1 }
            _ = _close(descriptor)
            return descriptor
        }
        let first = await WindowsSubprocess.capture(executable: command, arguments: ["/d", "/c", "echo ready"], timeout: 20, limit: 1024)
        XCTAssertNotNil(first)
        let before = lowestFreeDescriptor()
        XCTAssertGreaterThanOrEqual(before, 0)
        for _ in 0..<20 {
            let output = await WindowsSubprocess.capture(executable: command, arguments: ["/d", "/c", "echo ready"], timeout: 20, limit: 1024)
            XCTAssertNotNil(output)
        }
        // Twenty captures that each kept two descriptors would add forty.
        XCTAssertLessThanOrEqual(lowestFreeDescriptor(), before + 4)
        XCTAssertEqual(WindowsNullDevice.shared?.input, WindowsNullDevice.shared?.input)
    }

    func testCapturedChildReadsEndOfInputAndDropsErrors() async throws {
        let result = await WindowsSubprocess.capture(executable: command,
            arguments: ["/d", "/c", "set /p ignored= & echo hidden 1>&2 & echo shown"], timeout: 20, limit: 1024)
        XCTAssertEqual(result.map { String(decoding: $0, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) }, "shown")
    }

    func testOwnedChildCapturesBoundedOutputAndReportsFailure() async throws {
        let result = await WindowsSubprocess.capture(executable: command,
            arguments: ["/d", "/c", "echo pacer-fixture"], timeout: 20, limit: 1024)
        XCTAssertEqual(result.map { String(decoding: $0, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) }, "pacer-fixture")
        let failed = await WindowsSubprocess.capture(executable: command,
            arguments: ["/d", "/c", "exit 7"], timeout: 20, limit: 1024)
        XCTAssertNil(failed)
    }

    func testIPv6NormalizationRejectsShellSyntax() {
        XCTAssertEqual(WindowsIP.normalizedIPv6("2001:0db8::1"), "2001:db8::1")
        XCTAssertNil(WindowsIP.normalizedIPv6("::1 & ignored"))
        XCTAssertFalse(ClaudeSSHRouteResolver.validDestination("host;ignored"))
    }
}
#endif
