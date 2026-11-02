import Foundation
import XCTest
@testable import PacerCore

final class EngineReminderTests: XCTestCase {
    func testNoticeBodiesRedactBeforeIPCAndPreserveNonProjectQuotaDetails() throws {
        for kind in [IslandNotice.Kind.waitingForInput, .completed, .interrupted] {
            let value = IslandNotice(id: "synthetic-notice", kind: kind, title: "Codex", detail: "Private synthetic project")
            let visible = EngineNotice(value, hideProjects: false), hidden = EngineNotice(value, hideProjects: true)
            XCTAssertTrue(try XCTUnwrap(visible.body).contains(value.detail))
            XCTAssertFalse(try XCTUnwrap(visible.privateBody).contains(value.detail))
            XCTAssertEqual(hidden.body, hidden.privateBody)
            let frame = String(decoding: try JSONEncoder().encode(hidden), as: UTF8.self)
            XCTAssertFalse(frame.contains(value.detail), "A hidden notice must be safe before it enters the pipe")
        }
        let quota = IslandNotice(id: "synthetic-balance", kind: .lowQuota, title: "DeepSeek", detail: "¥9.00", category: DeepSeekNoticePolicy.balanceCategory)
        let hidden = EngineNotice(quota, hideProjects: true)
        XCTAssertEqual(hidden.body, EngineNotice(quota, hideProjects: false).body)
        XCTAssertTrue(try XCTUnwrap(hidden.privateBody).contains("¥9.00"))
        XCTAssertEqual(hidden.actions?.map(\.kind), ["topUp"])
    }
    func testBudgetTransitionsActionsSnoozeAndAtomicReminderConfiguration() async throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000), capture = ReminderCapture()
        let runtime = EngineRuntime(demo: true, now: { now }, output: { capture.append($0) })
        func command(_ method: String, _ params: [String: Any] = [:]) throws -> Data {
            try JSONSerialization.data(withJSONObject: ["protocolVersion": 1, "id": UUID().uuidString, "method": method, "params": params])
        }
        func reminders(_ warnings: [String] = ["lowBalance", "spendSpike", "budget"], low: Double? = nil, spike: Double? = 1000) -> [String: Any] {
            ["warnings": warnings, "lowLine": low.map { $0 as Any } ?? NSNull(), "spikeLine": spike.map { $0 as Any } ?? NSNull()]
        }
        func budget(_ daily: Double) -> [String: Any] {
            ["mode": "budget", "daily": daily, "weekly": NSNull(), "ringPeriod": "day", "speedSource": "local", "showsTurnCost": true]
        }
        _ = await runtime.receive(try command("initialize", ["enabledProviders": ["deepseek"], "deepseekSettings": budget(1000), "reminderSettings": reminders()]))
        let initial = try XCTUnwrap(capture.last()), wallet = try XCTUnwrap(initial.wallet)
        let spent = wallet.today + wallet.elsewhere
        XCTAssertGreaterThan(spent, 0); XCTAssertTrue(initial.notices.isEmpty, "Historical spend establishes a quiet baseline")
        XCTAssertNotNil(initial.wallet?.reminders?.lowPlaceholder); XCTAssertNotNil(initial.wallet?.reminders?.spikePlaceholder)
        _ = await runtime.receive(try command("configure", ["deepseekSettings": budget(spent / 0.9)]))
        let near = try XCTUnwrap(capture.last())
        XCTAssertEqual(near.notices.count, 1); XCTAssertTrue(near.notices[0].id.hasPrefix("deepseek:budget:day")); XCTAssertNil(near.notices[0].category)
        XCTAssertNotNil(near.notices[0].body); XCTAssertEqual(near.wallet?.alert?.kind, .nearingBudget)
        _ = await runtime.receive(try command("configure", ["deepseekSettings": budget(spent / 1.1)]))
        XCTAssertEqual(capture.last()?.notices.count, 1); XCTAssertEqual(capture.last()?.compactWarnings?.map(\.kind), [.overBudget])
        _ = await runtime.receive(try command("refresh")); XCTAssertTrue(capture.last()?.notices.isEmpty == true)
        _ = await runtime.receive(try command("configure", ["reminderSettings": reminders([], spike: 0.00001)]))
        XCTAssertNil(capture.last()?.wallet?.alert)
        _ = await runtime.receive(try command("configure", ["reminderSettings": reminders(spike: 0.00001)]))
        XCTAssertTrue(capture.last()?.notices.isEmpty == true, "Re-enabling a kind must not replay a spike that began while disabled")
        _ = await runtime.receive(try command("configure", ["reminderSettings": reminders()]))
        _ = await runtime.receive(try command("configure", ["reminderSettings": reminders(spike: 0.00001)]))
        let spike = try XCTUnwrap(capture.last()?.notices.first)
        XCTAssertEqual(spike.category, DeepSeekNoticePolicy.spikeCategory); XCTAssertEqual(spike.actions?.map(\.kind), ["openHarness", "snoozeSpike"])
        _ = await runtime.receive(try command("snoozeDeepSeekSpike"))
        _ = await runtime.receive(try command("configure", ["reminderSettings": reminders()]))
        _ = await runtime.receive(try command("configure", ["reminderSettings": reminders(spike: 0.00001)]))
        XCTAssertTrue(capture.last()?.notices.isEmpty == true, "Snooze suppresses new crossings in this hour")
        let title = capture.last()?.presentation.rows.first?.title
        _ = await runtime.receive(try command("configure", ["hideProjects": true, "reminderSettings": reminders(["unknown"])]))
        _ = await runtime.receive(try command("refresh"))
        XCTAssertEqual(capture.last()?.presentation.rows.first?.title, title, "The complete invalid update is rejected atomically")
        _ = await runtime.receive(try command("configure", ["reminderSettings": reminders(low: 1000)]))
        let balance = try XCTUnwrap(capture.last()?.notices.first)
        XCTAssertEqual(balance.category, DeepSeekNoticePolicy.balanceCategory); XCTAssertEqual(balance.actions?.map(\.kind), ["topUp"])
        _ = await runtime.receive(try command("configure", ["hideProjects": true]))
        _ = await runtime.receive(try command("demoStage", ["demoStage": 3]))
        XCTAssertTrue(capture.last()?.notices.allSatisfy { $0.kind == "lowQuota" || $0.body == $0.privateBody } == true)
        await runtime.stop()
    }
}
private final class ReminderCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var snapshot: EngineSnapshot?
    func append(_ data: Data) { guard let value = try? JSONDecoder().decode(EngineSnapshot.self, from: data) else { return }; lock.lock(); defer { lock.unlock() }; snapshot = value }
    func last() -> EngineSnapshot? { lock.lock(); defer { lock.unlock() }; return snapshot }
}
