import XCTest
@testable import PacerCore

final class MetricPresentationMacTests: XCTestCase {
    private let thread = "019a0000-0000-7000-8000-000000000001"
    private let start = Date(timeIntervalSince1970: 1_800_000_000)
    private func event(_ a: inout SessionActivity, _ method: String, _ seconds: Double, turn: String = "turn", _ fields: [String: Any] = [:]) {
        var row: [String: Any] = ["method": method, "threadId": thread, "turnId": turn, "at": start.addingTimeInterval(seconds).timeIntervalSince1970]
        row.merge(fields) { _, new in new }; a.consumeLive(row)
    }
    private func log(_ a: inout SessionActivity, _ seconds: Double, _ payload: [String: Any]) throws {
        a.consume(try JSONSerialization.data(withJSONObject: ["type": "event_msg", "timestamp": ISO8601DateFormatter().string(from: start.addingTimeInterval(seconds)), "payload": payload]))
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
                  {'type':'turn_context','timestamp':datetime.datetime.fromtimestamp(began+1,datetime.timezone.utc).isoformat(),'payload':{'turn_id':'turn','model':'gpt-fixture','effort':None,'instructions':'PRIVATE'}},
                  {'type':'event_msg','timestamp':datetime.datetime.fromtimestamp(began+4,datetime.timezone.utc).isoformat(),'payload':{'type':'item_completed','thread_id':tid,'turn_id':'turn','started_at_ms':(began+3.123)*1000,'completed_at_ms':(began+4)*1000,'item':{'type':'AgentMessage','content':['PRIVATE']}}},
                  {'type':'ignored','payload':{'padding':'x'*600000}}]
            # A header keeps the first turn-start line away from the initial fragment boundary.
            f.write((json.dumps({'type':'session_meta','payload':{'id':tid}})+'\n').encode())
            for row in rows:f.write((json.dumps(row)+'\n').encode())
            size=f.tell();seed=anchor(f,size,tid)
            assert seed['payload']['type']=='task_started' and abs(seed['payload']['first_output_latency_ms']-3123)<.001
            assert seed['payload']['_model_context']=={'model':'gpt-fixture','effort':None}
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
}
