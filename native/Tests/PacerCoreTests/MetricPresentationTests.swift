import XCTest
@testable import PacerCore

final class MetricPresentationTests: XCTestCase {
    private let thread = "019a0000-0000-7000-8000-000000000001"
    private let start = Date(timeIntervalSince1970: 1_800_000_000)
    private func event(_ a: inout SessionActivity, _ method: String, _ seconds: Double, turn: String = "turn", _ fields: [String: Any] = [:]) {
        var row: [String: Any] = ["method": method, "threadId": thread, "turnId": turn, "at": start.addingTimeInterval(seconds).timeIntervalSince1970]
        row.merge(fields) { _, new in new }; a.consumeLive(row)
    }
    private func log(_ a: inout SessionActivity, _ seconds: Double, _ payload: [String: Any]) throws {
        a.consume(try JSONSerialization.data(withJSONObject: ["type": "event_msg", "timestamp": ISO8601DateFormatter().string(from: start.addingTimeInterval(seconds)), "payload": payload]))
    }
    func testFreshnessDependsOnlyOnMeasurementAgeAcrossToolsAndNewTurns() {
        var a = SessionActivity(id: thread, phaseAwareRate: true)
        event(&a, "turn/started", 0); event(&a, "item/agentMessage/delta", 10, ["hasText": true])
        event(&a, "thread/tokenUsage/updated", 10, ["outputTokens": 600, "lastOutputTokens": 600])
        event(&a, "item/started", 11, ["itemType": "commandExecution", "itemId": "tool"])
        XCTAssertTrue(a.displayedOutputEstimate(at: start.addingTimeInterval(24.999))?.isFresh == true)
        XCTAssertFalse(a.displayedOutputEstimate(at: start.addingTimeInterval(25))?.isFresh == true)
        event(&a, "turn/completed", 12, ["status": "completed"])
        event(&a, "turn/started", 13, turn: "next")
        XCTAssertEqual(a.displayedOutputEstimate(at: start.addingTimeInterval(14))?.value, 60)
        XCTAssertTrue(a.displayedOutputEstimate(at: start.addingTimeInterval(14))?.isFresh == true)
        XCTAssertEqual(a.rateExpiresAt, start.addingTimeInterval(25))
    }
    func testFirstOutputSurvivesPartialReadsDuplicatesAndSourceReplacement() {
        var a = SessionActivity(id: thread, sourceHostID: "remote-ssh-discovered:fixture", phaseAwareRate: true)
        event(&a, "turn/started", 0)
        event(&a, "turn/attached", 1)
        event(&a, "item/agentMessage/delta", 2, ["hasText": true])
        XCTAssertEqual(a.firstTokenLatency, 2, "A reconnect before first text retains the observed start")
        a.markPartialRate()
        event(&a, "turn/started", 3)
        event(&a, "item/started", 4, ["itemType": "commandExecution", "itemId": "tool"])
        XCTAssertEqual(a.firstTokenLatency, 2)
        var replacement = SessionActivity(id: thread, sourceHostID: "remote-ssh-discovered:fixture", phaseAwareRate: true)
        event(&replacement, "turn/attached", 5)
        replacement.mergeDisplayMetadata(from: a)
        XCTAssertEqual(replacement.firstTokenLatency, 2)
        replacement.markDiscontinuity()
        XCTAssertEqual(replacement.firstTokenLatency, 2)
        event(&replacement, "turn/attached", 6)
        XCTAssertEqual(replacement.firstTokenLatency, 2)
        event(&replacement, "turn/started", 7, turn: "next")
        XCTAssertNil(replacement.firstTokenLatency)
        event(&replacement, "item/agentMessage/delta", 10, turn: "next", ["hasText": true])
        XCTAssertEqual(replacement.firstTokenLatency, 3)
    }
    func testBackendLatencyEnrichesOnlyItsTurnAndDoesNotReplayCompletion() throws {
        var a = SessionActivity(id: thread, phaseAwareRate: true)
        try log(&a, 0, ["type": "task_started", "turn_id": "turn"])
        a.markPartialRate()
        try log(&a, 10, ["type": "task_complete", "turn_id": "turn", "time_to_first_token_ms": 3537, "duration_ms": 10000])
        XCTAssertEqual(a.firstTokenLatency, 3.537)
        let ending = a.phaseChangedAt
        try log(&a, 11, ["type": "task_complete", "turn_id": "turn", "time_to_first_token_ms": 9999, "duration_ms": 10000])
        XCTAssertEqual(a.firstTokenLatency, 3.537)
        // Replayed lifecycle records are a separate guard; numeric timing cannot move the ending.
        XCTAssertEqual(a.phaseChangedAt, ending)
        event(&a, "turn/started", 12, turn: "next")
        try log(&a, 13, ["type": "task_complete", "turn_id": "turn", "time_to_first_token_ms": 1000])
        XCTAssertNil(a.firstTokenLatency)
        XCTAssertEqual(a.phase, .running)
    }
    func testCompletedModelItemWithoutDeltasProvidesObservedSSHFirstOutput() {
        var a = SessionActivity(id: thread, sourceHostID: "remote-ssh-discovered:fixture", phaseAwareRate: true)
        event(&a, "turn/started", 0)
        event(&a, "item/completed", 4, ["itemType": "reasoning", "itemId": "r", "hasText": true])
        XCTAssertEqual(a.firstTokenLatency, 4)
        event(&a, "item/agentMessage/delta", 5, ["hasText": true])
        XCTAssertEqual(a.firstTokenLatency, 4)
        var attached = SessionActivity(id: thread, phaseAwareRate: true)
        event(&attached, "turn/attached", 0)
        event(&attached, "item/completed", 4, ["itemType": "agentMessage", "hasText": true])
        XCTAssertNil(attached.firstTokenLatency, "Unknown earlier output cannot be invented on attachment")
    }
    func testSSHProjectionKeepsTimingAndTextPresenceWithoutPrivateContent() throws {
        let script = RealtimeProbe.library + "\n" + #"""
        tid='019a0000-0000-7000-8000-000000000001'
        timing=sanitize({'type':'event_msg','payload':{'type':'task_complete','turn_id':'turn','time_to_first_token_ms':3537,'duration_ms':10000,'last_agent_message':'PRIVATE'}})
        assert timing['payload']=={'type':'task_complete','turn_id':'turn','time_to_first_token_ms':3537,'duration_ms':10000}
        first=sanitize({'type':'event_msg','payload':{'type':'item_completed','thread_id':tid,'turn_id':'turn','started_at_ms':3131,'completed_at_ms':3137,'item':{'type':'AgentMessage','content':[{'text':'PRIVATE'}]}}})
        assert first['payload']=={'type':'item_completed','thread_id':tid,'turn_id':'turn','first_output_at_ms':3131} and 'PRIVATE' not in repr(first)
        encrypted=sanitize({'type':'event_msg','payload':{'type':'item_completed','thread_id':tid,'turn_id':'turn','completed_at_ms':3137,'item':{'type':'Reasoning','summary_text':[],'raw_content':'PRIVATE'}}})
        assert encrypted is None
        import tempfile
        class LegacyDateTimeMeta(type):
            def __getattribute__(cls,name):
                if name=='fromisoformat':raise AttributeError('Python 3.6 has no fromisoformat')
                return super().__getattribute__(name)
        class LegacyDateTime(datetime.datetime,metaclass=LegacyDateTimeMeta):pass
        datetime.datetime=LegacyDateTime
        assert not hasattr(datetime.datetime,'fromisoformat')
        expected=1800000000123.456
        for value in ('2027-01-15T08:00:00.123456Z','2027-01-15T16:00:00.123456+08:00','2027-01-15T04:30:00.123456-0330','2027-01-15T08:00:00.123456789+0000'):
            assert abs(timestamp_ms(value)-expected)<.001
        assert timestamp_ms('2027-01-15T08:00:00Z')==1800000000000
        assert timestamp_ms('2027-01-15 08:00:00')==datetime.datetime(2027,1,15,8).timestamp()*1000
        for value in (None,True,123,'bad','2027-02-30T08:00:00Z','2027-01-15T25:00:00Z','2027-01-15T08:00:00+00:60','2027-01-15T08:00:00+24:00','2027-01-15T08:00:00Z trailing'):
            assert timestamp_ms(value) is None
        began=1800000000
        with tempfile.TemporaryFile() as f:
            rows=[{'type':'event_msg','timestamp':datetime.datetime.fromtimestamp(began,datetime.timezone.utc).isoformat(),'payload':{'type':'task_started','turn_id':'turn'}},
                  {'type':'turn_context','timestamp':datetime.datetime.fromtimestamp(began+1,datetime.timezone.utc).isoformat(),'payload':{'turn_id':'turn'}},
                  {'type':'event_msg','timestamp':datetime.datetime.fromtimestamp(began+4,datetime.timezone.utc).isoformat(),'payload':{'type':'item_completed','thread_id':tid,'turn_id':'turn','started_at_ms':(began+3.123)*1000,'completed_at_ms':(began+4)*1000,'item':{'type':'AgentMessage','content':['PRIVATE']}}},
                  {'type':'ignored','payload':{'padding':'x'*600000}}]
            # A header keeps the first turn-start line away from the initial fragment boundary.
            f.write((json.dumps({'type':'session_meta','payload':{'id':tid}})+'\n').encode())
            for row in rows:f.write((json.dumps(row)+'\n').encode())
            size=f.tell();seed=anchor(f,size,tid)
            assert seed['payload']['type']=='task_started' and abs(seed['payload']['first_output_latency_ms']-3123)<.001
            assert 'PRIVATE' not in repr(seed)
        invalid=sanitize({'type':'event_msg','payload':{'type':'task_complete','time_to_first_token_ms':True,'duration_ms':-1}})
        assert 'time_to_first_token_ms' not in invalid['payload'] and 'duration_ms' not in invalid['payload']
        for kind,item in [('agentMessage',{'text':'PRIVATE'}),('reasoning',{'summary':['PRIVATE']}),('plan',{'text':'PRIVATE'})]:
            result=event('item/completed',{'threadId':tid,'turnId':'turn','item':{'id':'item','type':kind,**item}})
            assert result['hasText'] is True and 'PRIVATE' not in repr(result)
        empty=event('item/completed',{'threadId':tid,'turnId':'turn','item':{'id':'item','type':'reasoning','summary':[],'encryptedContent':'PRIVATE'}})
        assert empty['hasText'] is False and 'PRIVATE' not in repr(empty)
        print('numeric timing and presence only')
        """#
        let child = Process(), out = Pipe(), err = Pipe()
        child.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        child.arguments = ["-c", script, Data("/private/tmp/pacer-timing-test".utf8).base64EncodedString()]
        child.standardOutput = out; child.standardError = err
        try child.run(); let bytes = out.fileHandleForReading.readDataToEndOfFile(); child.waitUntilExit()
        XCTAssertEqual(child.terminationStatus, 0, String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self))
        XCTAssertTrue(String(decoding: bytes, as: UTF8.self).contains("numeric timing and presence only"))
    }
    func testLateSSHAttachmentRecoversCompleteLogWindowButNeverGuessesAcrossGap() throws {
        var logged = SessionActivity(id: thread, sourceHostID: "remote-ssh-discovered:fixture", phaseAwareRate: true)
        try log(&logged, 0, ["type": "task_started", "turn_id": "turn"])
        let marker: [String: Any] = ["type": "item_completed", "thread_id": thread, "turn_id": "turn",
            "first_output_at_ms": start.addingTimeInterval(3.123).timeIntervalSince1970 * 1000]
        try log(&logged, 4, marker)
        XCTAssertEqual(try XCTUnwrap(logged.firstTokenLatency), 3.123, accuracy: 0.000001)
        var live = SessionActivity(id: thread, sourceHostID: "remote-ssh-discovered:fixture", phaseAwareRate: true)
        event(&live, "turn/attached", 1)
        event(&live, "item/agentMessage/delta", 4, ["hasText": true])
        XCTAssertNil(live.firstTokenLatency)
        live.mergePerformance(from: logged)
        event(&live, "item/started", 5, ["itemType": "commandExecution", "itemId": "tool"])
        XCTAssertEqual(try XCTUnwrap(live.firstTokenLatency), 3.123, accuracy: 0.000001)
        var partial = SessionActivity(id: thread, phaseAwareRate: true)
        try log(&partial, 0, ["type": "task_started", "turn_id": "turn"])
        partial.markPartialRate()
        try log(&partial, 4, marker)
        XCTAssertNil(partial.firstTokenLatency)
        try log(&partial, 10, ["type": "task_complete", "turn_id": "turn", "time_to_first_token_ms": 3137, "duration_ms": 10000])
        XCTAssertEqual(partial.firstTokenLatency, 3.137)
    }
    func testBoundedLocalAnchorRecoversFirstOutputOutsideTailAndContextDoesNotReplaceStart() async throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("pacer-latency-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: home) }
        let formatter = DateFormatter(); formatter.dateFormat = "yyyy/MM/dd"
        let directory = home.appendingPathComponent("sessions/" + formatter.string(from: start))
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var bytes = Data()
        func row(_ type: String, _ seconds: Double, _ payload: [String: Any]) throws {
            bytes.append(try JSONSerialization.data(withJSONObject: ["type": type,
                "timestamp": ISO8601DateFormatter().string(from: start.addingTimeInterval(seconds)), "payload": payload])); bytes.append(10)
        }
        try row("session_meta", 0, ["id": thread])
        try row("event_msg", 0, ["type": "task_started", "turn_id": "turn"])
        try row("turn_context", 1, ["turn_id": "turn"])
        try row("event_msg", 4, ["type": "item_completed", "thread_id": thread, "turn_id": "turn",
            "started_at_ms": start.addingTimeInterval(3.123).timeIntervalSince1970 * 1000,
            "completed_at_ms": start.addingTimeInterval(4).timeIntervalSince1970 * 1000,
            "item": ["type": "AgentMessage", "content": ["Fixture text"]]])
        try row("ignored", 5, ["padding": String(repeating: "x", count: 600_000)])
        try bytes.write(to: directory.appendingPathComponent("rollout-" + thread + ".jsonl"))
        let result = await LocalActivityReader().read(home: home, now: start.addingTimeInterval(30), phaseAwareRate: true)
        let a = try XCTUnwrap(result.activities.first)
        XCTAssertEqual(a.turnStartedAt, start)
        XCTAssertEqual(try XCTUnwrap(a.firstTokenLatency), 3.123, accuracy: 0.000001)
        XCTAssertNil(a.responsePerformance)
    }
}
