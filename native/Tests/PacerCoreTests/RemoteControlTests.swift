import XCTest
@testable import PacerCore

final class RemoteControlTests: XCTestCase {
    private let thread = "019a0000-0000-7000-8000-000000000001"
    private let host = "remote-control:env_fixture"
    private let client = "019a0000-0000-7000-8000-000000000010"
    private let owner = "019a0000-0000-7000-8000-000000000020"
    private let epoch = Date(timeIntervalSince1970: 1000)

    func testDiscoveryUnionsSavedRoutesWithoutReadingEnrollmentOrProjectContent() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let config: [String: Any] = [
            "thread-project-membership-host-ids": [thread: host, "other": "local", "unsafe": "remote-control:bad/path"],
            "remote-projects": [["hostId": host, "label": "PRIVATE", "remotePath": "PRIVATE"], ["hostId": "remote-control:env_project"]],
            "added-remote-control-env-ids": ["env_added", "bad/host"],
            "app-server-migrated-pinned-thread-ids-by-host": ["remote-control:env_pinned:/home/test/.codex": [thread]],
            "electron-remote-control-client-enrollments": ["PRIVATE": ["privateKey": "PRIVATE"]]]
        try JSONSerialization.data(withJSONObject: config).write(to: home.appendingPathComponent(".codex-global-state.json"))
        let targets = RemoteControlActivityTarget.configured(home: home)
        XCTAssertEqual(Set(targets.map(\.id)), [host, "remote-control:env_project", "remote-control:env_added", "remote-control:env_pinned"])
        XCTAssertFalse(String(describing: targets).contains("PRIVATE"))
        var routing = DesktopRouteHints()
        XCTAssertEqual(routing.changed(home: home, hosts: [host]), [.init(host: host, thread: thread)])
    }

    func testRelayPreservesHostIsolationRatesAttentionAndCompletionOrder() throws {
        var session = try NativeDesktopSession(hosts: ["local", host]) { _ in }
        try initialize(&session)
        _ = session.takeFrames()
        var remote = RuntimeEventState(sourceID: host, sourceName: "Remote Control")
        var local = RuntimeEventState(sourceID: nil, sourceName: nil)
        remote.consume(["kind": "status", "connected": true]); local.consume(["kind": "status", "connected": true])
        func consume(_ hostID: String, _ change: [String: Any], at seconds: Double) throws -> [[String: Any]] {
            try send(&session, method: "thread-stream-following-status-requested", version: 1, params: ["hostId": hostID, "conversationId": thread])
            try send(&session, method: "thread-stream-state-changed", version: 11,
                     params: ["hostId": hostID, "conversationId": thread, "change": change], at: seconds)
            try session.publishEvents()
            let frames = try session.takeFrames().map { try JSONSerialization.jsonObject(with: $0) as! [String: Any] }
            for frame in frames where frame["hostId"] as? String == host { remote.consume(frame) }
            for frame in frames where frame["hostId"] as? String == "local" { local.consume(frame) }
            XCTAssertFalse(String(describing: frames).contains("PRIVATE"))
            return frames
        }
        let snapshot: [String: Any] = ["type": "snapshot", "revision": 0, "conversationState": state()]
        _ = try consume("local", snapshot, at: 0)
        _ = try consume(host, snapshot, at: 0)
        XCTAssertEqual(remote.activities.first?.id, host + ":" + thread)
        XCTAssertEqual(local.activities.first?.id, "local:" + thread)
        XCTAssertNil(remote.activities.first?.tokensPerSecond(at: epoch))
        let count = patch(base: 0, changes: [["op": "replace", "path": ["latestTokenUsageInfo"],
            "value": ["total": ["outputTokens": 10040], "last": ["outputTokens": 40]]]])
        _ = try consume(host, count, at: 2)
        XCTAssertEqual(remote.activities.first?.tokensPerSecond(at: epoch.addingTimeInterval(2)), 20)
        XCTAssertNil(local.activities.first?.tokensPerSecond(at: epoch.addingTimeInterval(2)))
        _ = try consume(host, patch(base: 1, changes: [["op": "replace", "path": ["threadRuntimeStatus", "activeFlags"],
            "value": ["waitingOnUserInput"]]]), at: 3)
        XCTAssertEqual(remote.activities.first?.phase, .waitingForInput)
        _ = try consume(host, patch(base: 2, changes: [["op": "replace", "path": ["threadRuntimeStatus", "activeFlags"], "value": []]]), at: 4)
        let frames = try consume(host, patch(base: 3, changes: [
            ["op": "replace", "path": ["latestTokenUsageInfo"], "value": ["total": ["outputTokens": 10080], "last": ["outputTokens": 40]]],
            ["op": "replace", "path": ["turns", 0, "status"], "value": "completed"],
            ["op": "replace", "path": ["threadRuntimeStatus", "type"], "value": "idle"]]), at: 6)
        let events = frames.compactMap { $0["events"] as? [[String: Any]] }.flatMap { $0 }
        let usage = try XCTUnwrap(events.firstIndex { $0["method"] as? String == "thread/tokenUsage/updated" })
        let end = try XCTUnwrap(events.firstIndex { $0["method"] as? String == "turn/completed" })
        XCTAssertLessThan(usage, end)
        XCTAssertEqual(remote.activities.first?.phase, .completed)
        XCTAssertEqual(local.activities.first?.phase, .running)
    }

    func testStaleRemoteSnapshotCannotRunAndReattachmentCannotMeasureHistoricalTokens() throws {
        var projection = DesktopWireProjection(threadID: thread, requiresResumedRuntime: true)
        var raw = state(); raw["resumeState"] = "needs_resume"
        raw["title"] = "Remote fixture"; raw["latestModel"] = "gpt-test"
        let parent = "019a0000-0000-7000-8000-000000000040", child = "019a0000-0000-7000-8000-000000000041"
        raw["parentThreadId"] = parent
        var turns = raw["turns"] as! [[String: Any]]
        var items = turns[0]["items"] as! [[String: Any]]
        items.append(["id": "child", "type": "subAgentActivity", "kind": "started", "agentThreadId": child, "message": "PRIVATE"])
        turns[0]["items"] = items; raw["turns"] = turns
        let events = try projection.consume(view(["type": "snapshot", "revision": 0, "conversationState": raw]), owner: owner, at: epoch)
        XCTAssertTrue(events.isEmpty)
        XCTAssertFalse(projection.isActive)
        let recovered = try projection.consume(view(patch(base: 0, changes: [["op": "replace", "path": ["resumeState"], "value": "resumed"]])),
                                                owner: owner, at: epoch.addingTimeInterval(100))
        XCTAssertEqual(recovered.first { ($0["method"] as? String)?.hasPrefix("turn/") == true }?["method"] as? String, "turn/attached")
        XCTAssertTrue(recovered.first { $0["method"] as? String == "thread/tokenUsage/updated" }?["cachedUsage"] as? Bool == true)
        XCTAssertFalse(recovered.contains { $0["firstTextDelta"] as? Bool == true })
        let metadata = recovered.first { $0["method"] as? String == "metadata" }
        XCTAssertEqual(metadata?["name"] as? String, "Remote fixture")
        XCTAssertEqual(metadata?["model"] as? String, "gpt-test")
        XCTAssertEqual(metadata?["parentThreadId"] as? String, parent)
        var runtime = RuntimeEventState(sourceID: host, sourceName: "Remote Control")
        runtime.consume(["kind": "status", "connected": true]); runtime.consume(["kind": "runtimeBatch", "events": recovered])
        XCTAssertEqual(runtime.activities.first?.phase, .running)
        XCTAssertNil(runtime.activities.first?.tokensPerSecond(at: epoch.addingTimeInterval(100)))
        XCTAssertNil(runtime.activities.first?.firstTokenLatency)
        XCTAssertEqual(runtime.activities.first?.stage, .thinking)
        XCTAssertEqual(runtime.activities.first?.parentThreadID, parent)
        XCTAssertEqual(runtime.activities.first?.subagentStates[child]?.state, "running")
        raw["resumeState"] = "resumed"; raw["threadRuntimeStatus"] = ["type": "idle"]
        var idle = DesktopWireProjection(threadID: thread, requiresResumedRuntime: true)
        XCTAssertTrue(try idle.consume(view(["type": "snapshot", "revision": 0, "conversationState": raw]), owner: owner, at: epoch).isEmpty)
        XCTAssertFalse(idle.isActive)
    }

    func testIdleBeforeExplicitEndingPreservesFinalUsageAndCompletion() throws {
        var projection = DesktopWireProjection(threadID: thread, requiresResumedRuntime: true)
        var runtime = RuntimeEventState(sourceID: host, sourceName: "Remote Control")
        runtime.consume(["kind": "status", "connected": true])
        func consume(_ change: [String: Any], at seconds: Double) throws -> [[String: Any]] {
            let events = try projection.consume(view(change), owner: owner, at: epoch.addingTimeInterval(seconds))
            runtime.consume(["kind": "runtimeBatch", "events": events]); return events
        }
        _ = try consume(["type": "snapshot", "revision": 0, "conversationState": state()], at: 0)
        let idle = try consume(patch(base: 0, changes: [["op": "replace", "path": ["threadRuntimeStatus", "type"], "value": "idle"]]), at: 1)
        XCTAssertTrue(projection.runtimeAvailable)
        XCTAssertFalse(idle.contains { $0["method"] as? String == "turn/completed" })
        let ending = try consume(patch(base: 1, changes: [
            ["op": "replace", "path": ["latestTokenUsageInfo"], "value": ["total": ["outputTokens": 10080], "last": ["outputTokens": 80]]],
            ["op": "replace", "path": ["turns", 0, "status"], "value": "completed"]]), at: 3)
        let usageIndex = try XCTUnwrap(ending.firstIndex { $0["method"] as? String == "thread/tokenUsage/updated" })
        let endingIndex = try XCTUnwrap(ending.firstIndex { $0["method"] as? String == "turn/completed" })
        XCTAssertLessThan(usageIndex, endingIndex)
        XCTAssertEqual(runtime.activities.first?.phase, .completed)
        XCTAssertNotNil(runtime.activities.first?.displayedOutputEstimate(at: epoch.addingTimeInterval(3)))
    }

    func testCurrentHostIsNotCrowdedOutByHistoricalHostsAndRejectsNewlineSuffixes() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let selected = "remote-control:env_z_current"
        let projects = (0..<9).map { ["hostId": "remote-control:env_a_old_\($0)"] }
        let config: [String: Any] = ["selected-remote-host-id": selected, "remote-projects": projects,
            "thread-project-membership-host-ids": [thread: selected, "unsafe": "remote-control:env_0_bad\n"]]
        try JSONSerialization.data(withJSONObject: config).write(to: home.appendingPathComponent(".codex-global-state.json"))
        let ids = RemoteControlActivityTarget.configured(home: home).map(\.id)
        XCTAssertEqual(ids.first, selected)
        XCTAssertLessThanOrEqual(ids.count, 8)
        XCTAssertFalse(ids.contains { $0.contains("\n") })
    }

    func testDisconnectAndRevisionGapInvalidateRemoteActivityWithoutCompletingIt() throws {
        for ownerDisconnect in [false, true] {
            var session = try NativeDesktopSession(hosts: [host]) { _ in }
            try initialize(&session)
            try send(&session, method: "thread-stream-following-status-requested", version: 1, params: ["hostId": host, "conversationId": thread])
            try send(&session, method: "thread-stream-state-changed", version: 11, params: ["hostId": host, "conversationId": thread,
                "change": ["type": "snapshot", "revision": 0, "conversationState": state()]])
            try session.publishEvents(); _ = session.takeFrames()
            if ownerDisconnect {
                try send(&session, method: "client-status-changed", version: 0, params: ["clientId": owner, "status": "disconnected"])
            } else {
                try send(&session, method: "thread-stream-state-changed", version: 11, params: ["hostId": host, "conversationId": thread,
                    "change": patch(base: 10, changes: [])])
            }
            let frames = try session.takeFrames().map { try JSONSerialization.jsonObject(with: $0) as! [String: Any] }
            XCTAssertTrue(frames.contains { $0["kind"] as? String == "streamInvalidated" && $0["hostId"] as? String == host })
            XCTAssertFalse(frames.compactMap { $0["events"] as? [[String: Any]] }.flatMap { $0 }.contains { $0["method"] as? String == "turn/completed" })
        }
    }

    func testCachedRefreshCannotCreateOrRefreshTPSAndNextLiveCountersUseItsBaseline() throws {
        for measured in [false, true] {
            var projection = DesktopWireProjection(threadID: thread, requiresResumedRuntime: true)
            var runtime = RuntimeEventState(sourceID: host, sourceName: "Remote Control")
            runtime.consume(["kind": "status", "connected": true])
            func consume(_ change: [String: Any], at seconds: Double) throws {
                let events = try projection.consume(view(change), owner: owner, at: epoch.addingTimeInterval(seconds))
                runtime.consume(["kind": "runtimeBatch", "events": events])
            }
            var raw = state(); raw["latestTokenUsageInfo"] = ["total": ["outputTokens": 1000], "last": ["outputTokens": 600]]
            try consume(["type": "snapshot", "revision": 0, "conversationState": raw], at: 0)
            var revision = 0
            if measured {
                try consume(patch(base: 0, changes: [["op": "replace", "path": ["latestTokenUsageInfo"],
                    "value": ["total": ["outputTokens": 1040], "last": ["outputTokens": 40]]]]), at: 2)
                revision = 1
            }
            let before = runtime.activities.first?.displayedOutputEstimate(at: epoch.addingTimeInterval(2))
            raw["latestTokenUsageInfo"] = ["total": ["outputTokens": 51000], "last": ["outputTokens": 50000]]
            try consume(["type": "snapshot", "revision": revision + 1, "conversationState": raw], at: 3)
            XCTAssertEqual(runtime.activities.first?.displayedOutputEstimate(at: epoch.addingTimeInterval(3)), before)
            try consume(patch(base: revision + 1, changes: [["op": "replace", "path": ["latestTokenUsageInfo"],
                "value": ["total": ["outputTokens": 51040], "last": ["outputTokens": 40]]]]), at: 5)
            XCTAssertEqual(runtime.activities.first?.tokensPerSecond(at: epoch.addingTimeInterval(5)), 20)
        }
    }

    func testCachedRefreshDuringToolWaitPreservesBlockedTime() {
        var rate = GenerationRate()
        rate.observe(total: 1000, at: epoch)
        rate.setWaiting(true, at: epoch.addingTimeInterval(1))
        rate.observe(total: 51000, at: epoch.addingTimeInterval(5), cached: true)
        rate.setWaiting(false, at: epoch.addingTimeInterval(10))
        rate.observe(total: 51040, at: epoch.addingTimeInterval(12))
        XCTAssertEqual(rate.estimate(at: epoch.addingTimeInterval(12))?.value, 20)
    }

    func testSplitRequestCountersCannotPairOldLastUsageWithNewTotal() throws {
        for sequence in ["total-first", "last-first", "atomic"] {
            var projection = DesktopWireProjection(threadID: thread, requiresResumedRuntime: true)
            var runtime = RuntimeEventState(sourceID: host, sourceName: "Remote Control")
            runtime.consume(["kind": "status", "connected": true])
            var revision = 0
            func change(_ patches: [[String: Any]], at seconds: Double) throws {
                let events = try projection.consume(view(patch(base: revision, changes: patches)), owner: owner, at: epoch.addingTimeInterval(seconds))
                revision += 1; runtime.consume(["kind": "runtimeBatch", "events": events])
            }
            var raw = state(); raw["turns"] = []; raw["latestTokenUsageInfo"] = ["total": ["outputTokens": 600], "last": ["outputTokens": 600]]
            let initial = try projection.consume(view(["type": "snapshot", "revision": 0, "conversationState": raw]), owner: owner, at: epoch)
            runtime.consume(["kind": "runtimeBatch", "events": initial])
            let turn: [String: Any] = ["turnId": "turn", "status": "inProgress", "turnStartedAtMs": 1001000,
                "items": [["id": "tool", "type": "commandExecution", "status": "inProgress"],
                          ["id": "reply", "type": "agentMessage", "status": "inProgress"]]]
            try change([["op": "add", "path": ["turns", 0], "value": turn]], at: 1)
            try change([["op": "replace", "path": ["turns", 0, "items", 0, "status"], "value": "completed"]], at: 2)
            try change([["op": "replace", "path": ["turns", 0, "items", 1, "text"], "value": "PRIVATE"]], at: 12)
            let total: [String: Any] = ["op": "replace", "path": ["latestTokenUsageInfo", "total", "outputTokens"], "value": 1600]
            let last: [String: Any] = ["op": "replace", "path": ["latestTokenUsageInfo", "last", "outputTokens"], "value": 1000]
            if sequence == "atomic" {
                try change([total, last], at: 12.1)
                XCTAssertEqual(runtime.activities.first?.responsePerformance?.outputTokens, 1000)
                XCTAssertEqual(runtime.activities.first?.responsePerformance?.tokensPerSecond, 100)
            } else {
                try change([sequence == "total-first" ? total : last], at: 12.1)
                try change([sequence == "total-first" ? last : total], at: 12.2)
                XCTAssertNil(runtime.activities.first?.responsePerformance)
                XCTAssertNil(runtime.activities.first?.displayedOutputEstimate(at: epoch.addingTimeInterval(12.2)))
            }
        }
    }

    func testCachedCounterGapCannotUpgradeAnOlderResponseWithAnUnrelatedRecord() {
        var meter = ResponsePerformanceMeter()
        meter.start(turnID: "turn", at: epoch, observed: true)
        meter.observeRuntime(total: 0, last: nil, reasoning: nil, at: epoch, cached: true)
        meter.modelOutput(at: epoch.addingTimeInterval(10), textDelta: true)
        meter.observeRuntime(total: 100, last: 100, reasoning: nil, at: epoch.addingTimeInterval(10))
        XCTAssertEqual(meter.latest?.tokensPerSecond, 10)
        meter.observeRuntime(total: 5100, last: 5000, reasoning: nil, at: epoch.addingTimeInterval(11), cached: true)
        meter.observeRequest(id: "unknown-window", turn: "turn", output: 5000, reasoning: nil, at: epoch.addingTimeInterval(12))
        XCTAssertNil(meter.latest)
    }

    func testCachedGapDiscardsUpstreamPendingAndAmbiguousWindows() {
        for ambiguous in [false, true] {
            for exact in [false, true] {
                var meter = ResponsePerformanceMeter()
                meter.start(turnID: "turn", at: epoch, observed: true)
                meter.observeRuntime(total: 0, last: nil, reasoning: nil, at: epoch, cached: true)
                meter.modelOutput(at: epoch.addingTimeInterval(1), textDelta: true)
                meter.setWaiting(true, at: epoch.addingTimeInterval(2))
                meter.inputBoundary(at: epoch.addingTimeInterval(3))
                if ambiguous {
                    meter.modelOutput(at: epoch.addingTimeInterval(4), textDelta: true)
                    meter.setWaiting(true, at: epoch.addingTimeInterval(5))
                }
                meter.observeRuntime(total: 50000, last: 50000, reasoning: nil, at: epoch.addingTimeInterval(6), cached: true)
                meter.modelOutput(at: epoch.addingTimeInterval(7), textDelta: true)
                if exact { meter.observeRequest(id: "unmatched", turn: "turn", output: 1000, reasoning: nil, at: epoch.addingTimeInterval(8)) }
                else { meter.observeRuntime(total: 51000, last: 1000, reasoning: nil, at: epoch.addingTimeInterval(8)) }
                XCTAssertNil(meter.latest)
                meter.inputBoundary(at: epoch.addingTimeInterval(9))
                meter.modelOutput(at: epoch.addingTimeInterval(19), textDelta: true)
                if exact { meter.observeRequest(id: "fresh", turn: "turn", output: 600, reasoning: nil, at: epoch.addingTimeInterval(19)) }
                else { meter.observeRuntime(total: 51600, last: 600, reasoning: nil, at: epoch.addingTimeInterval(19)) }
                XCTAssertEqual(meter.latest?.tokensPerSecond, 60)
            }
        }
    }

    func testLateTerminalUsageUsesUpstreamPendingWindowAndPreservesTTFTTimestamp() throws {
        var runtime = RuntimeEventState(sourceID: host, sourceName: "Remote Control"), inbox = CompletionInbox()
        runtime.consume(["kind": "status", "connected": true])
        func event(_ method: String, _ seconds: Double, _ fields: [String: Any] = [:]) -> [String: Any] {
            ["method": method, "threadId": thread, "turnId": "turn", "at": epoch.addingTimeInterval(seconds).timeIntervalSince1970]
                .merging(fields) { _, new in new }
        }
        runtime.consume(["kind": "runtimeBatch", "events": [event("turn/started", 0),
            event("thread/tokenUsage/updated", 0, ["outputTokens": 0, "cachedUsage": true]),
            event("item/agentMessage/delta", 10, ["hasText": true]),
            event("item/started", 11, ["itemId": "tool", "itemType": "commandExecution"]),
            event("turn/completed", 12, ["status": "completed"])]])
        inbox.observe(runtime.activities, at: epoch.addingTimeInterval(12), retention: 30)
        let before = try XCTUnwrap(inbox.activities.first)
        runtime.consume(["kind": "runtime", "event": event("stream/released", 12)]); runtime.releasePublishedState()
        runtime.consume(["kind": "runtime", "event": event("thread/tokenUsage/updated", 13,
            ["terminalUsage": true, "outputTokens": 110, "lastOutputTokens": 110])])
        inbox.updatePerformance(runtime.performanceUpdates)
        let after = try XCTUnwrap(inbox.activities.first)
        XCTAssertEqual(after.responsePerformance?.tokensPerSecond, 10)
        XCTAssertEqual(after.firstTokenLatency, 10)
        XCTAssertEqual(after.firstTokenReportedAt, before.firstTokenReportedAt)
        XCTAssertEqual(after.phaseChangedAt, before.phaseChangedAt)
        XCTAssertTrue(runtime.activities.isEmpty)
        runtime.releasePublishedState()
        runtime.consume(["kind": "runtime", "event": event("thread/tokenUsage/updated", 14,
            ["terminalUsage": true, "outputTokens": 110, "lastOutputTokens": 110])])
        XCTAssertTrue(runtime.performanceUpdates.isEmpty)
    }

    func testTerminalFirstUsageSecondEnrichesOnlyTheRetainedCard() throws {
        var session = try NativeDesktopSession(hosts: [host]) { _ in }
        try initialize(&session); _ = session.takeFrames()
        try send(&session, method: "thread-stream-following-status-requested", version: 1, params: ["hostId": host, "conversationId": thread])
        var runtime = RuntimeEventState(sourceID: host, sourceName: "Remote Control"), inbox = CompletionInbox()
        runtime.consume(["kind": "status", "connected": true])
        func consume(_ change: [String: Any], at seconds: Double) throws {
            try send(&session, method: "thread-stream-state-changed", version: 11,
                     params: ["hostId": host, "conversationId": thread, "change": change], at: seconds)
            try session.publishEvents()
            for bytes in session.takeFrames() {
                runtime.consume(try JSONSerialization.jsonObject(with: bytes) as! [String: Any])
            }
        }
        let turn: [String: Any] = ["turnId": "turn", "status": "inProgress", "turnStartedAtMs": 1001000,
            "items": [["id": "reply", "type": "agentMessage", "status": "inProgress"]]]
        var raw = state(); raw["turns"] = []; raw["latestTokenUsageInfo"] = ["total": ["outputTokens": 0], "last": ["outputTokens": 0]]
        try consume(["type": "snapshot", "revision": 0, "conversationState": raw], at: 0)
        try consume(patch(base: 0, changes: [["op": "add", "path": ["turns", 0], "value": turn]]), at: 1)
        try consume(patch(base: 1, changes: [["op": "replace", "path": ["turns", 0, "items", 0, "text"], "value": "PRIVATE"]]), at: 3)
        try consume(patch(base: 2, changes: [
            ["op": "replace", "path": ["turns", 0, "items", 0, "status"], "value": "completed"],
            ["op": "replace", "path": ["turns", 0, "status"], "value": "completed"],
            ["op": "replace", "path": ["threadRuntimeStatus", "type"], "value": "idle"]]), at: 11)
        XCTAssertEqual(inbox.observe(runtime.activities, at: epoch.addingTimeInterval(11), retention: 30).count, 1)
        let before = try XCTUnwrap(inbox.activities.first)
        runtime.releasePublishedState()
        try consume(patch(base: 3, changes: [["op": "replace", "path": ["latestTokenUsageInfo"],
            "value": ["total": ["outputTokens": 100], "last": ["outputTokens": 100]]]]), at: 12)
        XCTAssertTrue(runtime.activities.isEmpty)
        inbox.updatePerformance(runtime.performanceUpdates)
        let after = try XCTUnwrap(inbox.activities.first)
        XCTAssertEqual(after.responsePerformance?.tokensPerSecond, 10)
        XCTAssertEqual(after.phaseChangedAt, before.phaseChangedAt)
        XCTAssertTrue(inbox.isUnread(after))
        inbox.dismiss(after); inbox.updatePerformance(runtime.performanceUpdates)
        XCTAssertTrue(inbox.activities.isEmpty)
        inbox.observe([before], at: epoch.addingTimeInterval(42), retention: 30)
        inbox.updatePerformance(runtime.performanceUpdates)
        XCTAssertTrue(inbox.activities.isEmpty)
    }

    func testReleaseAndLateUsageInOneBatchCannotRestoreAnOlderCounterOnReplay() {
        var runtime = RuntimeEventState(sourceID: host, sourceName: "Remote Control")
        runtime.consume(["kind": "status", "connected": true])
        func event(_ method: String, _ seconds: Double, _ fields: [String: Any] = [:]) -> [String: Any] {
            ["method": method, "threadId": thread, "turnId": "turn", "at": epoch.addingTimeInterval(seconds).timeIntervalSince1970]
                .merging(fields) { _, new in new }
        }
        runtime.consume(["kind": "runtimeBatch", "events": [
            event("turn/started", 0), event("thread/tokenUsage/updated", 0, ["outputTokens": 0, "cachedUsage": true]),
            event("item/agentMessage/delta", 10, ["hasText": true]), event("turn/completed", 11, ["status": "completed"])]])
        runtime.consume(["kind": "runtimeBatch", "events": [
            event("stream/released", 11),
            event("thread/tokenUsage/updated", 12, ["terminalUsage": true, "outputTokens": 100, "lastOutputTokens": 100])]])
        XCTAssertEqual(runtime.performanceUpdates.first?.response?.tokensPerSecond, 10)
        runtime.releasePublishedState()
        runtime.consume(["kind": "runtime", "event": event("thread/tokenUsage/updated", 13,
            ["terminalUsage": true, "outputTokens": 100, "lastOutputTokens": 100])])
        XCTAssertTrue(runtime.activities.isEmpty)
        XCTAssertTrue(runtime.performanceUpdates.isEmpty)
        runtime.consume(["kind": "runtime", "event": event("turn/started", 14, ["turnId": "new-turn"])])
        runtime.consume(["kind": "runtime", "event": event("thread/tokenUsage/updated", 15,
            ["terminalUsage": true, "outputTokens": 500, "lastOutputTokens": 400])])
        XCTAssertTrue(runtime.performanceUpdates.isEmpty)
        XCTAssertEqual(runtime.activities.first?.turnID, "new-turn")
    }

    private func initialize(_ session: inout NativeDesktopSession) throws {
        try session.receive(JSONSerialization.data(withJSONObject: ["type": "response", "method": "initialize", "resultType": "success", "result": ["clientId": client]]), at: epoch)
    }
    private func send(_ session: inout NativeDesktopSession, method: String, version: Int, params: [String: Any], at seconds: Double = 0) throws {
        try session.receive(JSONSerialization.data(withJSONObject: ["type": "broadcast", "method": method, "version": version,
            "sourceClientId": owner, "params": params]), at: epoch.addingTimeInterval(seconds))
    }
    private func view(_ value: [String: Any]) throws -> JSONFieldView { try JSONFieldView.document(JSONSerialization.data(withJSONObject: value)) }
    private func patch(base: Int, changes: [[String: Any]]) -> [String: Any] {
        ["type": "patches", "baseRevision": base, "revision": base + 1, "patches": changes]
    }
    private func state() -> [String: Any] {
        ["resumeState": "resumed", "threadRuntimeStatus": ["type": "active", "activeFlags": []], "requests": [],
         "latestTokenUsageInfo": ["total": ["outputTokens": 10000], "last": ["outputTokens": 9000]],
         "turns": [["turnId": "turn", "status": "inProgress", "turnStartedAtMs": 1000000,
                    "items": [["id": "reasoning", "type": "reasoning", "text": "PRIVATE"]]]]]
    }
}
