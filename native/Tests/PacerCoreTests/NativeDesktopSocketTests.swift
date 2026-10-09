import XCTest
@testable import PacerCore

final class NativeDesktopSocketTests: XCTestCase {
    private final class Frames: @unchecked Sendable {
        let lock = NSLock()
        var bytes: [Data] = []
        var sawRequest = false, sawResolution = false, sawCompletion = false
        func append(_ data: Data) -> (Bool, Bool, Bool) {
            lock.lock(); defer { lock.unlock() }; bytes.append(data)
            let value = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
            var requested = false, resolved = false, completed = false
            if value["kind"] as? String == "attention", let rows = value["requests"] as? [[String: Any]] {
                if !rows.isEmpty && !sawRequest { sawRequest = true; requested = true }
                if rows.isEmpty && sawRequest && !sawResolution { sawResolution = true; resolved = true }
            }
            if let events = value["events"] as? [[String: Any]], events.contains(where: { $0["method"] as? String == "turn/completed" }), !sawCompletion {
                sawCompletion = true; completed = true
            }
            return (requested, resolved, completed)
        }
        func all() -> [Data] { lock.lock(); defer { lock.unlock() }; return bytes }
    }
    func testOwnedNativeSocketDeliversRequestsCountsCompletionAndStopsWithoutPythonCollector() async throws {
        let home = URL(fileURLWithPath: "/private/tmp/pacer-native-" + String(UUID().uuidString.prefix(8)))
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let child = Process(), stdout = Pipe(), stderr = Pipe()
        let childEnded = expectation(description: "socket fixture exited")
        child.terminationHandler = { _ in childEnded.fulfill() }
        child.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        child.arguments = ["-u", "-c", Self.server, home.path]
        child.standardOutput = stdout; child.standardError = stderr
        try child.run()
        defer { if child.isRunning { child.terminate() } }
        let socket = home.appendingPathComponent("ipc/ipc.sock")
        for _ in 0..<200 where !FileManager.default.fileExists(atPath: socket.path) { try await Task.sleep(nanoseconds: 5_000_000) }
        XCTAssertTrue(FileManager.default.fileExists(atPath: socket.path))
        let requested = expectation(description: "async request received"), resolved = expectation(description: "request explicitly resolved")
        let completed = expectation(description: "turn ended"), closed = expectation(description: "owned socket closed")
        let frames = Frames()
        let collector = NativeDesktopCollector(home: home, hosts: ["local"], onFrame: { data in
            let flags = frames.append(data)
            if flags.0 { requested.fulfill() }; if flags.1 { resolved.fulfill() }; if flags.2 { completed.fulfill() }
        }, onClosed: { closed.fulfill() })
        try collector.start()
        await fulfillment(of: [requested, resolved, completed], timeout: 5)
        collector.stop()
        await fulfillment(of: [closed], timeout: 2)
        await fulfillment(of: [childEnded], timeout: 5)
        guard !child.isRunning else { XCTFail("Socket fixture did not exit"); return }
        XCTAssertEqual(child.terminationStatus, 0, String(decoding: stderr.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self))
        let captured = frames.all()
        XCTAssertFalse(captured.contains { String(decoding: $0, as: UTF8.self).contains("PRIVATE") })
        let values = try captured.map { try JSONSerialization.jsonObject(with: $0) as! [String: Any] }
        let events = values.compactMap { $0["events"] as? [[String: Any]] }.flatMap { $0 }
        XCTAssertTrue(events.contains { $0["outputTokens"] as? Int == 25 })
        XCTAssertTrue(events.contains { $0["method"] as? String == "item/completed" })
        let report = try JSONSerialization.jsonObject(with: stdout.fileHandleForReading.readDataToEndOfFile()) as! [String: Any]
        XCTAssertTrue(report["onlyMonitoringRequests"] as? Bool == true)
    }
    func testExpandingFlushesPendingNativeEventsWithoutSocketTrafficOrReconnect() async throws {
        let home = URL(fileURLWithPath: "/private/tmp/pacer-native-cadence-" + String(UUID().uuidString.prefix(8)))
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let child = Process(), stderr = Pipe()
        let marker = try XCTUnwrap(Self.server.range(of: "time.sleep(.3)"))
        let script = String(Self.server[..<marker.lowerBound]) + #"""
        time.sleep(.3)
        change({'type':'patches','baseRevision':0,'revision':1,'patches':[{'op':'replace','path':['latestTokenUsageInfo','total','outputTokens'],'value':12}]})
        try:
            while True:read()
        except (EOFError,ConnectionResetError):pass
        finally:connection.close();server.close()
        """#
        child.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        child.arguments = ["-u", "-c", script, home.path]
        child.standardOutput = FileHandle.nullDevice; child.standardError = stderr
        try child.run(); defer { if child.isRunning { child.terminate() } }
        let socket = home.appendingPathComponent("ipc/ipc.sock")
        for _ in 0..<200 where !FileManager.default.fileExists(atPath: socket.path) { try await Task.sleep(nanoseconds: 5_000_000) }
        let initial = expectation(description: "initial count"), expanded = expectation(description: "pending count on expansion")
        let closed = expectation(description: "owned collector stopped")
        let frames = Frames()
        let collector = NativeDesktopCollector(home: home, hosts: ["local"], batchInterval: 5, onFrame: { data in
            _ = frames.append(data)
            let value = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            let events = value?["events"] as? [[String: Any]] ?? []
            if events.contains(where: { $0["outputTokens"] as? Int == 10 }) { initial.fulfill() }
            if events.contains(where: { $0["outputTokens"] as? Int == 12 }) { expanded.fulfill() }
        }, onClosed: { closed.fulfill() })
        try collector.start()
        await fulfillment(of: [initial], timeout: 2)
        try await Task.sleep(nanoseconds: 1_300_000_000)
        let pending = try frames.all().map { try JSONSerialization.jsonObject(with: $0) as! [String: Any] }
        XCTAssertFalse(pending.contains { ($0["events"] as? [[String: Any]])?.contains { $0["outputTokens"] as? Int == 12 } == true })
        collector.setBatchInterval(1, flushPending: true)
        await fulfillment(of: [expanded], timeout: 1)
        collector.stop(); await fulfillment(of: [closed], timeout: 2)
        child.waitUntilExit()
        XCTAssertEqual(child.terminationStatus, 0, String(decoding: stderr.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self))
    }

    func testMonitorDeliversFinalEndingBeforeSocketEOF() async throws {
        for routing in [false, true] {
            for atomic in routing ? [true, false] : [true] {
                try await verifyMonitorEnding(host: "local", atomic: atomic, routing: routing)
            }
        }
    }
    func testRemoteControlMonitorDiscoversRoutingAndDeliversCompletionBeforeEOF() async throws {
        for atomic in [true, false] {
            try await verifyMonitorEnding(host: "remote-control:env_fixture", atomic: atomic, routing: true)
        }
    }
    private func verifyMonitorEnding(host: String, atomic: Bool, routing: Bool) async throws {
        final class Ending: @unchecked Sendable {
            let lock = NSLock()
            var delivered = false
            var inbox = CompletionInbox()
            func first(_ activities: [SessionActivity]) -> Bool {
                lock.lock(); defer { lock.unlock() }
                inbox.observe(activities, at: Date(), retention: 1800)
                guard !delivered, activities.contains(where: { $0.phase == .completed }) else { return false }
                delivered = true; return true
            }
            func unreadCount() -> Int { lock.lock(); defer { lock.unlock() }; return inbox.unreadActivities.count }
        }
        let home = URL(fileURLWithPath: "/private/tmp/pacer-native-eof-" + String(UUID().uuidString.prefix(8)))
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        if routing {
            var config: [String: Any] = ["codex-managed-remote-connections": [
                ["source": "discovered", "hostId": host, "alias": "synthetic", "displayName": "Synthetic SSH"]
            ], "remote-connection-auto-connect-by-host-id": [host: true]]
            if host.hasPrefix("remote-control:") { config["remote-projects"] = [["hostId": host]] }
            try JSONSerialization.data(withJSONObject: config).write(to: home.appendingPathComponent(".codex-global-state.json"))
        }
        let child = Process(), stderr = Pipe()
        let childEnded = expectation(description: "EOF fixture exited")
        child.terminationHandler = { _ in childEnded.fulfill() }
        child.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        let end = try XCTUnwrap(Self.server.range(of: "try:\n    while True:read()"))
        var script = String(Self.server[..<end.lowerBound])
        // End inside the active batching interval, rather than keeping the
        // connection open until an ordinary timer flush can save the ending.
        script = script.replacingOccurrences(of: "time.sleep(.3)\nchange({'type':'patches','baseRevision':1", with: "time.sleep(.01)\nchange({'type':'patches','baseRevision':1")
        script = script.replacingOccurrences(of: "'hostId':'local'", with: "'hostId':'\(host)'")
        if host.hasPrefix("remote-control:") {
            script = script.replacingOccurrences(of: "'conversationState':{'threadRuntimeStatus'", with: "'conversationState':{'resumeState':'resumed','threadRuntimeStatus'")
        }
        if routing {
            // This is the real missed-discovery path: the owner sends no
            // following announcement. A brand-new SSH task only adds routing
            // metadata; Pacer must wake and subscribe without the 60s poll.
            let announcement = "send({'type':'broadcast','method':'thread-stream-following-status-requested','version':1,'params':{'hostId':'\(host)','conversationId':tid}})"
            let write = atomic ? "temporary=root/'routing.tmp';temporary.write_text(json.dumps(config));os.replace(temporary,index)" : "index.write_text(json.dumps(config))"
            let routing = """
            time.sleep(.2)
            index=root/'.codex-global-state.json'
            config=json.loads(index.read_text());config['thread-project-membership-host-ids']={tid:'\(host)'}
            \(write)
            """
            XCTAssertTrue(script.contains(announcement))
            script = script.replacingOccurrences(of: announcement, with: routing)
            if atomic {
                // The index can precede ownership. Drop the first follow and
                // stay silent: a timer must retry even without another packet.
                script = script.replacingOccurrences(of: "follow=read();assert follow['params']['following'] is True",
                    with: "follow=read();assert follow['params']['following'] is True\nfollow=read();assert follow['params']['following'] is True")
            }
        }
        script += "\nconnection.close();server.close()\n"
        child.arguments = ["-u", "-c", script, home.path]
        child.standardOutput = FileHandle.nullDevice; child.standardError = stderr
        try child.run()
        defer { if child.isRunning { child.terminate() } }
        let socket = home.appendingPathComponent("ipc/ipc.sock")
        for _ in 0..<200 where !FileManager.default.fileExists(atPath: socket.path) { try await Task.sleep(nanoseconds: 5_000_000) }
        let ending = Ending(), delivered = expectation(description: "ending delivered before disconnect")
        let monitor = RealtimeActivityMonitor()
        await monitor.start(home: home, includeSSH: host != "local", useSSHFallback: false) { activities, _, _ in
            XCTAssertTrue(activities.allSatisfy { ($0.sourceHostID ?? "local") == host })
            if ending.first(activities) { delivered.fulfill() }
        }
        await fulfillment(of: [delivered], timeout: 5)
        await monitor.shutdown()
        XCTAssertEqual(ending.unreadCount(), 1, "The reminder must outlive runtime release, trailing patches and EOF")
        await fulfillment(of: [childEnded], timeout: 5)
        guard !child.isRunning else { XCTFail("EOF fixture did not exit"); return }
        XCTAssertEqual(child.terminationStatus, 0, String(decoding: stderr.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self))
    }
    private static let server = #"""
    import socket,struct,json,pathlib,sys,os,time
    root=pathlib.Path(sys.argv[1]);directory=root/'ipc';directory.mkdir(mode=0o700)
    server=socket.socket(socket.AF_UNIX,socket.SOCK_STREAM);server.bind(str(directory/'ipc.sock'));os.chmod(directory/'ipc.sock',0o600);server.listen(1)
    connection,_=server.accept();connection.settimeout(5);messages=[]
    def readn(n):
        data=b''
        while len(data)<n:
            part=connection.recv(n-len(data))
            if not part:raise EOFError()
            data+=part
        return data
    def read():
        v=json.loads(readn(struct.unpack('<I',readn(4))[0]));messages.append(v);return v
    def send(v):
        data=json.dumps(v,separators=(',',':')).encode();connection.sendall(struct.pack('<I',len(data))+data)
    tid='019a0000-0000-7000-8000-000000000001';owner='019a0000-0000-7000-8000-000000000020';client='019a0000-0000-7000-8000-000000000010'
    initialize=read();send({'type':'response','method':'initialize','resultType':'success','result':{'clientId':client}})
    send({'type':'broadcast','method':'thread-stream-following-status-requested','version':1,'params':{'hostId':'local','conversationId':tid}})
    follow=read();assert follow['params']['following'] is True
    def change(value):send({'type':'broadcast','method':'thread-stream-state-changed','version':11,'sourceClientId':owner,'params':{'hostId':'local','conversationId':tid,'change':value}})
    change({'type':'snapshot','revision':0,'conversationState':{'threadRuntimeStatus':{'type':'active','activeFlags':[]},'requests':[],'latestTokenUsageInfo':{'total':{'outputTokens':10}},'turns':[{'turnId':'turn','status':'inProgress','items':[{'id':'tool','type':'commandExecution','status':'inProgress','command':'PRIVATE'}]}]}})
    time.sleep(.3)
    request={'id':'async','method':'item/tool/requestUserInput','params':{'isBlocking':False,'questions':[{'question':'PRIVATE'}]}}
    change({'type':'patches','baseRevision':0,'revision':1,'patches':[{'op':'replace','path':['requests'],'value':[request]},{'op':'replace','path':['latestTokenUsageInfo','total','outputTokens'],'value':25},{'op':'replace','path':['turns',0,'items',0,'status'],'value':'completed'}]})
    time.sleep(.3)
    change({'type':'patches','baseRevision':1,'revision':2,'patches':[{'op':'replace','path':['requests'],'value':[]},{'op':'replace','path':['turns',0,'status'],'value':'completed'}]})
    change({'type':'patches','baseRevision':2,'revision':3,'patches':[{'op':'replace','path':['threadRuntimeStatus'],'value':{'type':'idle','activeFlags':[]}},{'op':'replace','path':['latestTokenUsageInfo','total','outputTokens'],'value':26}]})
    try:
        while True:read()
    except (EOFError,ConnectionResetError):pass
    print(json.dumps({'onlyMonitoringRequests':all(v.get('method') in ('initialize','thread-stream-following-changed') for v in messages)}))
    connection.close();server.close()
    """#
}
