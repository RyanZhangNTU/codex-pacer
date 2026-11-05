import XCTest
@testable import PacerCore

final class RealtimeTransportTests: XCTestCase {
    private let active = "019a0000-0000-7000-8000-000000000001"
    private func runProbe(badAccept: Bool = false, server: Bool = true, hintOnly: Bool = false, indexOnly: Bool = false, closeAfterTerminal: Bool = false) throws -> String {
        let home = URL(fileURLWithPath: "/private/tmp/pacer-ws-" + String(UUID().uuidString.prefix(8)))
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        var prefix = server ? Self.fixture.replacingOccurrences(of: "BAD_ACCEPT", with: badAccept ? "True" : "False") : ""
        if closeAfterTerminal {
            prefix = prefix.replacingOccurrences(of: "send({'method':'turn/completed'", with: "time.sleep(.05);send({'method':'turn/completed'")
            prefix = prefix.replacingOccurrences(of: "'PRIVATE final'}]}}})", with: "'PRIVATE final'}]}}});time.sleep(.01);break")
        }
        if hintOnly || indexOnly {
            prefix = prefix.replacingOccurrences(of: "result={'data':[fixture_active,fixture_idle,fixture_review]}", with: indexOnly ? "result={'data':[fixture_active] if fixture_ready.is_set() else []}" : "result={'data':[]}")
            let first = try XCTUnwrap(prefix.range(of: "send({'method':'item/agentMessage/delta'"))
            let last = try XCTUnwrap(prefix.range(of: "send({'method':'turn/completed'", range: first.lowerBound..<prefix.endIndex))
            let line = prefix[..<first.lowerBound].lastIndex(of: "\n").map { prefix.index(after: $0) } ?? prefix.startIndex
            let indent = String(prefix[line..<first.lowerBound])
            prefix.replaceSubrange(first.lowerBound..<last.lowerBound, with: "time.sleep(.35)\n" + indent)
        }
        if indexOnly {
            let setup = #"""
            fixture_ready=threading.Event();fixture_finished=threading.Event()
            fixture_index=fixture_home/'state_5.sqlite-wal';fixture_index.write_bytes(b'0')
            def fixture_activate():
                fixture_index.write_bytes(b'1');threading.Timer(.6,fixture_ready.set).start()
            """#
            prefix = prefix.replacingOccurrences(of: "fixture_dir=", with: setup + "\nfixture_dir=")
            prefix = prefix.replacingOccurrences(of: "send({'id':v['id'],'result':result})", with: "send({'id':v['id'],'result':result})\n            if method=='thread/loaded/list' and not fixture_ready.is_set():threading.Timer(.3,fixture_activate).start()")
            prefix = prefix.replacingOccurrences(of: "tid==fixture_idle else 'active'", with: "tid==fixture_idle or fixture_finished.is_set() else 'active'")
            prefix = prefix.replacingOccurrences(of: "'PRIVATE final'}]}}})", with: "'PRIVATE final'}]}}});fixture_finished.set()")
        }
        let child = Process(), stdout = Pipe(), stdin = Pipe(), stderr = Pipe()
        child.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        child.arguments = ["-u", "-c", prefix + "\n" + RealtimeProbe.script, Data(home.path.utf8).base64EncodedString(), hintOnly || indexOnly ? "ssh-lifetime" : "once"]
        child.standardOutput = stdout; child.standardError = stderr
        if hintOnly || indexOnly { child.standardInput = stdin }
        try child.run()
        if hintOnly {
            let hint = try JSONSerialization.data(withJSONObject: ["kind": "discover", "threadIds": [active]]) + Data([10])
            try stdin.fileHandleForWriting.write(contentsOf: hint)
        }
        if hintOnly || indexOnly {
            DispatchQueue.global().asyncAfter(deadline: .now() + (indexOnly ? 3.5 : 1.5)) { try? stdin.fileHandleForWriting.close() }
        }
        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        child.waitUntilExit()
        XCTAssertEqual(child.terminationStatus, 0, String(decoding: stderr.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self))
        return String(decoding: data, as: UTF8.self)
    }
    func testAutomaticCadenceUsesFiveSecondsAndExpandingFlushesWithoutResubscribe() async throws {
        final class Capture: @unchecked Sendable {
            let lock = NSLock()
            var buffer = Data(), all = Data(), names = Set<String>()
            func append(_ data: Data) -> Set<String> {
                lock.lock(); defer { lock.unlock() }
                buffer.append(data); all.append(data); var added = Set<String>()
                while let end = buffer.firstIndex(of: 10) {
                    let line = buffer[..<end]; buffer.removeSubrange(...end)
                    let value = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] ?? [:]
                    if let kind = value["kind"] as? String, ["testCadenceQueued", "testCadenceChecked"].contains(kind) {
                        added.insert(kind)
                    }
                    for event in value["events"] as? [[String: Any]] ?? [] {
                        if let name = event["name"] as? String, names.insert(name).inserted { added.insert(name) }
                    }
                }
                return added
            }
            func has(_ name: String) -> Bool { lock.lock(); defer { lock.unlock() }; return names.contains(name) }
            func output() -> Data { lock.lock(); defer { lock.unlock() }; return all }
        }
        let home = URL(fileURLWithPath: "/private/tmp/pacer-controlled-cadence-" + String(UUID().uuidString.prefix(8)))
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        var prefix = Self.fixture.replacingOccurrences(of: "BAD_ACCEPT", with: "False")
        let first = try XCTUnwrap(prefix.range(of: "send({'method':'item/agentMessage/delta','params':dict(common"))
        let end = try XCTUnwrap(prefix.range(of: "send({'method':'turn/completed'", range: first.lowerBound..<prefix.endIndex))
        let line = prefix[..<first.lowerBound].lastIndex(of: "\n").map { prefix.index(after: $0) } ?? prefix.startIndex
        let indent = String(prefix[line..<first.lowerBound])
        let replacement = """
        send({'method':'item/agentMessage/delta','params':dict(common,itemId='reply',delta='PRIVATE reply')})
        send({'method':'thread/name/updated','params':{'threadId':fixture_active,'threadName':'cadence-initial'}})
        fixture_pending_gate.wait()
        send({'method':'thread/name/updated','params':{'threadId':fixture_active,'threadName':'cadence-pending'}})
        threading.Event().wait(30)
        """
        prefix.replaceSubrange(first.lowerBound..<end.lowerBound, with: replacement.replacingOccurrences(of: "\n", with: "\n" + indent) + "\n" + indent)
        // Start-up is independent of the cadence under test. Release the
        // pending event only after the helper has applied collapsed settings.
        prefix = "import threading\nfixture_pending_gate=threading.Event()\n" + prefix
        let clock = """
        fixture_clock=None
        fixture_base=None
        fixture_check_after_loop=False
        fixture_real_monotonic=time.monotonic
        time.monotonic=lambda:fixture_real_monotonic() if fixture_clock is None else fixture_clock
        fixture_receive=Session.receive
        def fixture_received(self,value):
            result=fixture_receive(self,value)
            if isinstance(value,dict) and value.get('method')=='thread/name/updated' and value.get('params',{}).get('threadName')=='cadence-pending':
                emit({'kind':'testCadenceQueued'})
            return result
        Session.receive=fixture_received
        """
        var main = String(RealtimeProbe.script.dropFirst(RealtimeProbe.library.count))
        let globals = "global hint_buffer,batch_interval,flush_at"
        let interval = "batch_interval=interval;now=time.monotonic()"
        let settings = "if isinstance(value,dict) and value.get('kind')=='settings':"
        let reschedule = "if request_logs:request_logs.reschedule(now,interval,flush)"
        let stamp = "stamp=(bool(session and session.ready),len(session.attached) if session else 0)"
        for marker in [globals, interval, settings, reschedule, stamp] { XCTAssertTrue(main.contains(marker)) }
        main = main.replacingOccurrences(of: globals, with: globals + ",fixture_clock,fixture_base,fixture_check_after_loop,now")
        main = main.replacingOccurrences(of: interval, with:
            "if interval==5 and fixture_clock is None:fixture_clock=fixture_base=last_flush\n                " + interval)
        main = main.replacingOccurrences(of: settings, with:
            "if isinstance(value,dict) and value.get('kind')=='testClock':\n" +
            "            fixture_clock=fixture_base+value['at'];now=fixture_clock;fixture_check_after_loop=True;continue\n        " + settings)
        main = main.replacingOccurrences(of: reschedule, with: reschedule +
            "\n                if interval==5:fixture_pending_gate.set()")
        main = main.replacingOccurrences(of: stamp, with:
            "if fixture_check_after_loop:emit({'kind':'testCadenceChecked'});fixture_check_after_loop=False\n        " + stamp)
        let child = Process(), stdout = Pipe(), stdin = Pipe(), stderr = Pipe()
        child.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        child.arguments = ["-u", "-c", prefix + "\n" + RealtimeProbe.library + "\n" + clock + "\n" + main,
                           Data(home.path.utf8).base64EncodedString(), "ssh-lifetime", "5"]
        child.standardOutput = stdout; child.standardInput = stdin; child.standardError = stderr
        let capture = Capture(), initial = expectation(description: "initial ordinary batch"), expanded = expectation(description: "pending batch on expansion")
        let queued = expectation(description: "pending event received after collapsed settings"), checked = expectation(description: "logical cadence evaluated")
        stdout.fileHandleForReading.readabilityHandler = { handle in
            let names = capture.append(handle.availableData)
            if names.contains("cadence-initial") { initial.fulfill() }
            if names.contains("cadence-pending") { expanded.fulfill() }
            if names.contains("testCadenceQueued") { queued.fulfill() }
            if names.contains("testCadenceChecked") { checked.fulfill() }
        }
        defer { stdout.fileHandleForReading.readabilityHandler = nil; if child.isRunning { child.terminate() } }
        try child.run()
        try stdin.fileHandleForWriting.write(contentsOf: Data("{\"kind\":\"settings\",\"batchInterval\":1,\"flushPending\":true}\n".utf8))
        await fulfillment(of: [initial], timeout: TestWait.limit)
        guard child.isRunning else {
            XCTFail(String(decoding: stderr.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)); return
        }
        try stdin.fileHandleForWriting.write(contentsOf: Data("{\"kind\":\"settings\",\"batchInterval\":5,\"flushPending\":false}\n".utf8))
        await fulfillment(of: [queued], timeout: TestWait.limit)
        // Advance the helper's monotonic clock after the event is queued.
        // A one-second clamp would flush it; the required five seconds do not.
        try stdin.fileHandleForWriting.write(contentsOf: Data("{\"kind\":\"testClock\",\"at\":2.3}\n".utf8))
        await fulfillment(of: [checked], timeout: TestWait.limit)
        XCTAssertFalse(capture.has("cadence-pending"), "Collapsed batches must not be clamped to the old one-second limit")
        try stdin.fileHandleForWriting.write(contentsOf: Data("{\"kind\":\"settings\",\"batchInterval\":1,\"flushPending\":true}\n".utf8))
        await fulfillment(of: [expanded], timeout: TestWait.limit)
        try stdin.fileHandleForWriting.close(); child.waitUntilExit()
        stdout.fileHandleForReading.readabilityHandler = nil
        _ = capture.append(stdout.fileHandleForReading.readDataToEndOfFile())
        XCTAssertEqual(child.terminationStatus, 0, String(decoding: stderr.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self))
        let frames = try String(decoding: capture.output(), as: UTF8.self).split(separator: "\n").map { try JSONSerialization.jsonObject(with: Data($0.utf8)) as! [String: Any] }
        let requests = try XCTUnwrap(frames.last?["testRequests"] as? [[String: Any]])
        XCTAssertEqual(requests.filter { $0["method"] as? String == "initialize" }.count, 1)
        XCTAssertEqual(requests.filter { $0["method"] as? String == "thread/resume" }.count, 1)
        XCTAssertFalse(String(decoding: capture.output(), as: UTF8.self).contains("PRIVATE"))
    }

    func testStdinDiscoveryObservesQuietActiveTaskAndExplicitEndingWithoutItemReplay() throws {
        try assertQuietTaskLifecycle(runProbe(hintOnly: true))
    }
    func testIndexWriteDiscoversTaskWithoutDesktopHintOrRuntimeAnnouncement() throws {
        let output = try runProbe(indexOnly: true)
        try assertQuietTaskLifecycle(output)
        let frames = try output.split(separator: "\n").map { try JSONSerialization.jsonObject(with: Data($0.utf8)) as! [String: Any] }
        let requests = try XCTUnwrap(frames.last?["testRequests"] as? [[String: Any]])
        let lists = requests.filter { $0["method"] as? String == "thread/loaded/list" }.count
        XCTAssertTrue((2...4).contains(lists), "An in-place index write must trigger bounded discovery retries")
        XCTAssertEqual(requests.filter { $0["method"] as? String == "thread/resume" }.count, 1)
    }
    private func assertQuietTaskLifecycle(_ output: String) throws {
        var state = RuntimeEventState(sourceID: "remote-ssh-discovered:fixture", sourceName: "SSH"), inbox = CompletionInbox()
        var sawActive = false
        for line in output.split(separator: "\n") {
            let frame = try JSONSerialization.jsonObject(with: Data(line.utf8)) as! [String: Any]
            state.consume(frame)
            sawActive = sawActive || state.activities.contains { $0.phase == .running && $0.turnID == nil && $0.hasLiveEvidence }
            inbox.observe(state.activities, at: Date(), retention: 1800)
            state.releasePublishedState()
        }
        XCTAssertTrue(sawActive, "Discovery must publish a quiet running task before any item event")
        XCTAssertEqual(inbox.unreadActivities.count, 1)
        XCTAssertEqual(inbox.unreadActivities.first?.turnID, "test-turn")
        XCTAssertFalse(output.contains("PRIVATE"))
    }
    func testRealUnixWebSocketFramesSubscribeOnlyActiveUserThreadAndDropContent() throws {
        let output = try runProbe()
        XCTAssertFalse(output.contains("PRIVATE"))
        let frames = try output.split(separator: "\n").map { try JSONSerialization.jsonObject(with: Data($0.utf8)) as! [String: Any] }
        let requests = try XCTUnwrap(frames.first(where: { $0["testRequests"] != nil })?["testRequests"] as? [[String: Any]])
        let allowed: Set<String> = ["initialize", "thread/loaded/list", "thread/read", "thread/resume"]
        XCTAssertTrue(requests.allSatisfy { allowed.contains($0["method"] as? String ?? "") })
        let resumes = requests.filter { $0["method"] as? String == "thread/resume" }
        XCTAssertEqual(resumes.count, 1)
        let reviewReads = requests.filter { $0["method"] as? String == "thread/read" &&
            ($0["params"] as? [String: Any])?["threadId"] as? String == "019a0000-0000-7000-8000-000000000003" }
        XCTAssertEqual(reviewReads.count, 1)
        let params = try XCTUnwrap(resumes.first?["params"] as? [String: Any])
        XCTAssertEqual(params["threadId"] as? String, active)
        XCTAssertEqual(params["excludeTurns"] as? Bool, true)
        XCTAssertEqual(Set(params.keys), ["threadId", "excludeTurns"])
        XCTAssertEqual(frames.last(where: { $0["kind"] as? String == "status" })?["connected"] as? Bool, true)
        var state = RuntimeEventState(sourceID: nil, sourceName: nil)
        for frame in frames { state.consume(frame) }
        XCTAssertEqual(state.activities.count, 1)
        XCTAssertEqual(state.activities.first?.phase, .completed)
        XCTAssertEqual(state.activities.first?.turnID, "test-turn")
        XCTAssertEqual(state.status.attachedThreads, 0, "The completed turn must release its subscription slot")
        XCTAssertTrue(frames.contains { frame in
            (frame["events"] as? [[String: Any]])?.contains { $0["method"] as? String == "stream/released" } == true
        })
    }
    func testRemoteEOFDeliversQueuedCompletionBeforeDisconnectAndRetainsUnreadCard() throws {
        let output = try runProbe(closeAfterTerminal: true)
        let frames = try output.split(separator: "\n").map { try JSONSerialization.jsonObject(with: Data($0.utf8)) as! [String: Any] }
        let terminal = try XCTUnwrap(frames.firstIndex { ($0["events"] as? [[String: Any]])?.contains { $0["method"] as? String == "turn/completed" } == true })
        let disconnected = try XCTUnwrap(frames.lastIndex { $0["kind"] as? String == "status" && $0["connected"] as? Bool == false })
        XCTAssertLessThan(terminal, disconnected)
        var state = RuntimeEventState(sourceID: "remote-ssh-discovered:fixture", sourceName: "SSH"), inbox = CompletionInbox()
        for frame in frames {
            state.consume(frame)
            inbox.observe(state.activities, at: Date(), retention: 1800)
            state.releasePublishedState()
        }
        XCTAssertEqual(inbox.unreadActivities.count, 1)
        XCTAssertEqual(inbox.unreadActivities.first?.phase, .completed)
        XCTAssertEqual(inbox.unreadActivities.first?.turnID, "test-turn")
        XCTAssertFalse(output.contains("PRIVATE"))
    }
    func testInvalidWebSocketAcceptCannotCreateLiveConnection() throws {
        let output = try runProbe(badAccept: true)
        let frames = try output.split(separator: "\n").map { try JSONSerialization.jsonObject(with: Data($0.utf8)) as! [String: Any] }
        XCTAssertFalse(frames.contains { $0["connected"] as? Bool == true })
        XCTAssertFalse(output.contains("thread/resume"))
    }
    func testMissingEndpointFallsBackWithoutStartingAnyServer() throws {
        let output = try runProbe(server: false)
        XCTAssertTrue(output.contains("\"sessions\":[]"))
        XCTAssertFalse(output.contains("\"connected\":true"))
        XCTAssertTrue(output.contains("\"watchingLogs\":false"))
    }

    private func scanTimes(connected: Bool) throws -> [Double] {
        let home = URL(fileURLWithPath: "/private/tmp/pacer-schedule-" + String(UUID().uuidString.prefix(8)))
        defer { try? FileManager.default.removeItem(at: home) }
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let simulation = #"""
        clock=[0.0];test_scans=[]
        time.monotonic=lambda:clock[0]
        def advance(delay):
            clock[0]+=delay
            if clock[0]>=130:raise KeyboardInterrupt()
        time.sleep=advance
        def ready(r,w,x,delay):advance(delay);return ([],[],[])
        select.select=ready
        class TestWS:
            def __init__(self,path):
                if not CONNECTED:raise OSError('unavailable')
                self.buf=b'';self.s=object();self.last_receive=1000000
            def send_frame(self,*args):pass
            def close(self):pass
        class TestSession:
            def __init__(self,ws):
                self.ready=True;self.pending={};self.attached=set();self.evidenced={'covered'};self.queue=[];self.notices=0;self.last_list=0;self.listing=False
            def request(self,*args):pass
            def request_loaded(self):self.last_list=time.monotonic();return True
        def test_snapshot(excluding=()):
            test_scans.append(clock[0]);assert excluding==({'covered'} if CONNECTED else ())
            return {'sessions':[]}
        WebSocket=TestWS;Session=TestSession;snapshot=test_snapshot
        """#.replacingOccurrences(of: "CONNECTED", with: connected ? "True" : "False")
        let main = String(RealtimeProbe.script.dropFirst(RealtimeProbe.library.count))
        let child = Process(), stdout = Pipe()
        child.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        child.arguments = ["-c", RealtimeProbe.library + "\n" + simulation + main + "\nprint(json.dumps({'testScans':test_scans}))", Data(home.path.utf8).base64EncodedString()]
        child.standardOutput = stdout; child.standardError = FileHandle.nullDevice
        try child.run()
        let bytes = stdout.fileHandleForReading.readDataToEndOfFile(); child.waitUntilExit()
        XCTAssertEqual(child.terminationStatus, 0)
        let frames = try String(decoding: bytes, as: UTF8.self).split(separator: "\n").map {
            try JSONSerialization.jsonObject(with: Data($0.utf8)) as! [String: Any]
        }
        return try XCTUnwrap(frames.last?["testScans"] as? [Double])
    }
    func testHealthySubscriptionDoesOnlyStartupAndTwoMinuteUncoveredDiscovery() throws {
        XCTAssertEqual(try scanTimes(connected: true), [0, 120])
    }
    func testUnavailableSubscriptionUsesMinuteFallbackRatherThanTwoSecondPolling() throws {
        XCTAssertEqual(try scanTimes(connected: false), [0, 60, 120])
    }

    func testBrokenFallbackScanKeepsHealthySocketAndHeartbeatsWithoutImmediateRetries() throws {
        let trace = try failureTimeline(scanFailure: true)
        XCTAssertEqual(trace["scans"] as? [Double], [0, 120])
        XCTAssertEqual(trace["connections"] as? Int, 1, "Log failures cannot disconnect a healthy subscription")
        let statuses = try XCTUnwrap(trace["statuses"] as? [[String: Any]])
        XCTAssertTrue(statuses.allSatisfy { $0["connected"] as? Bool == true })
        XCTAssertEqual(statuses.compactMap { $0["at"] as? Double }, stride(from: 0.0, through: 120.0, by: 15.0).map { $0 })
        XCTAssertLessThan(try XCTUnwrap(trace["loops"] as? Int), 200)
    }

    func testRecurringUnexpectedErrorsWaitAndContinueStatusHeartbeats() throws {
        let trace = try failureTimeline(scanFailure: false)
        XCTAssertEqual(trace["connections"] as? Int, 0)
        let statuses = try XCTUnwrap(trace["statuses"] as? [[String: Any]])
        XCTAssertTrue(statuses.allSatisfy { $0["connected"] as? Bool == false })
        XCTAssertEqual(statuses.compactMap { $0["at"] as? Double }, stride(from: 0.0, through: 120.0, by: 15.0).map { $0 })
        XCTAssertEqual(trace["loops"] as? Int, 130, "Persistent failures must wait instead of using a CPU-bound retry loop")
    }

    private func failureTimeline(scanFailure: Bool) throws -> [String: Any] {
        let home = URL(fileURLWithPath: "/private/tmp/pacer-helper-failure-" + String(UUID().uuidString.prefix(8)))
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let simulation = #"""
        clock=[0.0];test_scans=[];test_statuses=[];test_connections=[]
        def monotonic():
            # Fail the regression promptly rather than hanging on the old spin.
            if globals().get('loop_iterations',0)>1000:raise KeyboardInterrupt()
            return clock[0]
        time.monotonic=monotonic
        def advance(delay):
            clock[0]+=delay
            if clock[0]>=130:raise KeyboardInterrupt()
        time.sleep=advance
        def ready(r,w,x,delay):advance(delay);return ([],[],[])
        select.select=ready
        class TestIndex:
            def __init__(self,path):self.fd=-1;self.next_check=1e9
            def check(self,now):
                if not SCAN_FAILURE:raise AttributeError('synthetic persistent error')
                return False
            def close(self):pass
        class TestWS:
            def __init__(self,path):
                test_connections.append(clock[0]);self.buf=b'';self.s=object();self.last_receive=1e9
            def send_frame(self,*args):pass
            def close(self):pass
        class TestSession:
            def __init__(self,ws):
                self.ready=True;self.pending={};self.attached=set();self.evidenced=set();self.queue=[];self.notices=0;self.last_list=0;self.listing=False;self.rollout_paths={}
            def request_loaded(self):self.last_list=clock[0];return True
        def test_snapshot(excluding=()):
            test_scans.append(clock[0]);raise AttributeError('synthetic broken log')
        def test_emit(value):
            if isinstance(value,dict) and value.get('kind')=='status':test_statuses.append({'at':clock[0],'connected':value['connected']})
        WebSocket=TestWS;Session=TestSession;RuntimeIndexChanges=TestIndex;snapshot=test_snapshot;emit=test_emit
        """#.replacingOccurrences(of: "SCAN_FAILURE", with: scanFailure ? "True" : "False")
        let main = String(RealtimeProbe.script.dropFirst(RealtimeProbe.library.count))
        let child = Process(), stdout = Pipe(), stderr = Pipe()
        child.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        child.arguments = ["-c", RealtimeProbe.library + "\n" + simulation + main + "\nprint(json.dumps({'scans':test_scans,'statuses':test_statuses,'connections':len(test_connections),'loops':loop_iterations}))", Data(home.path.utf8).base64EncodedString(), "ssh-lifetime"]
        child.standardOutput = stdout; child.standardError = stderr
        try child.run()
        let bytes = stdout.fileHandleForReading.readDataToEndOfFile(); child.waitUntilExit()
        XCTAssertEqual(child.terminationStatus, 0, String(decoding: stderr.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
    }

    /// A test-owned server sends real masked/unmasked and fragmented WS frames.
    /// It never connects to Codex, runs a model, or touches a user's thread.
    private static let fixture = #"""
    import pathlib,base64,sys,socket,struct,json,hashlib,threading,time,os,atexit
    fixture_home=pathlib.Path(base64.b64decode(sys.argv[1]).decode())
    fixture_dir=fixture_home/'app-server-control';fixture_dir.mkdir(mode=0o700)
    fixture_socket=fixture_dir/'app-server-control.sock'
    fixture_server=socket.socket(socket.AF_UNIX,socket.SOCK_STREAM);fixture_server.bind(str(fixture_socket));os.chmod(fixture_socket,0o600);fixture_server.listen(1)
    fixture_requests=[]
    fixture_active='019a0000-0000-7000-8000-000000000001'
    fixture_idle='019a0000-0000-7000-8000-000000000002'
    fixture_review='019a0000-0000-7000-8000-000000000003'
    def fixture_worker():
        client,_=fixture_server.accept();client.settimeout(4);buffer=b''
        def readn(n):
            nonlocal buffer
            while len(buffer)<n:
                d=client.recv(65536)
                if not d:raise EOFError()
                buffer+=d
            out,buffer=buffer[:n],buffer[n:];return out
        def frame(op,data,final=True):
            n=len(data);head=bytes([(128 if final else 0)|op,n]) if n<126 else bytes([(128 if final else 0)|op,126])+struct.pack('!H',n)
            client.sendall(head+data)
        def send(v,fragment=False):
            d=json.dumps(v).encode()
            if fragment:frame(1,d[:30],False);frame(0,d[30:])
            else:frame(1,d)
        try:
            while b'\r\n\r\n' not in buffer:buffer+=client.recv(4096)
            header,buffer=buffer.split(b'\r\n\r\n',1)
            key=next(line.split(b':',1)[1].strip() for line in header.split(b'\r\n') if line.lower().startswith(b'sec-websocket-key:'))
            accept=b'invalid' if BAD_ACCEPT else base64.b64encode(hashlib.sha1(key+b'258EAFA5-E914-47DA-95CA-C5AB0DC85B11').digest())
            client.sendall(b'HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: '+accept+b'\r\n\r\n')
            while True:
                h=readn(2);op=h[0]&15;n=h[1]&127
                if n==126:n=struct.unpack('!H',readn(2))[0]
                elif n==127:n=struct.unpack('!Q',readn(8))[0]
                mask=readn(4) if h[1]&128 else None;d=readn(n)
                if mask:d=bytes(c^mask[i%4] for i,c in enumerate(d))
                if op==9:frame(10,d);continue
                if op!=1:continue
                v=json.loads(d)
                if 'id' not in v:continue
                fixture_requests.append(v);method=v['method'];params=v.get('params') or {}
                if method=='initialize':result={'userAgent':'fixture'}
                elif method=='thread/loaded/list':result={'data':[fixture_active,fixture_idle,fixture_review]}
                elif method in ('thread/read','thread/resume'):
                    tid=params['threadId'];result={'thread':{'id':tid,'status':{'type':'idle' if tid==fixture_idle else 'active'},'threadSource':'guardian_review' if tid==fixture_review else 'user','model':'gpt-test','name':'Running sample','cwd':'/fixture','preview':'PRIVATE prompt','turns':[]}}
                else:raise ValueError('unexpected request')
                send({'id':v['id'],'result':result})
                if method=='thread/resume':
                    common={'threadId':fixture_active,'turnId':'test-turn'}
                    send({'method':'item/agentMessage/delta','params':{'threadId':fixture_review,'turnId':'review','itemId':'review-item','delta':'PRIVATE auto review'}})
                    send({'method':'turn/started','params':{'threadId':fixture_active,'turn':{'id':'test-turn','status':'inProgress','items':[{'text':'PRIVATE input'}]}}})
                    send({'method':'item/started','params':dict(common,item={'type':'commandExecution','id':'tool','command':'PRIVATE command'},startedAtMs=time.time()*1000)})
                    send({'method':'item/agentMessage/delta','params':dict(common,itemId='reply',delta='PRIVATE reply')},True)
                    send({'method':'item/completed','params':dict(common,item={'type':'commandExecution','id':'tool','aggregatedOutput':'PRIVATE tool output'},completedAtMs=time.time()*1000)})
                    send({'method':'thread/tokenUsage/updated','params':dict(common,tokenUsage={'total':{'outputTokens':100,'inputTokens':12345},'last':{'outputTokens':100}})})
                    send({'method':'turn/completed','params':{'threadId':fixture_active,'turn':{'id':'test-turn','status':'completed','items':[{'text':'PRIVATE final'}]}}})
        except (EOFError,ConnectionResetError,BrokenPipeError):pass
        finally:client.close();fixture_server.close()
    fixture_thread=threading.Thread(target=fixture_worker,daemon=True);fixture_thread.start()
    def fixture_finish():
        fixture_thread.join(timeout=1);print(json.dumps({'testRequests':fixture_requests}),flush=True)
    atexit.register(fixture_finish)
    """#
}
