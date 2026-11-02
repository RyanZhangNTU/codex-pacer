import Darwin
import Foundation
import XCTest

@_silgen_name("backtrace")
private func quotaDiagnosticBacktrace(_ frames: UnsafeMutablePointer<UnsafeMutableRawPointer?>, _ count: Int32) -> Int32
@_silgen_name("backtrace_symbols_fd")
private func quotaDiagnosticSymbols(_ frames: UnsafeMutablePointer<UnsafeMutableRawPointer?>, _ count: Int32, _ descriptor: Int32)

// Temporary CI-only crash tracing. It records stack symbols, never app state.
final class AQuotaAbortDiagnosticsTests: XCTestCase {
    func testInstallTemporaryAbortTrace() {
        guard ProcessInfo.processInfo.environment["GITHUB_ACTIONS"] == "true" else { return }
        signal(SIGABRT) { code in
            let frames = UnsafeMutablePointer<UnsafeMutableRawPointer?>.allocate(capacity: 128)
            let count = quotaDiagnosticBacktrace(frames, 128)
            quotaDiagnosticSymbols(frames, count, STDERR_FILENO)
            _exit(128 + code)
        }
    }
}
