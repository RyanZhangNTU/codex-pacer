import Foundation
import XCTest
@testable import PacerCore
@testable import PacerEngineSupport

private actor SSHFrames {
    var bytes = Data()
    var snapshots: [RealtimeActivitySnapshot] = []
    func append(_ data: Data) { bytes.append(data) }
    func append(_ snapshot: RealtimeActivitySnapshot) { snapshots.append(snapshot) }
    func text() -> String { String(decoding: bytes, as: UTF8.self) }
    func count() -> Int { snapshots.count }
    func latest() -> RealtimeActivitySnapshot? { snapshots.last }
}
private actor SSHRuntimeFrames {
    private var pending = Data(), state = RuntimeEventState(sourceID: "remote-ssh-discovered:alias-a", sourceName: "Synthetic")
    var rows: [SessionActivity] = []
    func receive(_ bytes: Data) {
        pending += bytes
        while let end = pending.firstIndex(of: 10) {
            let line = pending.prefix(upTo: end); pending.removeSubrange(...end)
            if let frame = try? JSONSerialization.jsonObject(with: line) as? [String: Any] {
                state.consume(frame); if let row = state.activities.first { rows.append(row) }
            }
        }
    }
    func count() -> Int { rows.count }
    func last() -> SessionActivity? { rows.last }
}
private struct SSHUnusedDesktop: DesktopActivityChannel {
    func start() {}; func setHosts(_ hosts: Set<String>) {}; func discover(_ threads: [String]) {}
    func setBatchInterval(_ seconds: TimeInterval, flushPending: Bool) {}; func stop() {}
}
private final class SSHEngineCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var data: [Data] = []
    func append(_ bytes: Data) { lock.lock(); data.append(bytes); lock.unlock() }
    func snapshot() -> EngineSnapshot? { lock.lock(); defer { lock.unlock() }; return data.reversed().compactMap { try? JSONDecoder().decode(EngineSnapshot.self, from: $0) }.first }
}

