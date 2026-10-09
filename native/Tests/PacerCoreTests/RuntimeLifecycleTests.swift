import XCTest
@testable import PacerCore

final class RuntimeLifecycleTests: XCTestCase {
    private let thread = "019a0000-0000-7000-8000-000000000001"
    private func event(_ method: String, thread: String? = nil, at: Double = 1000, fields: [String: Any] = [:]) -> [String: Any] {
        var value: [String: Any] = ["method": method, "threadId": thread ?? self.thread, "turnId": "turn", "at": at]
        value.merge(fields) { _, new in new }
        return ["kind": "runtime", "event": value]
    }
    func testUnloadAndSystemErrorPreserveCompletedAndInterruptedTurns() {
        for terminal in ["completed", "interrupted"] {
            var state = RuntimeEventState(sourceID: nil, sourceName: nil)
            state.consume(["kind": "status", "connected": true])
            state.consume(event("turn/started"))
            var inbox = CompletionInbox()
            inbox.observe(state.activities, at: Date(timeIntervalSince1970: 1000), retention: 0)
            state.consume(event("turn/completed", at: 1001, fields: ["status": terminal]))
            inbox.observe(state.activities, at: Date(timeIntervalSince1970: 1001), retention: 0)
            for status in ["systemError", "notLoaded"] {
                state.consume(event("thread/status/changed", at: 1002, fields: ["status": status]))
                XCTAssertEqual(state.activities.first?.phase.rawValue, terminal)
            }
            inbox.observe(state.activities, at: Date(timeIntervalSince1970: 1002), retention: 0)
            state.releasePublishedState()
            XCTAssertTrue(state.activities.isEmpty)
            XCTAssertEqual(inbox.activities.first?.phase.rawValue, terminal)
            XCTAssertEqual(inbox.unreadActivities.count, 1)
        }
    }
    func testUnloadAfterTerminalPublicationCannotClearTheCompletionInbox() {
        for ending in ["completed", "interrupted", "failed"] {
            var state = RuntimeEventState(sourceID: "remote-ssh-discovered:gpu.example.com", sourceName: "SSH"), inbox = CompletionInbox()
            state.consume(["kind": "status", "connected": true])
            state.consume(event("turn/started"))
            state.consume(event("turn/completed", at: 1001, fields: ["status": ending]))
            state.consume(event("stream/released", at: 1001.1))
            inbox.observe(state.activities, at: Date(timeIntervalSince1970: 1002), retention: 1800)
            state.releasePublishedState()
            XCTAssertTrue(state.activities.isEmpty)
            for status in ["systemError", "notLoaded"] {
                state.consume(event("thread/status/changed", at: 1003, fields: ["status": status]))
                if status == "notLoaded" { state.consume(event("stream/released", at: 1003.1)) }
                XCTAssertTrue(state.activities.isEmpty, "Late transport status cannot create an unknown task after completion")
                inbox.observe(state.activities, at: Date(timeIntervalSince1970: 1004), retention: 1800)
                state.releasePublishedState()
                XCTAssertEqual(inbox.unreadActivities.count, 1)
                XCTAssertEqual(inbox.unreadActivities.first?.phase, ending == "completed" ? .completed : .interrupted)
            }
            state.consume(event("thread/observed", at: 1005, fields: ["status": "active"]))
            XCTAssertEqual(state.activities.first?.phase, .running)
            state.consume(event("thread/status/changed", at: 1006, fields: ["status": "systemError"]))
            XCTAssertEqual(state.activities.first?.phase, .unknown, "Errors in the next active turn must still invalidate it")
        }
    }
    func testDottedSSHHostDiscoversAndCompletesWithoutAnyFallbackLog() {
        for host in ["remote-ssh-discovered:gpu.example.com", "remote-ssh-discovered:SSH-192.0.2.1"] {
            for suffix in [thread, "rollout-" + thread + ".jsonl"] {
                let activity = SessionActivity(id: host + ":" + suffix, sourceHostID: host)
                XCTAssertEqual(activity.threadID, thread)
                XCTAssertEqual(activity.canonicalized().id, host + ":" + thread)
            }
            var state = RuntimeEventState(sourceID: host, sourceName: "Synthetic SSH"), inbox = CompletionInbox()
            state.consume(["kind": "status", "connected": true])
            state.consume(event("metadata", at: 1000, fields: ["name": "Synthetic SSH task"]))
            state.consume(event("thread/observed", at: 1001, fields: ["status": "idle"]))
            state.consume(event("thread/observed", at: 1002, fields: ["status": "active"]))
            XCTAssertEqual(state.activities.first?.phase, .running)
            XCTAssertEqual(state.activities.first?.threadID, thread)
            XCTAssertTrue(state.activities.first?.liveTurnStarted == true)
            inbox.observe(state.activities, at: Date(timeIntervalSince1970: 1002), retention: 1800)
            state.consume(event("item/started", at: 1003, fields: ["itemId": "tool", "itemType": "commandExecution"]))
            XCTAssertEqual(state.activities.first?.turnID, "turn")
            XCTAssertEqual(state.activities.first?.stage, .tool)
            state.consume(event("turn/completed", at: 1004, fields: ["status": "completed"]))
            state.consume(event("stream/released", at: 1004.1))
            inbox.observe(state.activities, at: Date(timeIntervalSince1970: 1005), retention: 1800)
            state.releasePublishedState()
            XCTAssertTrue(state.activities.isEmpty)
            XCTAssertEqual(inbox.unreadActivities.first?.phase, .completed)
            XCTAssertEqual(inbox.unreadActivities.first?.sourceHostID, host)
        }
    }
    func testSystemErrorOverridesOldFallbackUntilFreshEvidenceArrives() throws {
        var fallback = SessionActivity(id: thread, phaseAwareRate: true)
        fallback.consume(try JSONSerialization.data(withJSONObject: ["timestamp": "1970-01-01T00:16:40Z", "type": "event_msg",
            "payload": ["type": "task_started", "turn_id": "turn"]]))
        var state = RuntimeEventState(sourceID: nil, sourceName: nil)
        state.replaceLocalFallback([fallback])
        state.consume(["kind": "status", "connected": true])
        state.consume(event("turn/started", at: 1001))
        state.consume(event("thread/status/changed", at: 1002, fields: ["status": "systemError"]))
        for _ in 0..<3 {
            state.replaceLocalFallback([fallback])
            state.releasePublishedState()
            state.consume(["kind": "status", "connected": true])
            let value = try XCTUnwrap(state.activities.first)
            XCTAssertEqual(value.phase, .unknown)
            XCTAssertEqual(value.phaseChangedAt, Date(timeIntervalSince1970: 1002))
            XCTAssertFalse(value.hasLiveEvidence)
        }
        var inbox = CompletionInbox()
        inbox.observe(state.activities, at: Date(timeIntervalSince1970: 1003), retention: 1800)
        XCTAssertTrue(inbox.unreadActivities.isEmpty, "Transport errors are not task completions")
        state.consume(event("turn/started", at: 1004, fields: ["turnId": "next"]))
        XCTAssertEqual(state.activities.first?.phase, .running)
        XCTAssertEqual(state.activities.first?.turnID, "next")
    }
    func testLoadedDiscoveryReachesLaterPagesWithBoundedRequestsAndReusesFreedSlots() throws {
        let script = #"""
        class Fake:
            def __init__(self):self.sent=[]
            def send(self,v):self.sent.append(v)
        def tid(i):return str(uuid.UUID(int=i+1))
        ws=Fake();s=Session(ws);s.receive({'id':1,'result':{}})
        catalog=[tid(i) for i in range(145)]
        read=[];pages=[];max_reads=0
        def reply():
            global max_reads
            max_reads=max(max_reads,sum(v[0]=='read' for v in s.pending.values()))
            assert len(s.attached|s.attaching)+sum(v[0]=='read' for v in s.pending.values())<=32
            rid,(kind,id,_) = next(iter(s.pending.items()))
            if kind=='list':
                request=next(v for v in ws.sent if v.get('id')==rid)
                assert request['params']['limit']==64
                offset=int(request['params'].get('cursor','0'));pages.append(offset)
                s.receive({'id':rid,'result':{'data':catalog[offset:offset+64], 'nextCursor':str(offset+64) if offset+64<len(catalog) else None}})
            else:
                if kind=='read':read.append(id)
                # The entire first page and more are idle, followed by 40 active threads.
                index=catalog.index(id);active=index>=105
                if index==10:
                    s.receive({'id':rid,'error':{'code':-1}})
                else:
                    s.receive({'id':rid,'result':{'thread':{'id':id,'status':{'type':'active' if active else 'idle'}}}})
            s.queue=[] # The real publisher flushes each batch on its deadline.
        while s.pending:reply()
        assert pages==[0,64,128] and max_reads==8
        assert len(s.attached)==32 and len(s.read_queue)==8
        assert tid(105) in s.attached,'idle prefix must not starve later active tasks'
        assert len(s.known)<=64 and not s.request_loaded(),'a scan waits for capacity without restarting its first page'
        for i in range(105,113):
            s.receive({'method':'turn/completed','params':{'threadId':tid(i),'turn':{'id':'turn','status':'completed'}}})
            while s.pending:reply()
        assert not s.listing and not s.read_queue and len(s.attached)==32
        assert all(tid(i) in s.attached for i in range(137,145))
        assert read==catalog,'each metadata entry is visited once per scan'
        # Repeated cursors are rejected rather than entering an infinite scan.
        ws=Fake();s=Session(ws);s.receive({'id':1,'result':{}})
        rid=next(iter(s.pending));s.receive({'id':rid,'result':{'data':[],'nextCursor':'same'}})
        rid=next(iter(s.pending))
        try:s.receive({'id':rid,'result':{'data':[],'nextCursor':'same'}})
        except ValueError:pass
        else:raise AssertionError('cursor cycle accepted')
        # Endings and tool boundaries bypass batching. A busy long batch flushes
        # at 512 events, preserving the order and wire-size bound without reconnect.
        s.queue=[];packets=[];emit=lambda value:packets.append(value)
        s.queue_event({'method':'turn/completed','threadId':tid(0),'turnId':'turn','at':0})
        assert len(packets)==1 and packets[0]['events'][0]['method']=='turn/completed' and not s.queue
        for method in ('item/started','item/completed'):
            for kind in ('commandExecution','collabToolCall','collabAgentToolCall'):
                packets=[];s.queue_event({'method':method,'threadId':tid(0),'turnId':'turn','itemType':kind,'at':0})
                assert len(packets)==1 and not s.queue
        packets=[]
        for i in range(513):
            s.queue_event({'method':'item/plan/delta','threadId':tid(i),'turnId':'turn','at':i})
        assert [len(p['events']) for p in packets]==[512] and len(s.queue)==1
        flush_events(s)
        assert [len(p['events']) for p in packets]==[512,1] and not s.queue
        assert [e['at'] for p in packets for e in p['events']]==list(range(513))
        print('bounded discovery passed')
        """#
        XCTAssertTrue(try python(RealtimeProbe.library + "\n" + script).contains("bounded discovery passed"))
    }
    func testPublishingReleaseReclaimsStateButNewTurnBeforePublishSurvives() {
        var state = RuntimeEventState(sourceID: nil, sourceName: nil)
        state.consume(["kind": "status", "connected": true])
        for _ in 0..<1000 {
            let id = UUID().uuidString.lowercased()
            state.consume(event("turn/started", thread: id))
            state.consume(event("turn/completed", thread: id, at: 1001, fields: ["status": "completed"]))
            state.consume(event("stream/released", thread: id, at: 1002))
            XCTAssertEqual(state.activities.count, 1)
            state.releasePublishedState()
            XCTAssertTrue(state.activities.isEmpty)
        }
        state.consume(event("turn/started"))
        state.consume(event("stream/released", at: 1001))
        state.consume(event("turn/started", at: 1002, fields: ["turnId": "new"]))
        state.releasePublishedState()
        XCTAssertEqual(state.activities.first?.turnID, "new")
        XCTAssertEqual(state.activities.first?.phase, .running)
    }
    func testFailureAndApprovalEvidenceResetAtTheNextTurn() throws {
        var state = RuntimeEventState(sourceID: nil, sourceName: nil)
        state.consume(["kind": "status", "connected": true])
        state.consume(event("turn/started"))
        state.consume(event("thread/status/changed", at: 1001, fields: ["status": "active", "flags": ["waitingOnApproval"]]))
        XCTAssertTrue(try XCTUnwrap(state.activities.first).waitingForApproval)
        var inbox = CompletionInbox()
        inbox.observe(state.activities, at: Date(timeIntervalSince1970: 1001), retention: 0)
        state.consume(event("turn/completed", at: 1002, fields: ["status": "failed"]))
        let failed = try XCTUnwrap(state.activities.first)
        XCTAssertEqual(failed.phase, .interrupted, "Failure keeps the existing terminal lifecycle")
        XCTAssertTrue(failed.turnFailed)
        XCTAssertFalse(failed.waitingForApproval)
        XCTAssertNil(failed.outputEstimate(at: Date(timeIntervalSince1970: 1002)))
        inbox.observe(state.activities, at: Date(timeIntervalSince1970: 1002), retention: 0)
        state.releasePublishedState()
        XCTAssertTrue(inbox.unreadActivities.first?.turnFailed == true)
        state.consume(event("turn/started", at: 1003, fields: ["turnId": "next"]))
        XCTAssertFalse(try XCTUnwrap(state.activities.first).turnFailed)
        XCTAssertFalse(try XCTUnwrap(state.activities.first).waitingForApproval)
        state.consume(event("turn/completed", at: 1004, fields: ["turnId": "next", "status": "interrupted"]))
        XCTAssertFalse(try XCTUnwrap(state.activities.first).turnFailed, "Interruption is distinct from explicit failure")
    }
    func testChunkedFallbackIsAtomicAndRejectsGap() {
        var state = RuntimeEventState(sourceID: nil, sourceName: nil)
        let previous = SessionActivity(id: "local:" + thread)
        state.replaceLocalFallback([previous])
        let second = "019a0000-0000-7000-8000-000000000002"
        func chunk(_ part: Int, _ final: Bool, _ id: String) -> [String: Any] {
            ["kind": "fallbackChunk", "snapshotId": "snapshot", "part": part, "final": final,
             "sessions": [["id": "rollout-" + id + ".jsonl", "reset": true, "records": []]]]
        }
        state.consume(chunk(0, false, second))
        XCTAssertEqual(state.activities.first?.id, previous.id)
        state.consume(chunk(2, true, second))
        XCTAssertEqual(state.activities.first?.id, previous.id)
        state.consume(chunk(0, false, thread))
        state.consume(chunk(1, true, second))
        XCTAssertEqual(Set(state.activities.compactMap(\.threadID)), Set([thread, second]))
    }

    func testHelpersRecycleSubscriptionsAndQueueWaitingThread() throws {
        let script = #"""
        class Fake:
            def __init__(self):self.sent=[]
            def send(self,v):self.sent.append(v)
        def tid(i):return str(uuid.UUID(int=i+1))
        def follow(i):return {'type':'broadcast','method':'thread-stream-following-changed','version':1,'params':{'hostId':'local','conversationId':tid(i),'following':True}}
        ipc=Fake();s=DesktopSession(ipc)
        s.receive({'type':'response','method':'initialize','resultType':'success','result':{'clientId':tid(1000)}})
        def snapshot(i,rev,status):
            s.receive({'type':'broadcast','method':'thread-stream-state-changed','version':11,'sourceClientId':tid(2000),'params':{'hostId':'local','conversationId':tid(i),'change':{'type':'snapshot','revision':rev,'conversationState':{'turns':[{'turnId':'turn','status':status}]}}}})
        for i in range(32):s.receive(follow(i));snapshot(i,0,'inProgress')
        s.receive(follow(32));assert tid(32) not in s.followed
        snapshot(0,1,'completed')
        assert tid(0) not in s.followed and tid(32) in s.followed and len(s.followed)==32
        assert any(e['method']=='turn/completed' for e in s.queue)
        assert any(e['method']=='stream/released' for e in s.queue)
        s.queue=[]
        ws=Fake();r=Session(ws);r.receive({'id':1,'result':{}})
        rid=next(k for k,v in r.pending.items() if v[0]=='list');r.receive({'id':rid,'result':{'data':[]}})
        for i in range(40):
            id=tid(i);r.read_thread(id)
            rid=next(k for k,v in r.pending.items() if v[0]=='read' and v[1]==id)
            r.receive({'id':rid,'result':{'thread':{'id':id,'status':{'type':'active'}}}})
            rid=next(k for k,v in r.pending.items() if v[0]=='resume' and v[1]==id)
            r.receive({'id':rid,'result':{'thread':{'id':id,'status':{'type':'active'}}}})
            r.receive({'method':'thread/status/changed','params':{'threadId':id,'status':{'type':'idle'}}})
            assert id in r.attached,'idle alone must not end an observed turn'
            r.receive({'method':'turn/completed','params':{'threadId':id,'turn':{'id':'turn','status':'completed'}}})
            assert id not in r.attached and id not in r.known
            assert not any(v[1]==id for v in r.pending.values())
            r.queue=[]
        print('subscription lifecycle passed')
        """#
        XCTAssertTrue(try python(DesktopEventProbe.library + "\n" + script).contains("lifecycle passed"))
    }

    func testLargeSnapshotFramesReconstructExactlyLikeLegacy() throws {
        let script = #"""
        now=datetime.datetime.now(datetime.timezone.utc).isoformat()
        records=[{'timestamp':now,'type':'event_msg','payload':{'type':'task_started','turn_id':'turn'}}]
        # Cross the same wire boundaries with fewer records. Padding is ignored
        # by activity decoding; counters still exercise ordered reconstruction.
        records += [{'timestamp':now,'type':'event_msg','payload':{'type':'token_count','info':{'total_token_usage':{'output_tokens':i}},'fixturePadding':'x'*4096}} for i in range(64)]
        frame={'sessions':[{'id':'rollout-'+str(uuid.UUID(int=i+1))+'.jsonl','reset':True,'records':records*4 if i==0 else records} for i in range(16)]}
        assert len(json.dumps(frame).encode())>4*1024*1024
        packets=[]
        emit=lambda v:packets.append(json.loads(v) if isinstance(v,bytes) else v)
        small={'sessions':[dict(frame['sessions'][0],records=records[:16])]}
        emit_snapshot(small)
        assert packets==[small],'small snapshot must retain its original wire contents'
        packets=[]
        emit_snapshot(frame)
        print(json.dumps({'packets':packets,'legacy':frame},separators=(',',':')))
        """#
        let value = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(try python(RealtimeProbe.library + "\n" + script).utf8)) as? [String: Any])
        let frames = try XCTUnwrap(value["packets"] as? [[String: Any]])
        XCTAssertGreaterThan(frames.count, 1)
        let firstSession = "rollout-00000000-0000-0000-0000-000000000001.jsonl"
        let parts = frames.compactMap { $0["sessions"] as? [[String: Any]] }.flatMap { $0 }
            .filter { $0["id"] as? String == firstSession }
        XCTAssertGreaterThan(parts.count, 1, "A single session must still cross the frame boundary")
        XCTAssertEqual(parts.first?["reset"] as? Bool, true)
        XCTAssertTrue(parts.dropFirst().allSatisfy { $0["continuation"] as? Bool == true && $0["reset"] as? Bool == false })
        var chunked = RuntimeEventState(sourceID: "remote-ssh-discovered:test", sourceName: "test")
        var legacy = chunked
        legacy.consume(try XCTUnwrap(value["legacy"] as? [String: Any]))
        for (index, frame) in frames.enumerated() {
            XCTAssertLessThanOrEqual(try JSONSerialization.data(withJSONObject: frame).count, 1024 * 1024)
            chunked.consume(frame)
            if index < frames.count - 1 { XCTAssertTrue(chunked.activities.isEmpty) }
        }
        XCTAssertEqual(chunked.activities.sorted { $0.id < $1.id }, legacy.activities.sorted { $0.id < $1.id })
    }

    func testPipeBackpressurePreservesBurstLargerThanStreamCapacity() async throws {
        let child = Process(), output = Pipe()
        let childEnded = expectation(description: "Burst writer exited")
        child.terminationHandler = { _ in childEnded.fulfill() }
        child.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        child.arguments = ["-c", "import os; data=b'x'*(8*1024*1024);\nwhile data:\n n=os.write(1,data);data=data[n:]"]
        child.standardOutput = output; child.standardError = FileHandle.nullDevice
        let reader = PipeChunkReader(descriptor: output.fileHandleForReading.fileDescriptor)
        let channel = AsyncStream<Data>.makeStream(bufferingPolicy: .bufferingOldest(64))
        let handler = reader.pausingHandler(channel.continuation)
        output.fileHandleForReading.readabilityHandler = handler
        defer { reader.stop(); output.fileHandleForReading.readabilityHandler = nil; try? output.fileHandleForReading.close() }
        try child.run()
        var received = 0
        for await bytes in channel.stream {
            received += bytes.count
            try await Task.sleep(nanoseconds: 1_000_000)
            output.fileHandleForReading.readabilityHandler = handler
        }
        // Foundation's synchronous exit wait can stall on an async executor
        // after pipe EOF; observe the callback established before launch.
        await fulfillment(of: [childEnded], timeout: 5)
        XCTAssertEqual(child.terminationStatus, 0)
        XCTAssertEqual(received, 8 * 1024 * 1024)
    }

    func testIdleMetadataIsBoundedAndClearedOnDisconnect() {
        var state = RuntimeEventState(sourceID: nil, sourceName: nil)
        state.consume(["kind": "status", "connected": true])
        for _ in 0..<1000 { state.consume(event("metadata", thread: UUID().uuidString.lowercased(), fields: ["name": "Synthetic"])) }
        let fields = Mirror(reflecting: state).children
        XCTAssertLessThanOrEqual((fields.first { $0.label == "live" }?.value as? [String: SessionActivity])?.count ?? 0, 64)
        XCTAssertLessThanOrEqual(state.nameUpdates.count, 64, "Display metadata shares the bounded idle cache")
        state.consume(["kind": "status", "connected": false])
        let cleared = Mirror(reflecting: state).children
        XCTAssertTrue((cleared.first { $0.label == "idleOrder" }?.value as? [String: Int])?.isEmpty == true)
        XCTAssertTrue(state.nameUpdates.isEmpty)
    }

    func testRemoteNameUpdatesDoNotChangeTurnStateAndClearedNamesDoNotReturnFromCache() {
        let host = "remote-ssh-discovered:synthetic"
        var logged = SessionActivity(id: host + ":" + thread, sourceHostID: host)
        logged.consumeLive(["method": "metadata", "threadId": thread, "at": 999.0, "name": "Cached session name"])
        logged.consumeLive(["method": "turn/started", "threadId": thread, "turnId": "turn", "at": 999.0])
        var state = RuntimeEventState(sourceID: host, sourceName: "Synthetic")
        state.consume(["kind": "status", "connected": true])
        state.consume(event("turn/started"))
        XCTAssertEqual(ActivitySourceMerger.merge(logged: [logged], streamed: state.activities).first?.title, "Cached session name")
        state.consume(event("thread/tokenUsage/updated", at: 1001, fields: ["outputTokens": 100]))
        state.consume(event("thread/tokenUsage/updated", at: 1003, fields: ["outputTokens": 120]))
        let before = state.activities[0]
        state.consume(event("thread/name/updated", at: 1004, fields: ["name": "Renamed session"]))
        let updated = state.activities[0]
        XCTAssertEqual(updated.title, "Renamed session")
        XCTAssertEqual(updated.phase, before.phase)
        XCTAssertEqual(updated.turnID, before.turnID)
        XCTAssertEqual(updated.lastObserved, before.lastObserved)
        XCTAssertEqual(updated.tokensPerSecond(at: Date(timeIntervalSince1970: 1004)), before.tokensPerSecond(at: Date(timeIntervalSince1970: 1004)))
        state.consume(event("metadata", at: 1004, fields: ["name": " \n "]))
        XCTAssertEqual(state.activities[0].title, "Renamed session", "Incomplete RPC metadata cannot erase a known name")
        state.consume(event("thread/name/updated", at: 1005, fields: ["name": NSNull()]))
        XCTAssertNil(ActivitySourceMerger.merge(logged: [logged], streamed: state.activities).first?.title)
        var otherHost = SessionActivity(id: "local:" + thread)
        otherHost.consumeLive(["method": "metadata", "threadId": thread, "at": 999.0, "name": "Other host name"])
        XCTAssertNil(ActivitySourceMerger.merge(logged: [otherHost], streamed: state.activities).first { $0.sourceHostID == host }?.title)
    }

    func testRemoteNameNotificationsAndEphemeralThreadsStayWithinTheSanitizedProtocol() throws {
        let script = #"""
        class Fake:
            def __init__(self):self.sent=[]
            def send(self,v):self.sent.append(v)
        tid='019a0000-0000-7000-8000-000000000001'
        ws=Fake();s=Session(ws);s.ready=True;s.pending.clear()
        s.known[tid]={'type':'active'};s.attached.add(tid)
        before=len(ws.sent)
        s.receive({'method':'thread/name/updated','params':{'threadId':tid,'threadName':'A'*300,'extra':'PRIVATE'}})
        assert s.queue[-1]['method']=='thread/name/updated' and s.queue[-1]['name']=='A'*240
        assert len(ws.sent)==before,'attached task renames need no new metadata RPC'
        assert 'PRIVATE' not in repr(s.queue)
        s.receive({'method':'thread/name/updated','params':{'threadId':tid,'threadName':None}})
        assert s.queue[-1]['name'] is None
        before=len(s.queue)
        s.receive({'method':'thread/name/updated','params':{'threadId':tid,'threadName':42}})
        assert len(s.queue)==before,'malformed names cannot erase a known title'
        s.receive({'method':'thread/name/updated','params':{'threadId':tid}})
        assert len(s.queue)==before,'an absent field is not an explicit name removal'
        for source in ({'ephemeral':True},{'source':{'subAgent':{'other':'guardian'}}}):
            ws=Fake();s=Session(ws);s.ready=True;s.pending.clear()
            s.receive({'method':'thread/started','params':{'thread':dict(source,id=tid,status={'type':'active'})}})
            assert tid in s.excluded and not s.queue and not ws.sent[1:]
            ws=Fake();s=Session(ws);s.ready=True;s.pending.clear()
            s.request('thread/read',{'threadId':tid},'read',tid);rid=ws.sent[-1]['id']
            s.receive({'id':rid,'result':{'thread':dict(source,id=tid,status={'type':'active'})}})
            assert tid in s.excluded and tid not in s.known and not s.attached and not s.queue
        ws=Fake();s=Session(ws);s.ready=True;s.pending.clear()
        s.request('thread/read',{'threadId':tid},'read',tid);rid=ws.sent[-1]['id']
        s.receive({'method':'thread/started','params':{'thread':{'id':tid,'ephemeral':True}}})
        s.receive({'id':rid,'result':{'thread':{'id':tid,'status':{'type':'active'}}}})
        assert tid not in s.known and not s.attached and not s.queue,'an in-flight reply cannot recreate an excluded task'
        for initial in (True,False):
            p=Projection(tid)
            raw={'ephemeral':initial,'turns':[]}
            try:
                p.consume({'type':'snapshot','revision':0,'conversationState':raw},'owner')
                p.consume({'type':'patches','baseRevision':0,'revision':1,'patches':[{'op':'replace','path':['ephemeral'],'value':True}]},'owner')
            except ValueError as e:assert str(e)=='excluded ephemeral'
            else:raise AssertionError('compatibility projection retained an ephemeral thread')
        print('remote metadata passed')
        """#
        XCTAssertTrue(try python(DesktopEventProbe.library + "\n" + script).contains("remote metadata passed"))
    }

    private func python(_ script: String) throws -> String {
        let child = Process(), output = Pipe(), error = Pipe()
        child.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        child.arguments = ["-u", "-c", script, Data("/private/tmp/pacer-no-user-data".utf8).base64EncodedString()]
        child.standardOutput = output; child.standardError = error
        try child.run()
        let result = output.fileHandleForReading.readDataToEndOfFile(); child.waitUntilExit()
        XCTAssertEqual(child.terminationStatus, 0, String(decoding: error.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self))
        return String(decoding: result, as: UTF8.self)
    }
}
