import XCTest
@testable import PacerCore

final class DesktopEventTests: XCTestCase {
    private let thread = "019a0000-0000-7000-8000-000000000001"
    private func python(_ script: String, once: Bool = false) throws -> String {
        let home = URL(fileURLWithPath: "/private/tmp/pacer-ipc-" + String(UUID().uuidString.prefix(8)))
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let child = Process(), stdout = Pipe(), stderr = Pipe()
        child.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        child.arguments = ["-u", "-c", script, Data(home.path.utf8).base64EncodedString(), once ? "once" : "test"]
        child.standardOutput = stdout; child.standardError = stderr
        try child.run()
        let bytes = stdout.fileHandleForReading.readDataToEndOfFile()
        child.waitUntilExit()
        let error = String(decoding: stderr.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        XCTAssertEqual(child.terminationStatus, 0, error)
        return String(decoding: bytes, as: UTF8.self)
    }
    func testTextOnlyPatchesAdvanceRevisionAndActivityWithoutCopyingHistory() throws {
        let simulation = #"""
        p=Projection('019a0000-0000-7000-8000-000000000001')
        state={'threadRuntimeStatus':{'type':'active'},'turns':[{'turnId':'turn','status':'inProgress','items':[{'id':'answer','type':'agentMessage'}]}]}
        p.consume({'type':'snapshot','revision':0,'conversationState':state},'owner')
        before=json.dumps(p.tree);original_copy=copy.deepcopy
        def forbidden_copy(value):raise AssertionError('text-only update copied the history')
        copy.deepcopy=forbidden_copy
        try:
            events=p.consume({'type':'patches','baseRevision':0,'revision':1,'patches':[{'op':'replace','path':['turns',0,'items',0,'content'],'value':'PRIVATE BODY'}]},'owner')
        finally:copy.deepcopy=original_copy
        assert p.revision==1 and json.dumps(p.tree)==before
        assert any(e['method']=='item/agentMessage/delta' and e['itemId']=='answer' for e in events)
        assert any(e['method']=='thread/status/changed' and e['status']=='active' for e in events)
        assert 'PRIVATE BODY' not in json.dumps(events)
        print('body patch preserved activity')
        """#
        XCTAssertTrue(try python(DesktopEventProbe.library + "\n" + simulation).contains("preserved activity"))
    }
    func testPatchBatchRollbackIncludesMalformedIgnoredPatchAndInvalidProjectedPath() throws {
        let simulation = #"""
        p=Projection('019a0000-0000-7000-8000-000000000001')
        state={'latestTokenUsageInfo':{'total':{'outputTokens':100}},'turns':[{'turnId':'turn','status':'inProgress','items':[{'id':'tool','type':'commandExecution','status':'inProgress'}]}]}
        p.consume({'type':'snapshot','revision':0,'conversationState':state},'owner')
        before=json.dumps(p.tree);turn=copy.deepcopy(p.turn);usage=p.usage
        invalid=[{'op':'invalid','path':['ignored'],'value':'PRIVATE'}, {'op':'replace','path':['ignored']*13}, {'op':'replace','path':['turns',0,'items',50,'status'],'value':'completed'}, None]
        for bad in invalid:
            try:
                p.consume({'type':'patches','baseRevision':0,'revision':1,'patches':[{'op':'replace','path':['turns',0,'status'],'value':'completed'},bad]},'owner')
                assert False,'invalid patch accepted'
            except ValueError:pass
            assert p.revision==0 and json.dumps(p.tree)==before and p.turn==turn and p.usage==usage
        events=p.consume({'type':'patches','baseRevision':0,'revision':1,'patches':[{'op':'replace','path':['latestTokenUsageInfo','total','outputTokens'],'value':125},{'op':'replace','path':['turns',0,'items',0,'status'],'value':'completed'}]},'owner')
        assert any(e['method']=='thread/tokenUsage/updated' and e['outputTokens']==125 for e in events)
        assert any(e['method']=='item/completed' and e['itemId']=='tool' for e in events)
        assert p.revision==1
        print('atomic rollback preserved')
        """#
        XCTAssertTrue(try python(DesktopEventProbe.library + "\n" + simulation).contains("rollback preserved"))
    }
    func testProjectionDiscardsBodyAndRejectsRevisionGapBeforeTerminalState() throws {
        let simulation = #"""
        tid='019a0000-0000-7000-8000-000000000001';p=Projection(tid)
        state={'title':'Name','cwd':'/test/project','latestTokenUsageInfo':{'total':{'outputTokens':100,'inputTokens':999}},'turnHistory':{'kind':'canonical','history':{'entitiesByKey':{'key':{'turnId':'turn','status':'inProgress','turnStartedAtMs':100,'params':{'input':'PRIVATE'},'items':[{'id':'model','type':'reasoning','content':'PRIVATE'}]}}}}}
        first=p.consume({'type':'snapshot','revision':3,'conversationState':state},'owner')
        before=json.dumps(p.tree);rejected=False
        try:p.consume({'type':'patches','baseRevision':1,'revision':2,'patches':[{'op':'replace','path':['turnHistory','history','entitiesByKey','key','status'],'value':'completed'}]},'owner')
        except ValueError:rejected=True
        assert rejected and before==json.dumps(p.tree)
        assert 'PRIVATE' not in json.dumps(p.tree) and 'inputTokens' not in json.dumps(p.tree)
        try:p.consume({'type':'patches','baseRevision':3,'revision':4,'patches':[]},'other-owner');assert False
        except ValueError:pass
        done=p.consume({'type':'patches','baseRevision':3,'revision':4,'patches':[{'op':'replace','path':['turnHistory','history','entitiesByKey','key','status'],'value':'completed'}]},'owner')
        assert any(e['method']=='turn/attached' for e in first)
        assert any(e['method']=='turn/completed' and e['turnId']=='turn' for e in done)
        print(json.dumps({'first':first,'done':done,'gapRejected':rejected}))
        """#
        let result = try python(DesktopEventProbe.library + "\n" + simulation)
        XCTAssertFalse(result.contains("PRIVATE"))
        XCTAssertTrue(result.contains("turn/attached"))
        XCTAssertTrue(result.contains("turn/completed"))
    }
    func testRealDesktopSocketStreamsToolsCountsAndCompletionWithoutTaskOperations() throws {
        let output = try python(Self.fixture + "\n" + DesktopEventProbe.script, once: true)
        XCTAssertFalse(output.contains("PRIVATE"))
        let frames = try output.split(separator: "\n").map { try JSONSerialization.jsonObject(with: Data($0.utf8)) as! [String: Any] }
        let requests = try XCTUnwrap(frames.first(where: { $0["testMessages"] != nil })?["testMessages"] as? [[String: Any]])
        XCTAssertTrue(requests.allSatisfy { ["initialize", "thread-stream-following-changed"].contains($0["method"] as? String ?? "") })
        XCTAssertFalse(requests.contains { ($0["params"] as? [String: Any])?["hostId"] as? String == "remote" })
        var state = RuntimeEventState(sourceID: nil, sourceName: nil)
        for frame in frames { state.consume(frame) }
        XCTAssertEqual(state.activities.count, 1)
        XCTAssertEqual(state.activities.first?.phase, .completed)
        XCTAssertEqual(state.activities.first?.turnID, "turn")
        XCTAssertFalse(state.status.watchingLogs)
        XCTAssertEqual(state.status.fallbackScans, 0)
    }
    func testGapInvalidationReturnsToLogFallbackWithoutInventingCompletion() {
        var state = RuntimeEventState(sourceID: nil, sourceName: nil)
        var fallback = SessionActivity(id: "local:" + thread)
        fallback.consumeLive(["method": "turn/started", "threadId": thread, "turnId": "turn", "at": 1000.0])
        state.replaceLocalFallback([fallback])
        state.consume(["kind": "status", "connected": true])
        state.consume(["kind": "runtime", "event": ["method": "turn/attached", "threadId": thread, "turnId": "turn", "at": 1001.0]])
        state.consume(["kind": "streamInvalidated", "threadId": thread])
        XCTAssertEqual(state.activities.first?.phase, .unknown)
        fallback.consumeLive(["method": "turn/completed", "threadId": thread, "turnId": "turn", "at": 1000.5, "status": "completed"])
        state.replaceLocalFallback([fallback])
        XCTAssertEqual(state.activities.first?.phase, .completed)
    }
    func testApprovalClearingResumesTaskAndKeepsToolWaiting() {
        var activity = SessionActivity(id: "local:" + thread, phaseAwareRate: true)
        activity.consumeLive(["method": "turn/started", "threadId": thread, "turnId": "turn", "at": 1000.0])
        activity.consumeLive(["method": "thread/status/changed", "threadId": thread, "at": 1001.0, "status": "active", "flags": ["waitingOnApproval"]])
        XCTAssertEqual(activity.phase, .waitingForInput)
        activity.consumeLive(["method": "item/started", "threadId": thread, "turnId": "turn", "at": 1002.0, "itemId": "tool", "itemType": "commandExecution"])
        activity.consumeLive(["method": "thread/status/changed", "threadId": thread, "at": 1003.0, "status": "active", "flags": []])
        XCTAssertEqual(activity.phase, .running)
        XCTAssertEqual(activity.stage, .tool)
        XCTAssertEqual(activity.outputEstimate(at: Date(timeIntervalSince1970: 1003))?.value, 0)
    }
    func testSubscribedLocalThreadDoesNotReadChangedLogUntilFallbackIsNeeded() async throws {
        let home = URL(fileURLWithPath: "/private/tmp/pacer-covered-" + String(UUID().uuidString.prefix(8)))
        defer { try? FileManager.default.removeItem(at: home) }
        let formatter = DateFormatter(); formatter.dateFormat = "yyyy/MM/dd"
        let directory = home.appendingPathComponent("sessions/" + formatter.string(from: Date()))
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("rollout-" + thread + ".jsonl")
        let timestamp = ISO8601DateFormatter().string(from: Date())
        let start = "{\"timestamp\":\"\(timestamp)\",\"type\":\"event_msg\",\"payload\":{\"type\":\"task_started\",\"turn_id\":\"turn\"}}\n"
        let end = "{\"timestamp\":\"\(timestamp)\",\"type\":\"event_msg\",\"payload\":{\"type\":\"task_complete\",\"turn_id\":\"turn\"}}\n"
        try Data(start.utf8).write(to: file)
        let reader = LocalActivityReader()
        let initial = await reader.read(home: home)
        XCTAssertEqual(initial.activities.first?.phase, .running)
        try Data((start + end).utf8).write(to: file)
        let covered = await reader.read(home: home, excludingThreads: [thread])
        XCTAssertEqual(covered.activities.first?.phase, .running)
        let fallback = await reader.read(home: home)
        XCTAssertEqual(fallback.activities.first?.phase, .completed)
    }

    private static let fixture = #"""
    import pathlib,base64,sys,socket,struct,json,threading,time,os,atexit
    fixture_home=pathlib.Path(base64.b64decode(sys.argv[1]).decode());directory=fixture_home/'ipc';directory.mkdir(mode=0o700)
    server=socket.socket(socket.AF_UNIX);server.bind(str(directory/'ipc.sock'));os.chmod(directory/'ipc.sock',0o600);server.listen(1)
    messages=[];fixture_thread='019a0000-0000-7000-8000-000000000001';fixture_client='019a0000-0000-7000-8000-000000000010'
    fixture_owner='019a0000-0000-7000-8000-000000000011'
    def fixture_worker():
        connection,_=server.accept();connection.settimeout(3);buffer=b''
        def readn(n):
            nonlocal buffer
            while len(buffer)<n:
                b=connection.recv(65536)
                if not b:raise EOFError()
                buffer+=b
            b,buffer=buffer[:n],buffer[n:];return b
        def send(v):
            b=json.dumps(v).encode();frame=struct.pack('<I',len(b))+b;connection.sendall(frame[:2]);connection.sendall(frame[2:])
        def stream(change):send({'type':'broadcast','method':'thread-stream-state-changed','version':11,'sourceClientId':fixture_owner,'params':{'hostId':'local','conversationId':fixture_thread,'change':change}})
        try:
            while True:
                message=json.loads(readn(struct.unpack('<I',readn(4))[0]));messages.append(message)
                if message.get('method')=='initialize':
                    # Following can reach the observer before initialize finishes.
                    send({'type':'broadcast','method':'thread-stream-following-changed','version':1,'params':{'hostId':'local','conversationId':fixture_thread,'following':True}})
                    send({'type':'response','method':'initialize','resultType':'success','result':{'clientId':fixture_client}})
                    send({'type':'broadcast','method':'thread-stream-following-changed','version':1,'params':{'hostId':'remote','conversationId':fixture_thread,'following':True}})
                elif message.get('params',{}).get('following') is True:
                    state={'title':'Fixture','threadRuntimeStatus':{'type':'active'},'latestTokenUsageInfo':{'total':{'outputTokens':100}},'turns':[{'turnId':'turn','status':'inProgress','turnStartedAtMs':time.time()*1000-10000,'params':{'input':'PRIVATE INPUT'},'items':[{'id':'model','type':'reasoning','content':'PRIVATE'}]}]}
                    stream({'type':'snapshot','revision':1,'conversationState':state})
                    stream({'type':'patches','baseRevision':1,'revision':2,'patches':[{'op':'replace','path':['turns',0,'items',0,'content'],'value':'PRIVATE DELTA'},{'op':'replace','path':['latestTokenUsageInfo'],'value':{'total':{'outputTokens':120}}}]})
                    stream({'type':'patches','baseRevision':2,'revision':3,'patches':[{'op':'add','path':['turns',0,'items',1],'value':{'id':'tool','type':'commandExecution','status':'inProgress','command':'PRIVATE COMMAND'}}]})
                    stream({'type':'patches','baseRevision':3,'revision':4,'patches':[{'op':'replace','path':['turns',0,'items',1,'status'],'value':'completed'}]})
                    stream({'type':'patches','baseRevision':4,'revision':5,'patches':[{'op':'replace','path':['turns',0,'status'],'value':'completed'}]})
        except (EOFError,OSError):pass
        finally:connection.close()
    threading.Thread(target=fixture_worker,daemon=True).start()
    atexit.register(lambda:print(json.dumps({'testMessages':messages}),flush=True))
    """#
}
