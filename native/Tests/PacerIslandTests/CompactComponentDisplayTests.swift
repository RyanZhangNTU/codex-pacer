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
    func testExpandedHeaderQuietsOnlyQuotaValuesAndRowsShowElapsedRunningTurns() {
        let quieted = CompactIslandLayout.Component.allCases.filter(CompactIslandComponent.dimsWhenExpanded)
        XCTAssertEqual(Set(quieted), [.quota, .quotaGauge, .quotaLabel, .timeRemaining],
            "Status, rate and warnings stay at full strength while the rings repeat quota below")
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let running = activity("019a0000-0000-7000-8000-00000000e1a9", start: start, first: start.addingTimeInterval(2))
        XCTAssertEqual(TaskRowView.elapsedText(running, phase: .running, now: start.addingTimeInterval(95)),
            L10n.text("dashboard.countdown_minutes", 1))
        XCTAssertEqual(TaskRowView.elapsedText(running, phase: .running, now: start.addingTimeInterval(30)),
            L10n.text("dashboard.countdown_soon"))
        XCTAssertNil(TaskRowView.elapsedText(running, phase: .completed, now: start.addingTimeInterval(95)), "Only running turns count up")
        XCTAssertNil(TaskRowView.elapsedText(running, phase: .running, now: start.addingTimeInterval(-5)), "A future start is never shown")
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
        defer { if let old { defaults.set(old, forKey: "monitorSSH") } else { defaults.removeObject(forKey: "monitorSSH") } }
        defaults.set(true, forKey: "monitorSSH")
        let model = IslandModel(), now = Date(); model.now = now
        model.quota = try snapshot(used: 50, at: now, minutes: 300)
        var status = RuntimeStreamStatus(); status.connected = true
        model.streamStatuses = ["local": RuntimeStreamStatus(), "remote-ssh-discovered:fixture": status]
        for component in [CompactIslandLayout.Component.lowQuotaWarning, .quotaDelayWarning, .sshWarning] {
            XCTAssertFalse(CompactIslandComponent.isVisible(component, model: model))
        }
        model.quota = try snapshot(used: 90, at: now, minutes: 300)
        XCTAssertTrue(CompactIslandComponent.isVisible(.lowQuotaWarning, model: model))
        model.quota = try snapshot(used: 90, at: now, minutes: 100)
        XCTAssertFalse(CompactIslandComponent.isVisible(.lowQuotaWarning, model: model), "Only the 5h window drives the warning")
        model.quota = try snapshot(used: 90, at: now.addingTimeInterval(-301), minutes: 300)
        XCTAssertTrue(CompactIslandComponent.isVisible(.quotaDelayWarning, model: model))
        XCTAssertFalse(CompactIslandComponent.isVisible(.lowQuotaWarning, model: model), "Stale quota cannot produce a live low-quota warning")
        model.quota = nil; model.errorMessage = "Synthetic read failure"
        XCTAssertTrue(CompactIslandComponent.isVisible(.quotaDelayWarning, model: model))
        status.connected = false; model.streamStatuses["remote-ssh-discovered:fixture"] = status
        XCTAssertTrue(CompactIslandComponent.isVisible(.sshWarning, model: model))
        model.streamStatuses = [:]; model.unavailableSSH = ["Synthetic unavailable"]
        XCTAssertTrue(CompactIslandComponent.isVisible(.sshWarning, model: model))
        defaults.set(false, forKey: "monitorSSH")
        XCTAssertFalse(CompactIslandComponent.isVisible(.sshWarning, model: model))
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
