@testable import PacerEngineSupport
import Foundation
import XCTest
@testable import PacerCore
@testable import WindowsInstallerSupport

final class WindowsTelemetryTests: XCTestCase {
    private final class Frames: @unchecked Sendable {
        private let lock = NSLock()
        private var bytes: [Data] = []
        func append(_ data: Data) { lock.lock(); bytes.append(data); lock.unlock() }
        var all: [Data] { lock.lock(); defer { lock.unlock() }; return bytes }
    }
    private var python: URL { get throws { URL(fileURLWithPath: try XCTUnwrap(ProcessInfo.processInfo.environment["PACER_CLAUDE_PYTHON_PACKAGE"])).appendingPathComponent("python.exe") } }
    func testLoopbackFragmentedIdentityGzipPortConflictAndImmediateRebind() async throws {
        let frames = Frames(), receiver = ClaudeActivityTelemetry(port: 0) { frames.append($0) }
        try receiver.start(); defer { receiver.stop() }
        XCTAssertGreaterThan(receiver.listeningPort, 0)
        let conflict = ClaudeActivityTelemetry(port: receiver.listeningPort) { _ in XCTFail("Conflicting listener cannot own traffic") }
        XCTAssertThrowsError(try conflict.start())
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("pacer-telemetry-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("request.json")
        let attributes: [[String: Any]] = [
            ["key": "session.id", "value": ["stringValue": "fixture-session"]],
            ["key": "prompt.id", "value": ["stringValue": "fixture-prompt"]],
            ["key": "request_id", "value": ["stringValue": "fixture-request"]],
            ["key": "output_tokens", "value": ["intValue": "160"]],
            ["key": "duration_ms", "value": ["doubleValue": 2000]],
            ["key": "user_prompt", "value": ["stringValue": "PRIVATE_SYNTHETIC"]]
        ]
        let span: [String: Any] = ["name": "claude_code.llm_request", "startTimeUnixNano": "1790000000000000000",
            "endTimeUnixNano": "1790000002000000000", "attributes": attributes]
        try JSONSerialization.data(withJSONObject: ["resourceSpans": [["scopeSpans": [["spans": [span]]]]]]).write(to: file)
        let script = #"""
        import gzip,json,socket,sys,os,shutil
        os.environ['PATH']=os.path.join(os.environ['SystemRoot'],'System32')
        assert all(shutil.which(name) is None for name in ('python','python3','py'))
        data=open(sys.argv[2],'rb').read();statuses=[]
        for body,encoding in [(data,'identity'),(gzip.compress(data,mtime=0),'gzip')]:
            with socket.create_connection(('127.0.0.1',int(sys.argv[1])),2) as client:
                client.settimeout(2)
                wire=('POST /v1/traces HTTP/1.1\r\nContent-Type: application/json\r\nContent-Encoding: '+encoding+'\r\nContent-Length: '+str(len(body))+'\r\n\r\n').encode()+body
                for offset in range(0,len(wire),17):client.sendall(wire[offset:offset+17])
                reply=b''
                while True:
                    part=client.recv(4096)
                    if not part:break
                    reply+=part
                statuses.append(int(reply.split(b' ')[1]))
        print(json.dumps(statuses))
        """#
        let result = await WindowsSubprocess.capture(executable: try python,
            arguments: ["-S", "-c", script, String(receiver.listeningPort), WindowsCodexExecutableDiscovery.path(file)], timeout: 5, limit: 4096)
        let statuses = try JSONDecoder().decode([Int].self, from: XCTUnwrap(result))
        XCTAssertEqual(statuses, [200, 200]); XCTAssertEqual(frames.all.count, 2)
        XCTAssertFalse(frames.all.contains { String(decoding: $0, as: UTF8.self).contains("PRIVATE") })
        XCTAssertEqual(receiver.counters.httpRequests, 2); XCTAssertEqual(receiver.counters.projectedRequests, 2)
        let port = receiver.listeningPort
        receiver.stop()
        let replacement = ClaudeActivityTelemetry(port: port) { _ in }
        try replacement.start(); XCTAssertEqual(replacement.listeningPort, port); replacement.stop()
    }
    func testTelemetryAcrossDirectShortAndFallbackLaunchesInBothWindowsShells() async throws {
        let frames = Frames(), receiver = ClaudeActivityTelemetry(port: 0) { frames.append($0) }
        try receiver.start(); defer { receiver.stop() }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("pacer-shell-telemetry-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let python = try python
        // Claude emits OTLP itself; a synthetic emitter stands in for that
        // process. The receiver, HTTP decoding and privacy projection are real.
        let sender = #"""
        import http.client,json,os,sys
        from pathlib import Path
        from urllib.parse import urlsplit
        home=Path(sys.argv[2]); settings=json.loads((home/'settings.json').read_bytes())
        os.environ.update(settings['env'])
        assert os.environ['OTEL_TRACES_EXPORTER']=='otlp'
        assert os.environ['OTEL_EXPORTER_OTLP_TRACES_PROTOCOL']=='http/json'
        endpoint=urlsplit(os.environ['OTEL_EXPORTER_OTLP_TRACES_ENDPOINT'])
        body=(home/'request.json').read_bytes()
        connection=http.client.HTTPConnection(endpoint.hostname,endpoint.port,timeout=2)
        connection.request('POST',endpoint.path,body,{'Content-Type':'application/json'})
        response=connection.getresponse();response.read();print(response.status)
        connection.close()
        """#
        let attributes: [[String: Any]] = [
            ["key": "session.id", "value": ["stringValue": "synthetic-shell-session"]],
            ["key": "prompt.id", "value": ["stringValue": "synthetic-shell-prompt"]],
            ["key": "request_id", "value": ["stringValue": "synthetic-shell-request"]],
            ["key": "output_tokens", "value": ["intValue": "160"]],
            ["key": "duration_ms", "value": ["doubleValue": 2000]],
            ["key": "user_prompt", "value": ["stringValue": "PRIVATE_SYNTHETIC_SHELL"]]
        ]
        let span: [String: Any] = ["name": "claude_code.llm_request", "startTimeUnixNano": "1790000000000000000",
            "endTimeUnixNano": "1790000002000000000", "attributes": attributes]
        let body = try JSONSerialization.data(withJSONObject: ["resourceSpans": [["scopeSpans": [["spans": [span]]]]]])
        func home(_ name: String) throws -> URL {
            let home = root.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
            let installer = try WindowsClaudeHookCommands.installer(home: home, root: python.deletingLastPathComponent().deletingLastPathComponent(),
                storage: WindowsClaudeHookStorage(), script: Data(sender.utf8))
            XCTAssertTrue(try installer.install(home: home).telemetryConfigured)
            let settingsURL = home.appendingPathComponent("settings.json")
            var settings = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: settingsURL)) as? [String: Any])
            var env = try XCTUnwrap(settings["env"] as? [String: String])
            XCTAssertEqual(env["OTEL_EXPORTER_OTLP_TRACES_ENDPOINT"], "http://127.0.0.1:4319/v1/traces")
            // An ephemeral test port avoids claiming another session's 4319.
            env["OTEL_EXPORTER_OTLP_TRACES_ENDPOINT"] = "http://127.0.0.1:\(receiver.listeningPort)/v1/traces"
            settings["env"] = env
            try JSONSerialization.data(withJSONObject: settings).write(to: settingsURL)
            try body.write(to: home.appendingPathComponent("request.json"))
            return home
        }
        let spaced = try home("Claude space 用户"), plain = try home("ClaudeDirect")
        let values = WindowsClaudeHookCommands.arguments(python: python, home: spaced, kind: .hook)
        var routes = [["mode": "powershell", "command": WindowsClaudeHookCommands.fallback(values)]]
        let selection = WindowsClaudeHookCommands.selection(values)
        if selection.mode == "shortPath" { routes.append(["mode": "shortPath", "command": selection.command]) }
        let safePython = WindowsClaudeHookCommands.directSafe(python.path) ? python.path : WindowsClaudeHookCommands.shortPath(python)
        let safeHome = WindowsClaudeHookCommands.directSafe(plain.path) ? plain.path : WindowsClaudeHookCommands.shortPath(plain)
        if let safePython, let safeHome {
            let direct = WindowsClaudeHookCommands.selection(WindowsClaudeHookCommands.arguments(python: URL(fileURLWithPath: safePython), home: URL(fileURLWithPath: safeHome), kind: .hook))
            XCTAssertEqual(direct.mode, "direct"); routes.append(["mode": "direct", "command": direct.command])
        }
        let driver = #"""
        import json,os,subprocess,sys,time
        from pathlib import Path
        routes=json.loads(sys.argv[1]);env=dict(os.environ)
        for key in ('MSYS_NO_PATHCONV','MSYS2_ARG_CONV_EXCL','MSYS2_ENV_CONV_EXCL','BASH_ENV','ENV'):env.pop(key,None)
        system=Path(os.environ['SystemRoot'])/'System32'
        env['PATH']=str(system)+os.pathsep+str(system/'WindowsPowerShell/v1.0')
        executors={'bash':[str(Path(os.environ['ProgramFiles'])/'Git/bin/bash.exe'),'--noprofile','--norc','-c'],
            'powershell':[str(system/'WindowsPowerShell/v1.0/powershell.exe'),'-NoProfile','-NonInteractive','-Command']}
        results=[]
        for route in routes:
            for shell,prefix in executors.items():
                started=time.monotonic()
                result=subprocess.run(prefix+[route['command']],env=env,input=b'{}',capture_output=True,timeout=5,
                    creationflags=subprocess.CREATE_NO_WINDOW)
                results.append({'mode':route['mode'],'executor':shell,'status':200 if result.stdout.strip()==b'200' else 0,
                    'exit':result.returncode,'errorBytes':len(result.stderr),'milliseconds':round((time.monotonic()-started)*1000)})
        print(json.dumps(results))
        """#
        let arguments = String(decoding: try JSONSerialization.data(withJSONObject: routes), as: UTF8.self)
        let result = await WindowsSubprocess.capture(executable: python, arguments: ["-S", "-c", driver, arguments], timeout: 30, limit: 16384)
        let results = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(result)) as? [[String: Any]])
        XCTAssertEqual(results.count, routes.count * 2)
        for item in results {
            XCTAssertEqual(item["status"] as? Int, 200); XCTAssertEqual(item["exit"] as? Int, 0); XCTAssertEqual(item["errorBytes"] as? Int, 0)
            print("Telemetry launch " + String(decoding: try JSONSerialization.data(withJSONObject: item, options: [.sortedKeys]), as: UTF8.self))
        }
        XCTAssertEqual(frames.all.count, routes.count * 2)
        XCTAssertEqual(receiver.counters.projectedRequests, routes.count * 2)
        XCTAssertFalse(frames.all.contains { String(decoding: $0, as: UTF8.self).contains("PRIVATE") })
    }
    func testStopReleasesEightBlockedSocketsAndRejectsNinthClient() async throws {
        let receiver = ClaudeActivityTelemetry(port: 0) { _ in XCTFail("A partial request cannot project activity") }
        try receiver.start(); defer { receiver.stop() }
        let ready = expectation(description: "eight partial clients held and ninth rejected")
        let released = expectation(description: "all eight readers woke after stop")
        final class Lines: @unchecked Sendable {
            let lock = NSLock(); var pending = Data()
            func receive(_ data: Data, ready: XCTestExpectation, released: XCTestExpectation) {
                lock.lock(); defer { lock.unlock() }; pending.append(data)
                while let end = pending.firstIndex(of: 10) {
                    let line = String(decoding: pending.prefix(upTo: end), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines); pending.removeSubrange(...end)
                    if line == "ready" { ready.fulfill() }
                    else if line == "released:8" { released.fulfill() }
                    else { XCTFail("Unexpected synthetic socket fixture result") }
                }
            }
        }
        let script = #"""
        import socket,sys
        clients=[]
        for index in range(9):
            client=socket.create_connection(('127.0.0.1',int(sys.argv[1])),2);client.settimeout(2)
            if index<8:client.sendall(b'POST /v1/traces HTTP/1.1\r\n')
            clients.append(client)
        try:assert clients[8].recv(1)==b''
        except ConnectionResetError:pass
        print('ready',flush=True);sys.stdin.readline()
        count=0
        for client in clients[:8]:
            try:
                if client.recv(1)==b'':count+=1
            except ConnectionResetError:count+=1
            client.close()
        clients[8].close();print('released:'+str(count),flush=True)
        """#
        let lines = Lines()
        let child = try WindowsHelperProcessLauncher().launch(.init(executable: try python,
            arguments: ["-S", "-u", "-c", script, String(receiver.listeningPort)], environment: ProcessInfo.processInfo.environment),
            output: { lines.receive($0, ready: ready, released: released) }, ended: {})
        defer { child.close() }
        await fulfillment(of: [ready], timeout: 4)
        XCTAssertEqual(child.errorMessage(), "", "The synthetic socket fixture must reach its ready boundary")
        let started = ProcessInfo.processInfo.systemUptime; receiver.stop()
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - started, ShutdownDeadline.maximumWait)
        try child.write(Data("stopped\n".utf8))
        await fulfillment(of: [released], timeout: 3)
        child.close()
        let exited = await child.waitForExit()
        XCTAssertTrue(exited)
    }
}