final class WindowsSSHTests: XCTestCase {
    private let thread = "019a0000-0000-7000-8000-000000000001"
    private func fixture() throws -> (URL, URL, [String: String]) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("SSH 中文 fixture " + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let executable = URL(fileURLWithPath: try XCTUnwrap(ProcessInfo.processInfo.environment["PACER_SSH_FIXTURE"]))
        var environment = ProcessInfo.processInfo.environment
        environment["PACER_SSH_FIXTURE_ROOT"] = WindowsCodexExecutableDiscovery.path(root)
        return (root, executable, environment)
    }
    private func write(_ value: [String: Any], to file: URL) throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: value).write(to: file)
    }
    private func target() -> RemoteActivityTarget { .init(id: "remote-ssh-discovered:alias-a", name: "Synthetic", alias: "alias-a", home: "~/.codex") }
    private func wait(_ condition: @escaping () async -> Bool) async throws {
        if try await TestWait.until(condition) { return }
        XCTFail("Synthetic SSH boundary was not reached"); throw CodexClientError.invalidResponse
    }
    func testOpenSSHLookupAndWindowsPathsKeepTheCoreValidationBoundary() throws {
        let builtin = URL(fileURLWithPath: "C:/Windows/System32/OpenSSH/ssh.exe")
        let fallback = URL(fileURLWithPath: "D:/工具/ssh.exe")
        let env = ["sYsTeMrOoT": "C:/Windows", "pAtH": "relative;\"D:/工具\""]
        XCTAssertEqual(WindowsExecutables.findSSH(environment: env, exists: { $0 == builtin || $0 == fallback }), builtin)
        XCTAssertEqual(WindowsExecutables.findSSH(environment: env, exists: { $0 == fallback }), fallback)
        XCTAssertNil(WindowsExecutables.findSSH(environment: env, exists: { _ in false }))
        let locations = WindowsSSHServices.desktopLocations(environment: ["APPDATA": "C:/fixture/Roaming", "LOCALAPPDATA": "C:/fixture/Local"])
        XCTAssertEqual(locations.count, 3); XCTAssertTrue(locations.allSatisfy { $0.lastPathComponent == "ssh_configs.json" })
        XCTAssertTrue(locations[1].path.contains("LocalCache/Roaming/Claude"))
        let moved = FileManager.default.temporaryDirectory.appendingPathComponent("SSH desktop 中文 " + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: moved) }
        let current = moved.appendingPathComponent("Local/Claude-Data/claude_pzs8sxrjxfjjc")
        try write(["lastKnownAccountUuid": "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"], to: current.appendingPathComponent("config.json"))
        let movedEnvironment = ["APPDATA": WindowsCodexExecutableDiscovery.path(moved.appendingPathComponent("Roaming")),
                                "LOCALAPPDATA": WindowsCodexExecutableDiscovery.path(moved.appendingPathComponent("Local"))]
        let expected = current.appendingPathComponent("ssh_configs.json").path
        XCTAssertEqual(WindowsSSHServices.desktopLocations(environment: movedEnvironment).map(\.path), [expected])
        XCTAssertEqual(WindowsSSHServices(userHome: moved, environment: movedEnvironment).desktopFile.path, expected,
            "Before Desktop saves a connection, the moved folder is still the one read")
        var remote = target(); remote.sshIdentityFile = "C:/中文 key/key's name"; remote.sshPort = 2200
        let args = try XCTUnwrap(WindowsSSHServices.arguments(remote))
        XCTAssertEqual(Array(args.suffix(6)), ["-p", "2200", "-i", "C:/中文 key/key's name", "--", "alias-a"])
        for option in ["BatchMode=yes", "StrictHostKeyChecking=yes", "UpdateHostKeys=no", "NumberOfPasswordPrompts=0", "ForwardAgent=no", "PermitLocalCommand=no"] { XCTAssertTrue(args.contains(option)) }
        XCTAssertNil(remote.sshArguments(validDestination: { _ in true }), "The default POSIX identity contract stays unchanged")
        for path in ["relative", "-oProxyCommand=bad", "C:/key\n", "C:relative"] { remote.sshIdentityFile = path; XCTAssertNil(WindowsSSHServices.arguments(remote)) }
        remote.sshIdentityFile = nil; remote.sshDestination = "host;bad"; XCTAssertNil(WindowsSSHServices.arguments(remote))
        remote.sshDestination = nil; remote.sshPort = 0; XCTAssertNil(WindowsSSHServices.arguments(remote))
    }
    func testDiscoveryUsesDesktopLocationAndCanonicalRoutesWithoutWritingSSHFiles() async throws {
        let (root, executable, environment) = try fixture(), codex = root.appendingPathComponent(".codex"), claude = root.appendingPathComponent(".claude")
        let desktop = root.appendingPathComponent("AppData/Roaming/Claude/ssh_configs.json")
        let ids = ["remote-ssh-discovered:alias-a", "remote-ssh-discovered:alias-b"]
        try write(["codex-managed-remote-connections": zip(ids, ["alias-a", "alias-b"]).map { ["hostId": $0, "alias": $1, "source": "discovered"] },
                   "remote-connection-auto-connect-by-host-id": Dictionary(uniqueKeysWithValues: ids.map { ($0, true) })], to: codex.appendingPathComponent(".codex-global-state.json"))
        try write(["configs": [["sshHost": "fixture@same.example", "sshIdentityFile": "C:/中文 key"],
            ["id": "other", "sshHost": "only.example", "sshPort": 2200], ["sshHost": "-oBad"]]], to: desktop)
        try write(["sshConfigs": [["id": "other", "name": "Settings override", "sshHost": "only.example", "sshPort": 2222]]], to: claude.appendingPathComponent("settings.json"))
        let config = root.appendingPathComponent(".ssh/config"), known = root.appendingPathComponent(".ssh/known_hosts")
        try FileManager.default.createDirectory(at: config.deletingLastPathComponent(), withIntermediateDirectories: true)
        let sentinel = Data("synthetic readonly marker\n".utf8); try sentinel.write(to: config); try sentinel.write(to: known)
        let services = WindowsSSHServices(ssh: executable, userHome: root, desktopFile: desktop, environment: environment, resolve: { host, port in
            guard let args = ClaudeSSHRouteResolver.arguments(host: host, port: port, timeout: 1, normalizeIPv6: WindowsIP.normalizedIPv6),
                  let data = await WindowsSubprocess.capture(executable: executable, arguments: WindowsSSHServices.harden(args), timeout: 2, limit: 65536, environment: environment) else { return nil }
            return ClaudeSSHRouteResolver.parse(data, normalizeIPv6: WindowsIP.normalizedIPv6)
        })
        let codexTargets = await services.codexTargets(home: codex)
        XCTAssertEqual(codexTargets.map(\.id), [ids[0]]); XCTAssertEqual(codexTargets.first?.home, "~/.codex")
        let targets = await services.claudeTargets(codexHome: codex, claudeHome: claude)
        XCTAssertEqual(targets.count, 2); XCTAssertEqual(targets.first?.id, ids[0]); XCTAssertEqual(targets.first?.sshIdentityFile, "C:/中文 key")
        XCTAssertEqual(targets.last?.sshPort, 2222); XCTAssertEqual(targets.last?.name, "Settings override")
        let calls = try Data(contentsOf: root.appendingPathComponent("calls.jsonl"))
        _ = await services.claudeTargets(codexHome: codex, claudeHome: claude)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("calls.jsonl")), calls, "Cached routes must not launch more ssh processes")
        XCTAssertEqual(try Data(contentsOf: config), sentinel); XCTAssertEqual(try Data(contentsOf: known), sentinel)
        XCTAssertFalse(String(decoding: calls, as: UTF8.self).contains("PRIVATE"))
    }
    func testLongSharedCommandPreservesSplitOutputInputOrderAndEOF() async throws {
        let (root, ssh, environment) = try fixture(), frames = SSHFrames()
        let home = Data(WindowsCodexExecutableDiscovery.path(root.appendingPathComponent("remote home")).utf8).base64EncodedString()
        let code = "import sys,json\nprint('rea',end='',flush=True)\nprint('dy',flush=True)\nfor line in sys.stdin:print('echo:'+line.strip(),flush=True)\nprint('eof',flush=True)\n#" + String(repeating: "x", count: 80000)
        let command = "python3 -u -c 'import base64;exec(base64.b64decode(\"" + Data(code.utf8).base64EncodedString() + "\").decode())' " + home
        let original = try XCTUnwrap(WindowsSSHServices.arguments(target())) + [command]
        let wire = try WindowsSSHInvocation(arguments: original)
        XCTAssertLessThan(wire.arguments.joined().utf16.count, 4096); XCTAssertGreaterThan(wire.input.count, 32767)
        let child = try WindowsSSHProcessLauncher(ssh: ssh, environment: environment).launch(.init(executable: ssh, arguments: original,
            environment: environment), output: { await frames.append($0) }, ended: {})
        defer { child.close() }
        try await wait { await frames.text().contains("ready\n") }
        try child.write(Data("first\nsecond\n".utf8))
        try await wait { await frames.text().contains("echo:second\n") }
        child.close(); let exited = await child.waitForExit(); XCTAssertTrue(exited)
        let text = await frames.text(); XCTAssertEqual(text, "ready\necho:first\necho:second\neof\n")
        XCTAssertFalse(child.isRunning); XCTAssertEqual(child.terminationStatus, 0)
        XCTAssertFalse(child.errorMessage().contains(root.path))
        XCTAssertThrowsError(try WindowsSSHInvocation(arguments: ["--", "-oBad", "command"]))
        XCTAssertThrowsError(try WindowsSSHInvocation(arguments: Array(original.dropLast()) + [String(repeating: "x", count: 1048577)]))
    }
    func testRealtimeSourceLifecycleReconnectDisableSleepAndPrivateProjection() async throws {
        let (root, ssh, environment) = try fixture(), frames = SSHFrames(), remote = target()
        let now = Date().timeIntervalSince1970
        let rows: [[String: Any]] = [["kind": "status", "connected": true], ["kind": "runtimeBatch", "events": [
            ["method": "turn/started", "threadId": thread, "turnId": "turn", "at": now],
            ["method": "turn/completed", "threadId": thread, "turnId": "turn", "at": now + 1, "status": "completed"]]]]
        let bytes = try rows.reduce(into: Data()) { $0 += try JSONSerialization.data(withJSONObject: $1) + Data([10]) }
        try bytes.write(to: root.appendingPathComponent("frames.jsonl"))
        let catalog = RemoteControlCatalog(fetch: { _ in throw CodexClientError.invalidResponse }, files: WindowsFileSystem(), makeClient: { _ in nil })
        let monitor = RealtimeActivityMonitor(controlCatalog: catalog, services: .init(desktopAvailable: { _ in false }, controlAvailable: { _ in false },
            makeDesktop: { _, _, _, _, _, _ in SSHUnusedDesktop() }, processes: WindowsSSHProcessLauncher(ssh: ssh, environment: environment),
            python: ssh, ssh: ssh, sshTargets: { _ in [remote] }, sshArguments: { WindowsSSHServices.arguments($0) }), retryInterval: 0.05)
        let home = root.appendingPathComponent("local")
        await monitor.startAsync(home: home, includeRemoteControl: false) { await frames.append($0) }
        try await wait { await frames.latest()?.activities.first?.phase == .completed }
        let latest = await frames.latest(); XCTAssertEqual(latest?.activities.first?.sourceHostID, remote.id)
        XCTAssertEqual(latest?.activities.first?.threadID, thread); XCTAssertTrue(latest?.attention.isEmpty == true)
        await monitor.startAsync(home: home, includeSSH: false, includeRemoteControl: false) { await frames.append($0) }
        let disabled = await monitor.statuses(); XCTAssertNil(disabled[remote.id])
        try Data().write(to: root.appendingPathComponent("disconnect"))
        await monitor.startAsync(home: home, includeRemoteControl: false) { await frames.append($0) }
        try await wait { await monitor.statuses()[remote.id]?.connected == false }
        try FileManager.default.removeItem(at: root.appendingPathComponent("disconnect"))
        try await wait { await monitor.statuses()[remote.id]?.connected == true }
        await monitor.shutdown(); let count = await frames.count()
        try await Task.sleep(nanoseconds: 150_000_000)
        let after = await frames.count(); XCTAssertEqual(after, count, "A sleeping/stopped source cannot publish late frames")
        let calls = try String(contentsOf: root.appendingPathComponent("calls.jsonl"), encoding: .utf8)
        XCTAssertFalse(calls.contains("prompt")); XCTAssertFalse(calls.contains("PRIVATE TASK"))
        await monitor.startAsync(home: home, includeRemoteControl: false) { await frames.append($0) }
        try await wait { await monitor.statuses()[remote.id]?.connected == true }
        await monitor.shutdown()
    }
    func testSyntheticRemoteRunsApprovalReplyAndEndingThroughSharedRuntimeState() async throws {
        let (root, ssh, environment) = try fixture(), frames = SSHRuntimeFrames()
        let code = """
        import json,sys,time
        thread="\(thread)"
        print(json.dumps({"kind":"status","connected":True}),flush=True)
        def emit(method,**extra):
            event=dict(method=method,threadId=thread,turnId="turn",at=time.time(),prompt="PRIVATE TASK SENTINEL",**extra)
            print(json.dumps({"kind":"runtimeBatch","events":[event]}),flush=True)
        emit("turn/started")
        for flags in [["waitingOnApproval"],[],["waitingOnUserInput"],[]]:
            if not sys.stdin.readline():raise SystemExit(2)
            emit("thread/status/changed",status="active",flags=flags)
        if not sys.stdin.readline():raise SystemExit(2)
        emit("turn/completed",status="completed")
        sys.stdin.read()
        """
        let home = Data(WindowsCodexExecutableDiscovery.path(root.appendingPathComponent("remote")).utf8).base64EncodedString()
        let command = "python3 -u -c 'import base64;exec(base64.b64decode(\"" + Data(code.utf8).base64EncodedString() + "\").decode())' " + home
        let child = try WindowsSSHProcessLauncher(ssh: ssh, environment: environment).launch(.init(executable: ssh,
            arguments: try XCTUnwrap(WindowsSSHServices.arguments(target())) + [command], environment: environment),
            output: { await frames.receive($0) }, ended: {})
        defer { child.close() }
        try await wait { await frames.count() == 1 }
        let initial = await frames.last(); XCTAssertEqual(initial?.phase, .running)
        for (offset, expected) in [ActivityPhase.waitingForInput, .running, .waitingForInput, .running, .completed].enumerated() {
            try child.write(Data("advance\n".utf8)); try await wait { await frames.count() == offset + 2 }
            let row = await frames.last(); XCTAssertEqual(row?.phase, expected)
            if offset == 0 { XCTAssertTrue(row?.waitingForApproval == true) }
            if offset == 2 { XCTAssertFalse(row?.waitingForApproval == true) }
            XCTAssertFalse(String(describing: row).contains("PRIVATE TASK SENTINEL"), "Only typed runtime facts leave the remote projection")
        }
        child.close(); let exited = await child.waitForExit(); XCTAssertTrue(exited); XCTAssertEqual(child.terminationStatus, 0)
    }
    func testTerminalResumeValidatesRouteSessionAndQuotesWithoutPromptArguments() throws {
        for provider in [AgentProvider.codex, .claude] {
            let resume = WindowsSSHResume(provider: provider, session: thread, target: target())
            let token = try XCTUnwrap(resume.token), parsed = try XCTUnwrap(WindowsSSHResume.decode(token))
            XCTAssertEqual(parsed, resume); XCTAssertEqual(parsed.arguments?.firstIndex(of: "-t") != nil, true)
            XCTAssertFalse(try XCTUnwrap(parsed.arguments?.last).contains("--prompt"))
        }
        XCTAssertNil(WindowsSSHResume(provider: .codex, session: thread + ";bad", target: target()).token)
        var unsafe = target(); unsafe.sshDestination = "host;bad"
        XCTAssertNil(WindowsSSHResume(provider: .claude, session: thread, target: unsafe).token)
        XCTAssertNil(WindowsSSHResume.decode("not base64"))
        XCTAssertEqual(WindowsSSHTerminal.quote("C:\\中文 key\\"), "\"C:\\中文 key\\\\\"")
        let row = SessionActivity(id: "fixture", sourceHostID: target().id, provider: .claude, sessionID: thread)
        var input = ActivityNavigationServices.Input(context: UUID().uuidString, activity: row, home: URL(fileURLWithPath: "C:/fixture"), transcript: nil)
        XCTAssertThrowsError(try WindowsActivityNavigation.resolve(input))
        input.remoteTarget = target()
        let plan = try WindowsActivityNavigation.resolve(input)
        XCTAssertEqual(plan.kind, "terminal")
        let encoded = try JSONEncoder().encode(plan)
        let fields = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        XCTAssertEqual(fields["terminal"] as? String, plan.terminal, "The merged host capability CodingKeys must preserve SSH navigation")
        XCTAssertNil(fields["hostApplication"], "Native host capabilities never cross the protocol boundary")
        XCTAssertEqual(try JSONDecoder().decode(EngineNavigationPlan.self, from: encoded), plan)
        input.remoteTarget = .init(id: "other", name: "", alias: "alias-a", home: "")
        XCTAssertThrowsError(try WindowsActivityNavigation.resolve(input))
    }
    func testEngineSettingClosesAndReopensSSHProjectionAcrossSleepAndWake() async throws {
        let (root, ssh, environment) = try fixture(), codex = root.appendingPathComponent("codex"), capture = SSHEngineCapture()
        let id = target().id
        try write(["codex-managed-remote-connections": [["hostId": id, "alias": "alias-a", "source": "discovered"]],
            "remote-connection-auto-connect-by-host-id": [id: true]], to: codex.appendingPathComponent(".codex-global-state.json"))
        let rows: [[String: Any]] = [["kind": "status", "connected": true], ["kind": "runtimeBatch", "events": [
            ["method": "turn/started", "threadId": thread, "turnId": "turn", "at": Date().timeIntervalSince1970, "prompt": "PRIVATE TASK SENTINEL"]]]]
        let bytes = try rows.reduce(into: Data()) { $0 += try JSONSerialization.data(withJSONObject: $1) + Data([10]) }
        try bytes.write(to: root.appendingPathComponent("frames.jsonl"))
        let services = WindowsSSHServices(ssh: ssh, userHome: root, desktopFile: root.appendingPathComponent("desktop.json"), environment: environment,
            resolve: { _, port in .init(hostname: "same.example", user: "fixture", port: port ?? 22) })
        let runtime = EngineRuntime(demo: false, dismissalStore: nil,
            desktopServices: .init { _, _, _, _ in SSHUnusedDesktop() }, sshServices: services, output: { capture.append($0) })
        func command(_ method: String, _ params: [String: Any] = [:]) throws -> Data {
            try JSONSerialization.data(withJSONObject: ["protocolVersion": 1, "id": UUID().uuidString, "method": method, "params": params])
        }
        _ = await runtime.receive(try command("initialize", ["enabledProviders": ["codex"], "codexHome": WindowsCodexExecutableDiscovery.path(codex), "hideProjects": true]))
        try await wait { capture.snapshot()?.sources.contains { $0.transport == "ssh" && $0.available } == true }
        XCTAssertTrue(capture.snapshot()?.tasks.contains { $0.sessionID == self.thread } == true)
        XCTAssertFalse(String(describing: capture.snapshot()).contains("PRIVATE TASK SENTINEL"))
        _ = await runtime.receive(try command("configure", ["monitorSSH": false]))
        XCTAssertFalse(capture.snapshot()?.sources.contains { $0.transport == "ssh" } == true)
        XCTAssertFalse(capture.snapshot()?.tasks.contains { $0.sessionID == thread } == true, "Disabled SSH callbacks cannot restore remote tasks")
        _ = await runtime.receive(try command("configure", ["monitorSSH": true]))
        try await wait { capture.snapshot()?.sources.contains { $0.transport == "ssh" && $0.available } == true }
        _ = await runtime.receive(try command("prepareForSleep"))
        _ = await runtime.receive(try command("resumeAfterSleep"))
        try await wait { capture.snapshot()?.sources.contains { $0.transport == "ssh" && $0.available } == true }
        await runtime.stop()
    }
}
