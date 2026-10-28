import AppKit
import XCTest
@testable import PacerCore
@testable import PacerIsland

@MainActor
final class CompactComponentDisplayTests: XCTestCase {
    private func activity(_ id: String, turn: String = "turn", start: Date, first: Date?, remote: Bool = false) -> SessionActivity {
        var value = SessionActivity(id: id, sourceHostID: remote ? "remote-ssh-discovered:fixture" : nil, phaseAwareRate: true)
        value.consumeLive(["method": "turn/started", "threadId": id, "turnId": turn, "at": start.timeIntervalSince1970])
        if let first {
            value.consumeLive(["method": "item/agentMessage/delta", "threadId": id, "turnId": turn,
                "at": first.timeIntervalSince1970, "hasText": true])
        }
        return value
    }
    func testExpandedHeaderQuietsOnlyQuotaValuesAndRowsShowTurnTime() {
        let quieted = CompactIslandLayout.Component.allCases.filter(CompactIslandComponent.dimsWhenExpanded)
        XCTAssertEqual(Set(quieted), [.quota, .quotaGauge, .priceClock, .quotaLabel, .timeRemaining],
            "Status, rate and warnings stay at full strength while the rings repeat quota below")
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let running = activity("019a0000-0000-7000-8000-00000000e1a9", start: start, first: start.addingTimeInterval(2))
        XCTAssertEqual(TaskRowView.turnTimeText(running, phase: .running, now: start.addingTimeInterval(95)),
            L10n.text("dashboard.countdown_minutes", 1))
        XCTAssertEqual(TaskRowView.turnTimeText(running, phase: .running, now: start.addingTimeInterval(30)),
            L10n.text("dashboard.countdown_soon"))
        XCTAssertNil(TaskRowView.turnTimeText(running, phase: .completed, now: start.addingTimeInterval(95)),
            "A turn that has not ended has no total yet")
        XCTAssertNil(TaskRowView.turnTimeText(running, phase: .running, now: start.addingTimeInterval(-5)), "A future start is never shown")
        var ended = running
        ended.consumeLive(["method": "turn/completed", "threadId": ended.id, "turnId": "turn", "status": "completed",
            "at": start.addingTimeInterval(3_725).timeIntervalSince1970])
        XCTAssertEqual(ended.phase, .completed)
        XCTAssertEqual(TaskRowView.turnTimeText(ended, phase: .completed, now: start.addingTimeInterval(90_000)),
            L10n.text("dashboard.countdown_hours", 1, 2), "An ended turn keeps how long it took, not how long ago it ended")
    }
    func testReadEndingsDimWhileUnreadWaitingAndFailedRowsKeepTheirColor() {
        XCTAssertTrue(TaskRowView.isDimmed(phase: .completed, unread: false, attention: false, failed: false))
        XCTAssertTrue(TaskRowView.isDimmed(phase: .interrupted, unread: false, attention: false, failed: false))
        XCTAssertFalse(TaskRowView.isDimmed(phase: .completed, unread: true, attention: false, failed: false))
        XCTAssertFalse(TaskRowView.isDimmed(phase: .interrupted, unread: false, attention: false, failed: true))
        XCTAssertFalse(TaskRowView.isDimmed(phase: .completed, unread: false, attention: true, failed: false))
        XCTAssertFalse(TaskRowView.isDimmed(phase: .running, unread: false, attention: false, failed: false))
        XCTAssertFalse(TaskRowView.isDimmed(phase: .waitingForInput, unread: false, attention: false, failed: false))
        XCTAssertEqual(TaskRowView.middleTruncated("devbox-gpu-03.lab", limit: 16), "devbox-…u-03.lab")
        XCTAssertEqual(TaskRowView.middleTruncated("devbox", limit: 16), "devbox")
        XCTAssertEqual(TaskRowView.shortened("qwen3-coder-480b-a35b-instruct", limit: 22), "qwen3-coder-480b-a35b…")
    }
    func testActivityOrbitSpreadsRunningProvidersEvenlyWithHardEdgedHeads() {
        func stops(_ weights: [Int], animates: Bool = true) -> [String] {
            ActivityOrbit.stops(for: zip(AgentProvider.allCases, weights).map { .init(color: NSColor($0.0.tint), weight: $0.1) },
                                animates: animates)
                .map { String(format: "%.3f@%.2f", $0.location, $0.color.alphaComponent) }
        }
        let idle = { (location: String) in Array(repeating: location + "@0.00", count: 3) }
        XCTAssertEqual(stops([1, 1, 0]),
            ["0.000@0.00", "0.000@1.00", "0.250@0.00", "0.500@0.00", "0.500@1.00", "0.750@0.00"] + idle("0.750"),
            "Two services take opposite halves; heads are hard edges and the gaps stay transparent")
        XCTAssertEqual(stops([1, 0, 1]),
            ["0.000@0.00", "0.000@1.00", "0.250@0.00"] + idle("0.250") + ["0.500@0.00", "0.500@1.00", "0.750@0.00"],
            "Any two running services split the circle in halves, whichever they are")
        XCTAssertEqual(stops([1, 1, 1]),
            ["0.000@0.00", "0.000@1.00", "0.167@0.00", "0.333@0.00", "0.333@1.00", "0.500@0.00", "0.667@0.00", "0.667@1.00", "0.833@0.00"],
            "Three take thirds")
        XCTAssertEqual(stops([3, 1, 0]).prefix(6),
            ["0.000@0.00", "0.000@1.00", "0.375@0.00", "0.500@0.00", "0.500@1.00", "0.625@0.00"],
            "Lengths follow the share of running tasks")
        XCTAssertEqual(stops([0, 2, 0]), idle("0.000") + ["0.000@0.00", "0.000@1.00", "0.340@0.00"] + idle("0.340"),
            "A service alone starts at the top")
        for weights in [[0, 0, 0], [1, 0, 0], [0, 0, 1], [1, 1, 0], [9, 1, 0], [1, 9, 1], [5, 1, 1], [0, 1, 9]] {
            let locations = stops(weights).map { Double($0.prefix(5))! }
            XCTAssertEqual(locations.count, 9, "Equal stop counts let a change ease")
            XCTAssertEqual(locations, locations.sorted()); XCTAssertLessThanOrEqual(locations.last!, 1)
            let heads = stride(from: 0, to: 9, by: 3).map { stops(weights)[$0 + 1] }.filter { $0.hasSuffix("@1.00") }
            XCTAssertEqual(heads.count, weights.filter { $0 > 0 }.count)
        }
        XCTAssertEqual(stops([3, 1, 0], animates: false), ["0.000@0.75", "0.750@0.75", "0.750@0.75", "1.000@0.75"],
            "Without motion the running shares fill the ring")
        XCTAssertEqual(stops([0, 1, 0], animates: false), ["0.000@0.75", "1.000@0.75"])
        // --demo-claude shows both providers' comets, and its completion stage leaves Codex alone.
        let now = Date(timeIntervalSince1970: 1_800_000_000), claude = DemoScenario.claudeTask(stage: .thinking, at: now)
        XCTAssertEqual(claude.provider, .claude); XCTAssertEqual(claude.phase, .running)
        XCTAssertEqual(DemoScenario.claudeTask(stage: .completed, at: now).phase, .completed)
    }
    func testAlternatingQuotaTextStaysSharpWhenValuesArriveAfterItIsOnScreen() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 80, height: 24), styleMask: .borderless, backing: .buffered, defer: false)
        let view = AlternatingQuotaView(frame: NSRect(x: 0, y: 0, width: 60, height: 16))
        window.contentView?.addSubview(view)
        view.update(entries: [.init(text: "58%", color: .white)], animates: false)
        view.update(entries: [.init(text: "58%", color: .white), .init(text: "81%", color: .white)], animates: false)
        let layers = view.layer?.sublayers ?? []
        XCTAssertEqual(layers.count, 2)
        for layer in layers {
            XCTAssertEqual(layer.contentsScale, window.backingScaleFactor, "Text layers made after joining the window draw at the screen's scale")
        }
    }
    func testLatestTTFTUsesMeasurementTimeAndSurvivesToolsNewTurnsAndRemovedCards() async throws {
        let model = IslandModel(), now = Date()
        model.now = now
        let firstID = "019a0000-0000-7000-8000-000000000001", secondID = "019a0000-0000-7000-8000-000000000002"
        var older = activity(firstID, start: now.addingTimeInterval(-20), first: now.addingTimeInterval(-18))
        var latest = activity(secondID, start: now.addingTimeInterval(-30), first: now.addingTimeInterval(-8), remote: true)
        model.activities = [older, latest]
        XCTAssertEqual(try XCTUnwrap(model.latestFirstOutputLatency), 22, accuracy: 0.000001,
            "The latest first output may belong to a turn that started earlier")
        older.consumeLive(["method": "item/started", "threadId": firstID, "turnId": "turn", "at": now.timeIntervalSince1970,
            "itemType": "commandExecution", "itemId": "tool"])
        XCTAssertEqual(try XCTUnwrap(older.firstTokenReportedAt).timeIntervalSince(now.addingTimeInterval(-18)), 0,
            accuracy: 0.000001, "Tool events retain the original measurement timestamp within epoch conversion precision")
        latest.consumeLive(["method": "turn/completed", "threadId": secondID, "turnId": "turn", "at": now.timeIntervalSince1970])
        model.activities = [older, latest, activity(firstID, turn: "new", start: now, first: nil)]
        XCTAssertEqual(try XCTUnwrap(model.latestFirstOutputLatency), 22, accuracy: 0.000001)
        model.activities = []
        XCTAssertEqual(try XCTUnwrap(model.latestFirstOutputLatency), 22, accuracy: 0.000001)
        let newer = activity(secondID, turn: "next", start: now.addingTimeInterval(-5), first: now.addingTimeInterval(-3.75), remote: true)
        model.receiveRemoteUpdate([], statuses: [:], unavailable: [], requests: [], names: [], performance: [try XCTUnwrap(SessionPerformanceUpdate(newer))])
        XCTAssertEqual(try XCTUnwrap(model.latestFirstOutputLatency), 1.25, accuracy: 0.000001,
            "Late numeric updates can replace the displayed measurement without recreating a card")
        model.activities = [older, latest]
        XCTAssertEqual(try XCTUnwrap(model.latestFirstOutputLatency), 1.25, accuracy: 0.000001, "Old replay cannot replace the latest TTFT")
        await model.shutdown()
    }
    func testWarningsAreConditionalAndSSHWarningRespectsDisabledMonitoring() throws {
        let defaults = UserDefaults.standard, old = defaults.object(forKey: "monitorSSH")
        let oldLayout = defaults.object(forKey: CompactIslandLayout.defaultsKey)
        defer {
            if let old { defaults.set(old, forKey: "monitorSSH") } else { defaults.removeObject(forKey: "monitorSSH") }
            if let oldLayout { defaults.set(oldLayout, forKey: CompactIslandLayout.defaultsKey) }
            else { defaults.removeObject(forKey: CompactIslandLayout.defaultsKey) }
        }
        defaults.set(true, forKey: "monitorSSH")
        let model = IslandModel(), now = Date(); model.now = now
        model.quota = try snapshot(used: 50, at: now, minutes: 300)
        var status = RuntimeStreamStatus(); status.connected = true
        model.streamStatuses = ["local": RuntimeStreamStatus(), "remote-ssh-discovered:fixture": status]
        XCTAssertTrue(CompactIslandComponent.activeWarnings(model).isEmpty)
        XCTAssertFalse(CompactIslandComponent.isVisible(.warnings, model: model), "The slot shows only while a warning holds")
        model.quota = try snapshot(used: 90, at: now, minutes: 300)
        XCTAssertTrue(CompactIslandComponent.activeWarnings(model).contains(.fiveHour))
        model.quota = try snapshot(used: 90, at: now, minutes: 100)
        XCTAssertFalse(CompactIslandComponent.activeWarnings(model).contains(.fiveHour), "Only the 5h window drives the warning")
        model.quota = try snapshot(used: 90, at: now.addingTimeInterval(-301), minutes: 300)
        XCTAssertTrue(CompactIslandComponent.activeWarnings(model).contains(.quotaDelay))
        XCTAssertFalse(CompactIslandComponent.activeWarnings(model).contains(.fiveHour), "Stale quota cannot produce a live low-quota warning")
        model.quota = nil; model.errorMessage = "Synthetic read failure"
        XCTAssertTrue(CompactIslandComponent.activeWarnings(model).contains(.quotaDelay))
        status.connected = false; model.streamStatuses["remote-ssh-discovered:fixture"] = status
        XCTAssertTrue(CompactIslandComponent.activeWarnings(model).contains(.ssh))
        model.streamStatuses = [:]; model.unavailableSSH = ["Synthetic unavailable"]
        XCTAssertTrue(CompactIslandComponent.activeWarnings(model).contains(.ssh))
        var layout = CompactIslandLayout.standard
        layout.warnings = [.quotaDelay]; layout.save(to: defaults); model.applySettings(sourceChanged: false)
        XCTAssertEqual(CompactIslandComponent.activeWarnings(model), [.quotaDelay],
            "A warning turned off in Reminders stays hidden while its condition holds")
        layout.warnings = []; layout.save(to: defaults); model.applySettings(sourceChanged: false)
        XCTAssertFalse(CompactIslandComponent.isVisible(.warnings, model: model))
        CompactIslandLayout.standard.save(to: defaults); model.applySettings(sourceChanged: false)
        defaults.set(false, forKey: "monitorSSH")
        XCTAssertFalse(CompactIslandComponent.activeWarnings(model).contains(.ssh))
    }
    func testQuotaLabelFollowsPercentageChoiceAndTimeRemainingIsClamped() throws {
        let defaults = UserDefaults.standard, old = defaults.object(forKey: "compactMetric")
        defer { if let old { defaults.set(old, forKey: "compactMetric") } else { defaults.removeObject(forKey: "compactMetric") } }
        let model = IslandModel(), now = Date(); model.now = now
        model.quota = try snapshot(used: 57, at: now)
        defaults.set("remaining", forKey: "compactMetric")
        XCTAssertEqual(model.compactQuotaText(.codex), "43%")
        XCTAssertEqual(model.compactMetricLabel, L10n.text("layout.quota_label"))
        XCTAssertEqual(model.compactTimeRemainingText(.codex), "50%")
        defaults.set("pace", forKey: "compactMetric")
        XCTAssertEqual(model.compactQuotaText(.codex), "86%")
        XCTAssertEqual(model.compactMetricLabel, L10n.text("quota.pace"))
        model.now = now.addingTimeInterval(3600)
        XCTAssertEqual(model.compactTimeRemainingText(.codex), "0%")
        model.quota = nil
        XCTAssertEqual(model.compactTimeRemainingText(.codex), "—")
        XCTAssertEqual(model.compactQuotaText(.codex), "—")
    }
    private func snapshot(used: Double, at date: Date, minutes: Int = 100) throws -> QuotaSnapshot {
        let bytes = try JSONSerialization.data(withJSONObject: ["rateLimits": ["primary": ["usedPercent": used,
            "windowDurationMins": minutes, "resetsAt": date.addingTimeInterval(3000).timeIntervalSince1970]]])
        return try QuotaSnapshot.decode(bytes, capturedAt: date)
    }
}
