import XCTest
@testable import PacerCore

final class SubagentMetricsMacTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_800_000_000)
    private func id(_ n: Int) -> String { String(format: "019a0000-0000-7000-8000-%012d", n) }
    private func live(_ activity: inout SessionActivity, _ method: String, _ second: Double, _ fields: [String: Any] = [:], turn: String = "turn") {
        var e: [String: Any] = ["method": method, "threadId": activity.threadID!, "turnId": turn, "at": start.addingTimeInterval(second).timeIntervalSince1970]
        e.merge(fields) { _, new in new }; activity.consumeLive(e)
    }
    private func measured(_ n: Int, parent: Int? = nil, host: String? = nil, tokens: Int = 600) -> SessionActivity {
        var a = SessionActivity(id: (host ?? "local") + ":" + id(n), sourceHostID: host, phaseAwareRate: true)
        if let parent { live(&a, "metadata", 0, ["parentThreadId": id(parent)]) }
        live(&a, "turn/started", 0)
        live(&a, "item/agentMessage/delta", 10, ["hasText": true])
        live(&a, "thread/tokenUsage/updated", 10, ["outputTokens": tokens, "lastOutputTokens": tokens])
        return a
    }
    func testHelperPreservesParentAndDiscoversReceiverWithoutForwardingCollaborationText() throws {
        let script = RealtimeProbe.library + "\n" + #"""
        class WS:
            def __init__(self):self.sent=[]
            def send(self,value):self.sent.append(value)
        parent='019a0000-0000-7000-8000-000000000001';child='019a0000-0000-7000-8000-000000000002'
        header=sanitize({'type':'session_meta','payload':{'id':child,'source':{'subagent':{'thread_spawn':{'parent_thread_id':parent,'agent_path':'PRIVATE','agent_nickname':'PRIVATE'}}}}})
        assert header['payload']['parent_thread_id']==parent and 'PRIVATE' not in repr(header)
        boundary=sanitize({'type':'event_msg','payload':{'type':'thread_settings_applied','thread_id':child,'thread_settings':{'prompt':'PRIVATE'}}})
        assert boundary['payload']=={'type':'thread_settings_applied','thread_id':child} and 'PRIVATE' not in repr(boundary)
        ws=WS();s=Session(ws);s.pending={};s.ready=True;s.known[parent]={'type':'active'};s.attached.add(parent)
        packets=[];emit=lambda value:packets.append(value)
        s.receive({'method':'item/started','params':{'threadId':parent,'turnId':'turn','item':{'id':'spawn','type':'collabAgentToolCall','receiverThreadIds':[child],'prompt':'PRIVATE','agentsStates':{child:{'status':'running','message':'PRIVATE'}}}}})
        request=next(v for v in ws.sent if v.get('method')=='thread/read')
        assert request['params']=={'threadId':child,'includeTurns':False}
        s.receive({'id':request['id'],'result':{'thread':{'id':child,'status':{'type':'active'},'parentThreadId':parent,'source':{'subAgent':{'thread_spawn':{'parent_thread_id':parent,'agent_nickname':'PRIVATE'}}}}}})
        flush_events(s)
        assert any(e.get('parentThreadId')==parent for p in packets for e in p.get('events',[]))
        assert 'PRIVATE' not in repr(packets) and 'PRIVATE' not in repr(ws.sent)
        print('parent and receiver sanitized')
        """#
        let child = Process(), stdout = Pipe(), stderr = Pipe()
        child.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        child.arguments = ["-c", script, Data("/private/tmp/unused-subagent-fixture".utf8).base64EncodedString()]
        child.standardOutput = stdout; child.standardError = stderr
        try child.run(); let output = stdout.fileHandleForReading.readDataToEndOfFile(); child.waitUntilExit()
        XCTAssertEqual(child.terminationStatus, 0, String(decoding: stderr.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self))
        XCTAssertTrue(String(decoding: output, as: UTF8.self).contains("parent and receiver sanitized"))
    }
}
