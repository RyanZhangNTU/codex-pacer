import Foundation
import FoundationNetworking
import XCTest
@testable import PacerCore
@testable import PacerEngineSupport

private final class WSLChild: ChildProcessConnection, @unchecked Sendable {
    let exited = ShutdownSignal(), ioClosed = ShutdownSignal()
    let output: @Sendable (Data) async -> Void, ended: @Sendable () async -> Void
    private let lock = NSLock()
    private var input = Data()
    var rpc = false
    init(output: @escaping @Sendable (Data) async -> Void, ended: @escaping @Sendable () async -> Void) { self.output = output; self.ended = ended }
    var isRunning: Bool { !exited.isFinished }
    var terminationStatus: Int32? { isRunning ? nil : 0 }
    func errorMessage() -> String { "Synthetic source unavailable" }
    func write(_ data: Data) throws {
        lock.lock(); input.append(data); let rpc = rpc; lock.unlock()
        guard rpc, let row = try JSONSerialization.jsonObject(with: data) as? [String: Any], let id = row["id"] else { return }
        let method = row["method"] as? String, result: [String: Any]
        switch method {
        case "initialize": result = [:]
        case "account/read": result = ["account": ["type": "chatgpt", "planType": "fixture"]]
        case "account/rateLimits/read": result = ["rateLimits": ["primary": ["usedPercent": 25, "windowDurationMins": 300]]]
        default: XCTFail("WSL quota must stay read-only"); result = [:]
        }
        let bytes = try JSONSerialization.data(withJSONObject: ["id": id, "result": result]) + Data([10])
        Task { await output(bytes) }
    }
    func close() { exited.finish(); ioClosed.finish() }
    func terminateImmediately() { close() }
    func send(_ row: [String: Any]) async throws { await output(try JSONSerialization.data(withJSONObject: row) + Data([10])) }
    func disconnect() async { close(); await ended() }
}
private final class WSLLaunches: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [(ChildProcessRequest, Data, WSLChild)] = []
    func launch(_ request: ChildProcessRequest, input: Data, output: @escaping @Sendable (Data) async -> Void,
                ended: @escaping @Sendable () async -> Void) -> WSLChild {
        let child = WSLChild(output: output, ended: ended)
        lock.lock(); values.append((request, input, child)); lock.unlock(); return child
    }
    func all() -> [(ChildProcessRequest, Data, WSLChild)] { lock.lock(); defer { lock.unlock() }; return values }
}
private actor WSLUpdates {
    var snapshot: RealtimeActivitySnapshot?
    func receive(_ value: RealtimeActivitySnapshot) { snapshot = value }
}
private actor WSLNoDesktop: DesktopActivityChannel {
    func start() {}
    func discover(_ threads: [String]) {}
    func setHosts(_ hosts: Set<String>) {}
    func setBatchInterval(_ seconds: TimeInterval, flushPending: Bool) {}
    func stop() {}
}
private final class WSLFrames: @unchecked Sendable {
    private let lock = NSLock()
    private var frames: [EngineSnapshot] = []
    func append(_ data: Data) {
        guard let value = try? JSONDecoder().decode(EngineSnapshot.self, from: data) else { return }
        lock.lock(); frames.append(value); lock.unlock()
    }
    func latest() -> EngineSnapshot? { lock.lock(); defer { lock.unlock() }; return frames.last }
    func count() -> Int { lock.lock(); defer { lock.unlock() }; return frames.count }
}
final class WindowsWSLTests: XCTestCase {
    private func profile(distro: String = "Fixture Linux", user: String = "synthetic", uid: UInt32 = 1000,
                         home: String = "/home/synthetic", stamp: String = "2:40") -> WindowsWSLProfile {
        .init(distro: distro, user: user, uid: uid, home: home, identity: stamp,
              codexHome: home + "/custom codex", claudeHome: home + "/custom claude", codexIdentity: "2:41", claudeIdentity: "2:42")
    }
    private func activate(_ registry: WindowsWSLRegistry, _ profile: WindowsWSLProfile) {
        XCTAssertTrue(registry.accept([profile], installed: [profile.distro.lowercased()], ticket: registry.begin()))
    }
    func testDistributionDecodingAndPathConversionCannotBorrowAnotherSource() throws {
        let values = "\u{feff}Fixture Linux\r\nUbuntu-24.04\r\n"
        XCTAssertEqual(WindowsWSLServices.distributions(Data(values.utf16.flatMap { [UInt8($0 & 255), UInt8($0 >> 8)] })), ["Fixture Linux", "Ubuntu-24.04"])
        XCTAssertEqual(WindowsWSLServices.distributions(Data("Fixture Linux\nUbuntu-24.04\n".utf8)), ["Fixture Linux", "Ubuntu-24.04"])
        XCTAssertNil(WindowsWSLServices.distributions(Data("same\nSAME\n".utf8)))
        XCTAssertNil(WindowsWSLServices.distributions(Data(repeating: 1, count: 65537)))
        for name in ["-option", "bad/name", "bad\\name", "bad\0name", "bad;name"] { XCTAssertFalse(WindowsWSLProfile.validDistro(name)) }
        XCTAssertEqual(WindowsWSLProfile.linuxPath("\\\\wsl.localhost\\Fixture Linux\\home\\synthetic\\.codex", distro: "Fixture Linux"), "/home/synthetic/.codex")
        XCTAssertEqual(WindowsWSLProfile.linuxPath("\\\\WSL$\\Fixture Linux\\home\\Case", distro: "fixture linux"), "/home/Case")
        XCTAssertEqual(WindowsWSLProfile.linuxPath("//wsl.localhost/Fixture Linux/home/Case", distro: "Fixture Linux"), "/home/Case")
        for path in ["C:\\Users\\synthetic\\.codex", "\\\\wsl.localhost\\Different\\home\\synthetic", "//wsl.localhost/Different/home/synthetic", "/home/../other", "\\\\server\\share\\.codex"] {
            XCTAssertNil(WindowsWSLProfile.linuxPath(path, distro: "Fixture Linux"))
        }
        XCTAssertNotEqual(profile().id, profile(user: "other", uid: 1001).id)
        XCTAssertNotEqual(profile().id, profile(distro: "Other").id)
        XCTAssertNotEqual(profile().id, profile(stamp: "2:90").id)
        XCTAssertNotEqual(profile().target(.codex)?.home, profile().target(.claude)?.home)
        XCTAssertNil(profile().target(.deepseek))
    }
    func testDiscoveryProbesOnlyRunningDistributionsAndCancellationCannotReplaceANewSlot() async throws {
        let first = profile(), registry = WindowsWSLRegistry()
        let data = try JSONEncoder().encode(first)
        actor Calls {
            var args: [[String]] = []
            func add(_ values: [String], profile: Data) -> Data {
                args.append(values)
                if values == ["--list", "--quiet"] { return Data("Fixture Linux\nStopped\n".utf8) }
                if values == ["--list", "--running", "--quiet"] { return Data("Fixture Linux\n".utf8) }
                return profile
            }
        }
        let calls = Calls(), services = WindowsWSLServices(registry: registry, capture: { _, args, timeout, limit in
            XCTAssertLessThanOrEqual(timeout, 5); XCTAssertLessThanOrEqual(limit, 65536)
            return await calls.add(args, profile: data)
        })
        await services.discover()
        let args = await calls.args
        XCTAssertEqual(args.count, 3)
        XCTAssertTrue(args.filter { $0.first == "--distribution" }.allSatisfy { $0[1] == "Fixture Linux" })
        XCTAssertEqual(registry.targets(.codex).first?.id, first.id)
        let old = registry.begin(), next = registry.begin()
        registry.suspend(ticket: old)
        XCTAssertTrue(registry.accept([profile(distro: "New")], installed: ["new"], ticket: next))
        XCTAssertFalse(registry.accept([first], installed: [first.distro.lowercased()], ticket: old))
        XCTAssertEqual(registry.snapshot().profiles.first?.distro, "New")
        registry.suspend(); XCTAssertTrue(registry.targets(.codex).isEmpty)
        XCTAssertEqual(registry.snapshot().profiles.count, 1, "An offline source retains its identity and completion namespace")
    }
    func testInvocationStreamsLargeSharedCommandAndRevokesBeforeForwardingLateFrames() async throws {
        let profile = profile(), registry = WindowsWSLRegistry(), launches = WSLLaunches()
        activate(registry, profile)
        let services = WindowsWSLServices(registry: registry, start: { launches.launch($0, input: $1, output: $2, ended: $3) })
        let target = try XCTUnwrap(profile.target(.codex)), route = try XCTUnwrap(registry.arguments(target))
        let claude = try XCTUnwrap(profile.target(.claude))
        let setup = try services.setupArguments(claude)
        XCTAssertEqual(setup.prefix(3), ["--pacer-wsl", "claude", profile.id])
        let encoded = try XCTUnwrap(setup.last?.split(separator: " ").last).description
        let payload = try XCTUnwrap(Data(base64Encoded: encoded))
        let settings = try XCTUnwrap(JSONSerialization.jsonObject(with: payload) as? [String: Any])
        XCTAssertEqual(settings["home"] as? String, profile.claudeHome); XCTAssertEqual(settings["requireHome"] as? Bool, true)
        actor Frames { var count = 0; func receive(_ data: Data) { count += 1 } }
        let frames = Frames(), command = String(repeating: "x", count: 100_000)
        let child = try services.launcher().launch(.init(executable: WindowsExecutables.ssh, arguments: route + [command],
            environment: ["WSLENV": "CODEX_HOME/p", "CODEX_HOME": "C:/foreign", "CLAUDE_CODE_OAUTH_TOKEN": "PRIVATE", "SystemRoot": "C:/Windows"]),
            output: { await frames.receive($0) }, ended: {})
        let invocation = try XCTUnwrap(launches.all().first)
        XCTAssertFalse(invocation.0.arguments.contains(command)); XCTAssertLessThan(invocation.0.arguments.joined().utf8.count, 30000)
        XCTAssertEqual(invocation.1, Data(("100000\n" + command).utf8)); XCTAssertNil(invocation.0.environment["WSLENV"])
        XCTAssertNil(invocation.0.environment["CODEX_HOME"]); XCTAssertNil(invocation.0.environment["CLAUDE_CODE_OAUTH_TOKEN"])
        try await invocation.2.send(["kind": "status", "connected": true])
        let accepted = await frames.count; XCTAssertEqual(accepted, 1)
        registry.suspend()
        XCTAssertThrowsError(try services.setupArguments(claude))
        try await invocation.2.send(["kind": "runtimeBatch", "events": []])
        let after = await frames.count; XCTAssertEqual(after, accepted)
        XCTAssertThrowsError(try services.launcher().launch(.init(executable: WindowsExecutables.ssh, arguments: route + [command], environment: [:]), output: { _ in }, ended: {}))
        child.close(); XCTAssertTrue(child.exited.isFinished); XCTAssertTrue(child.ioClosed.isFinished)
    }
    func testSharedRealtimeMonitorOwnsWSLRuntimeAttentionCompletionEofAndReconnection() async throws {
        let profile = profile(), registry = WindowsWSLRegistry(), launches = WSLLaunches(), updates = WSLUpdates()
        activate(registry, profile)
        let services = WindowsWSLServices(registry: registry, start: { launches.launch($0, input: $1, output: $2, ended: $3) })
        let catalog = RemoteControlCatalog(fetch: { _ in Data() }, files: WindowsFileSystem(), makeClient: { _ in nil })
        let monitor = RealtimeActivityMonitor(controlCatalog: catalog, services: .init(desktopAvailable: { _ in false }, controlAvailable: { _ in false },
            makeDesktop: { _, _, _, _, _, _ in WSLNoDesktop() }, processes: services.launcher(), python: WindowsExecutables.python, ssh: WindowsExecutables.ssh,
            sshTargets: { _ in registry.targets(.codex) }, sshArguments: { registry.arguments($0) }), retryInterval: 60)
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        await monitor.startAsync(home: home, includeSSH: true, includeRemoteControl: false) { await updates.receive($0) }
        let child = try XCTUnwrap(launches.all().first?.2), thread = "019a0000-0000-7000-8000-000000000001", now = Date().timeIntervalSince1970
        try await child.send(["kind": "status", "connected": true, "sourceAvailable": true])
        try await child.send(["kind": "runtimeBatch", "events": [["method": "turn/started", "threadId": thread, "turnId": "turn", "at": now]]])
        let running = await monitor.activities(); XCTAssertEqual(running.first?.sourceHostID, profile.id); XCTAssertEqual(running.first?.phase, .running)
        try await child.send(["kind": "runtimeBatch", "events": [["method": "turn/completed", "threadId": thread, "turnId": "turn", "at": now, "status": "interrupted"]]])
        let ended = await monitor.activities(); XCTAssertEqual(ended.first?.phase, .interrupted)
        var inbox = CompletionInbox(); inbox.bindSourceHomes(provider: .codex, localHome: home, remoteHomes: [profile.id: profile.codexHome])
        inbox.observe(running, at: Date(), retention: 600); inbox.observe(ended, at: Date(), retention: 600)
        await monitor.retryInactiveHelpers()
        await monitor.startAsync(home: home, includeSSH: true, includeRemoteControl: false) { await updates.receive($0) }
        XCTAssertEqual(launches.all().count, 1, "Retrying sources does not resubscribe a healthy helper")
        await child.disconnect()
        XCTAssertTrue(inbox.unreadActivities.contains { $0.sourceHostID == profile.id })
        await monitor.invalidateRemoteControlCatalog(retryTransport: true)
        await monitor.startAsync(home: home, includeSSH: true, includeRemoteControl: false) { await updates.receive($0) }
        // Failed helper backoff is source-owned; explicit refresh must not
        // replace healthy helpers or acknowledge their retained completions.
        XCTAssertTrue(inbox.unreadActivities.contains { $0.sourceHostID == profile.id })
        XCTAssertEqual(launches.all().count, 1, "Catalog retry alone retains the helper's backoff")
        await monitor.retryInactiveHelpers()
        await monitor.startAsync(home: home, includeSSH: true, includeRemoteControl: false) { await updates.receive($0) }
        XCTAssertEqual(launches.all().count, 2, "The explicit task-source retry bypasses inactive helper backoff")
        XCTAssertTrue(inbox.unreadActivities.contains { $0.sourceHostID == profile.id })
        await monitor.shutdown(); XCTAssertFalse(child.isRunning)
    }
    func testNavigationTokenBindsDistroUserRootAndProviderWithoutAWindowsProfileFallback() throws {
        let profile = profile(), thread = "019a0000-0000-7000-8000-000000000001"
        for provider in [AgentProvider.codex, .claude] {
            let resume = WindowsWSLResume(profile: profile, provider: provider, session: thread)
            let token = try XCTUnwrap(resume.token), decoded = try XCTUnwrap(WindowsWSLResume.decode(token))
            XCTAssertEqual(decoded, resume); XCTAssertEqual(decoded.arguments?.prefix(4), ["--distribution", profile.distro, "--user", profile.user])
            XCTAssertEqual(decoded.arguments?.dropFirst(4).first, "--exec")
            var row = SessionActivity(id: provider.activityID(sessionID: thread, sourceHostID: profile.id), sourceHostID: profile.id, provider: provider, sessionID: thread)
            row.applyRuntime(["method": "turn/started", "threadId": thread, "turnId": "turn"])
            var input = ActivityNavigationServices.Input(context: UUID().uuidString, activity: row, home: FileManager.default.temporaryDirectory, transcript: nil)
            XCTAssertThrowsError(try WindowsActivityNavigation.resolve(input))
            input.wslProfile = profile
            XCTAssertEqual(try WindowsActivityNavigation.resolve(input).kind, "wslTerminal")
            input.wslProfile = self.profile(distro: "Other")
            XCTAssertThrowsError(try WindowsActivityNavigation.resolve(input))
        }
        XCTAssertNil(WindowsWSLResume(profile: profile, provider: .codex, session: "not-a-session; prompt").token)
        XCTAssertNil(WindowsWSLResume(profile: profile, provider: .deepseek, session: thread).token)
        XCTAssertNil(WindowsWSLResume.decode("../not-token"))
    }
    func testClaudeQuotaUsesOnlyTheSelectedLinuxCredentialSnapshotAndRejectsReplacement() async throws {
        let profile = profile(), registry = WindowsWSLRegistry()
        activate(registry, profile)
        let credential = try JSONSerialization.data(withJSONObject: ["claudeAiOauth": ["accessToken": "fixture-oauth-token", "expiresAt": Date().addingTimeInterval(3600).timeIntervalSince1970 * 1000]])
        let config = try JSONSerialization.data(withJSONObject: ["oauthAccount": ["accountUuid": "fixture-account", "organizationUuid": "fixture-org"]])
        func envelope(stamp: UInt64) throws -> Data {
            try JSONSerialization.data(withJSONObject: [".credentials.json": ["data": credential.base64EncodedString(), "stamp": [2, 55, UInt64(credential.count), stamp, stamp]],
                ".claude.json": ["data": config.base64EncodedString(), "stamp": [2, 56, UInt64(config.count), 100, 100]]])
        }
        let before = try envelope(stamp: 100), after = try envelope(stamp: 200)
        actor Reads { var count = 0; var replace = false; func next(_ before: Data, _ after: Data) -> Data { count += 1; return replace && count % 2 == 0 ? after : before }; func replacing() { count = 0; replace = true } }
        let reads = Reads(), services = WindowsWSLServices(registry: registry, capture: { _, args, _, _ in
            XCTAssertEqual(args.prefix(4), ["--distribution", profile.distro, "--user", profile.user])
            return await reads.next(before, after)
        })
        let transport: ClaudeQuotaClient.Transport = { request in
            XCTAssertEqual(request.url?.absoluteString, "https://api.anthropic.com/api/oauth/usage")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer fixture-oauth-token")
            return (Data("{\"five_hour\":{\"utilization\":25}}".utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        let quota = try await services.readQuota(profile: profile, provider: .claude, transport: transport)
        XCTAssertEqual(quota.buckets.first?.windows.first?.remainingPercent, 75)
        await reads.replacing()
        do { _ = try await services.readQuota(profile: profile, provider: .claude, transport: transport); XCTFail("A changed Linux credential file cannot publish its former reading") }
        catch ClaudeQuotaError.accountChanged { } catch { XCTFail("Unexpected quota replacement result") }
        registry.suspend()
        do { _ = try await services.readQuota(profile: profile, provider: .claude, transport: transport); XCTFail("Offline sources cannot borrow Windows credentials") }
        catch ClaudeQuotaError.accountChanged { } catch { XCTFail("Unexpected offline result") }
    }
    func testCodexQuotaRunsReadOnlyRpcInsideTheExactLinuxProfile() async throws {
        let profile = profile(), registry = WindowsWSLRegistry(), launches = WSLLaunches()
        activate(registry, profile)
        let envelope = try JSONSerialization.data(withJSONObject: ["auth.json": ["data": "", "stamp": [2, 60, 10, 100, 100]]])
        let executable = URL(fileURLWithPath: try XCTUnwrap(ProcessInfo.processInfo.environment["PACER_DESKTOP_PIPE_FIXTURE"]))
        let services = WindowsWSLServices(executable: executable, registry: registry, capture: { _, _, _, _ in envelope }, start: {
            let child = launches.launch($0, input: $1, output: $2, ended: $3); child.rpc = true; return child
        })
        let quota = try await services.readQuota(profile: profile, provider: .codex)
        XCTAssertEqual(quota.buckets.first?.windows.first?.remainingPercent, 75)
        let launch = try XCTUnwrap(launches.all().first)
        XCTAssertEqual(launch.0.arguments.prefix(4), ["--distribution", profile.distro, "--user", profile.user])
        XCTAssertTrue(String(decoding: launch.1, as: UTF8.self).contains("codex -s read-only -a never app-server --listen stdio://"))
        XCTAssertFalse(launch.2.isRunning)
        XCTAssertFalse(String(decoding: launch.1, as: UTF8.self).contains(FileManager.default.homeDirectoryForCurrentUser.path))
    }
    func testEngineWiresSharedWSLTasksAndDisablingOrSleepingReleasesTheOwnedHelper() async throws {
        let profile = profile(), registry = WindowsWSLRegistry(), launches = WSLLaunches(), frames = WSLFrames()
        let data = try JSONEncoder().encode(profile)
        let services = WindowsWSLServices(registry: registry, capture: { _, args, _, _ in
            if args.first == "--list" { return Data((profile.distro + "\n").utf8) }
            if args.contains(where: { $0.contains("print('verified')") }) { return Data("verified\n".utf8) }
            return data
        }, start: { launches.launch($0, input: $1, output: $2, ended: $3) })
        let desktop = CodexDesktopServices { _, _, _, _ in WSLNoDesktop() }
        let runtime = EngineRuntime(demo: false, dismissalStore: nil, desktopServices: desktop, wslServices: services, output: { frames.append($0) })
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("pacer-wsl-engine-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        func command(_ method: String, _ params: [String: Any] = [:]) throws -> Data {
            try JSONSerialization.data(withJSONObject: ["protocolVersion": 1, "id": UUID().uuidString, "method": method, "params": params])
        }
        func until(_ condition: () -> Bool) async throws {
            let end = Date().addingTimeInterval(3)
            while !condition(), Date() < end { try await Task.sleep(nanoseconds: 5_000_000) }
            XCTAssertTrue(condition())
        }
        _ = await runtime.receive(try command("initialize", ["enabledProviders": ["codex"], "codexHome": EngineCodexSourceReport.path(root)]))
        try await until { !launches.all().isEmpty }
        let child = try XCTUnwrap(launches.all().last?.2), thread = "019a0000-0000-7000-8000-000000000001"
        try await child.send(["kind": "status", "connected": true, "sourceAvailable": true])
        try await child.send(["kind": "runtimeBatch", "events": [["method": "turn/started", "threadId": thread, "turnId": "one", "at": Date().timeIntervalSince1970]]])
        XCTAssertEqual(frames.latest()?.tasks.first?.sourceID, profile.id)
        XCTAssertEqual(frames.latest()?.sources.first { $0.transport == "wsl" && $0.provider == "codex" }?.state, "connected")
        XCTAssertEqual(frames.latest()?.connections?.hosts.first?.id, profile.id)
        XCTAssertTrue(frames.latest()?.connections?.hosts.first?.modules.first?.readsQuota == true)
        try await child.send(["kind": "runtimeBatch", "events": [["method": "turn/completed", "threadId": thread, "turnId": "one", "status": "completed", "at": Date().timeIntervalSince1970]]])
        XCTAssertTrue(frames.latest()?.tasks.first?.unread == true)
        XCTAssertNotNil(frames.latest()?.activityLinks?.first)
        _ = await runtime.receive(try command("configure", ["monitorWSL": false]))
        XCTAssertTrue(frames.latest()?.tasks.allSatisfy { $0.sourceID != profile.id } == true)
        XCTAssertFalse(child.isRunning)
        XCTAssertTrue(frames.latest()?.connections?.hosts.isEmpty == true)
        let prior = launches.all().count
        _ = await runtime.receive(try command("configure", ["monitorWSL": true]))
        try await until { launches.all().count > prior }
        let waking = try XCTUnwrap(launches.all().last?.2)
        await runtime.prepareForSleep(); XCTAssertTrue(registry.snapshot().active.isEmpty)
        XCTAssertFalse(waking.isRunning, "Sleep releases an active Linux helper, not only an already disabled source")
        await runtime.resumeAfterSleep()
        await runtime.stop()
        let count = frames.count()
        try await child.send(["kind": "runtimeBatch", "events": [["method": "turn/started", "threadId": thread, "turnId": "late"]]])
        XCTAssertEqual(frames.count(), count)
    }
}
