import XCTest
@testable import PacerMacSupport

final class DurableCatalogPacingTests: XCTestCase {
    /// Each reading advances a fake clock, so long intervals finish in milliseconds.
    private final class Clock: @unchecked Sendable {
        private(set) var now = Date(timeIntervalSince1970: 1_800_000_000)
        private(set) var reads = 0
        func read() -> Date { reads += 1; now = now.addingTimeInterval(10); return now }
    }

    func testOpenPanelShortensIdleWaitAndDarkDisplayHoldsThenReadsOnWake() async throws {
        let idle = Clock()
        try await MacDurableCatalog.pace(MacDurableCatalog.idleInterval, panelInView: { false }, isDark: { false }, clock: idle.read, step: 0.001)
        let open = Clock()
        try await MacDurableCatalog.pace(MacDurableCatalog.idleInterval, panelInView: { true }, isDark: { false }, clock: open.read, step: 0.001)
        XCTAssertGreaterThan(idle.reads, open.reads)
        XCTAssertGreaterThanOrEqual(idle.now.timeIntervalSince1970 - 1_800_000_000, MacDurableCatalog.idleInterval)

        // While dark nothing is due, however long it lasts; lighting reads at once.
        var checks = 0
        let dark = Clock()
        try await MacDurableCatalog.pace(1, panelInView: { false }, isDark: { checks += 1; return checks < 50 }, clock: dark.read, step: 0.001)
        XCTAssertEqual(checks, 50)
        XCTAssertEqual(dark.reads, 1)
    }
}
