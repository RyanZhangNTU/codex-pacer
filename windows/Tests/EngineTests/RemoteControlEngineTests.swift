import Foundation
import XCTest
@testable import PacerCore
@testable import PacerEngineSupport

private actor RemoteChannel: DesktopActivityChannel {
    let frame: @Sendable (Data) async -> Void, closed: @Sendable () async -> Void
    var hosts: Set<String>, stopped = false
    var remoteRoutes: [NativeDesktopSession.Key] = []
    init(hosts: Set<String>, frame: @escaping @Sendable (Data) async -> Void, closed: @escaping @Sendable () async -> Void) {
        self.hosts = hosts; self.frame = frame; self.closed = closed
    }
    func start() {}
    func discover(_ threads: [String]) {}
    func discoverRemote(_ routes: [NativeDesktopSession.Key]) { remoteRoutes += routes }
    func setHosts(_ hosts: Set<String>) { self.hosts = hosts }
    func setBatchInterval(_ seconds: TimeInterval, flushPending: Bool) {}
    func stop() { stopped = true }
    func send(_ value: [String: Any]) async throws { await frame(try JSONSerialization.data(withJSONObject: value)) }
    func disconnect() async { await closed() }
}
private final class RemoteFixture: @unchecked Sendable {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("pacer-remote-" + UUID().uuidString)
    let lock = NSLock()
    var channels: [RemoteChannel] = [], snapshots: [EngineSnapshot] = [], messages: [[String: Any]] = []
    var account = "first", fail = false
    private var directoryRequests = 0, addedDevice = false, workOnline = true
    private struct Executables: ExecutablePlatform {
        func normalize(_ input: String, userHome: URL) -> String { input }
        func isAbsolutePath(_ path: String) -> Bool { true }
        func searchPaths(environment: [String: String], userHome: URL, applicationURLs: [URL]?, systemBinDirectories: [String]?) -> [ExecutableSearchPath] { [] }
        func isExecutableFile(_ url: URL) -> Bool { true }
        func executableIdentity(_ url: URL) -> String { url.path }
        func selectionKind(_ url: URL) -> ExecutableSelectionKind? { .file }
        func selectionURLs(_ url: URL, isDirectory: Bool) -> [URL] { [url] }
        func launchEnvironment(for executable: URL, inherited: [String: String], userHome: URL) -> [String: String] { inherited }
    }
    private final class RPC: ChildProcessConnection, @unchecked Sendable {
        let exited = ShutdownSignal(), ioClosed = ShutdownSignal()
        let account: String, output: @Sendable (Data) -> Void
        init(account: String, output: @escaping @Sendable (Data) -> Void) { self.account = account; self.output = output }
        var isRunning: Bool { !exited.isFinished }
        var terminationStatus: Int32? { isRunning ? nil : 0 }
        func errorMessage() -> String { "" }
        func close() { exited.finish(); ioClosed.finish() }
        func terminateImmediately() { close() }
        func write(_ data: Data) throws {
            let row = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            guard let id = row["id"] else { return }
            let method = try XCTUnwrap(row["method"] as? String)
            var result: [String: Any] = [:]
            if method == "account/read" { result = ["account": ["type": "chatgpt"], "workspaceRouting": ["chatgptAccountId": account]] }
            else if method == "getAuthStatus" {
                let claims = try JSONSerialization.data(withJSONObject: ["https://api.openai.com/auth": ["chatgpt_account_id": account, "chatgpt_account_user_id": "user"]])
                let token = "e30." + claims.base64EncodedString().replacingOccurrences(of: "=", with: "").replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_") + ".fixture"
                result = ["authMethod": "chatgpt", "authToken": token]
            } else { XCTAssertEqual(method, "initialize") }
            output(try JSONSerialization.data(withJSONObject: ["id": id, "result": result]) + Data([10]))
        }
    }
    private struct Launcher: ChildProcessLauncher {
        let account: String
        func launch(_ request: ChildProcessRequest, output: @escaping @Sendable (Data) -> Void,
                    ended: @escaping @Sendable () -> Void) throws -> any ChildProcessConnection { RPC(account: account, output: output) }
    }
    init() throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: ["electron-remote-control-client-enrollments": ["fixture": ["accountUserId": "user", "clientId": "client"]]])
            .write(to: root.appendingPathComponent(".codex-global-state.json"))
        try Data("first-profile".utf8).write(to: root.appendingPathComponent("auth.json"))
        try Data().write(to: root.appendingPathComponent("synthetic.exe"))
    }
    deinit { try? FileManager.default.removeItem(at: root) }
    lazy var catalog = RemoteControlCatalog(fetch: { [self] request in
        return try response()
    }, files: WindowsFileSystem(), makeClient: { [self] home in
        lock.lock(); let account = account; lock.unlock()
        return CodexClient(executable: home.appendingPathComponent("synthetic.exe"), home: home, timeout: 1,
                           processes: Launcher(account: account), executables: Executables(), files: WindowsFileSystem())
    })
    private func response() throws -> Data {
        lock.lock()
        directoryRequests += 1
        let fail = fail, addedDevice = addedDevice, workOnline = workOnline
        lock.unlock()
        if fail { throw RemoteControlCatalog.CatalogError.status(401) }
        var rows: [[String: Any]] = [["env_id": "work", "display_name": "Workstation", "online": workOnline],
                                    ["env_id": "offline", "name": "Notebook", "online": false]]
        if addedDevice { rows.append(["env_id": "new", "name": "New device", "online": true]) }
        return try JSONSerialization.data(withJSONObject: ["items": rows])
    }
    func setDirectory(added: Bool = false, online: Bool = true) {
        lock.lock(); addedDevice = added; workOnline = online; lock.unlock()
    }
    func fetchCount() -> Int { lock.lock(); defer { lock.unlock() }; return directoryRequests }
    var services: CodexDesktopServices {
        .init(makeConnection: { [self] _, _, frame, closed in make(["local"], frame, closed) }, catalog: catalog,
              routed: { [self] _, hosts, _, _, frame, closed in make(hosts, frame, closed) })
    }
    private func make(_ hosts: Set<String>, _ frame: @escaping @Sendable (Data) async -> Void,
                      _ closed: @escaping @Sendable () async -> Void) -> RemoteChannel {
        let channel = RemoteChannel(hosts: hosts, frame: frame, closed: closed)
        lock.lock(); channels.append(channel); lock.unlock(); return channel
    }
    func read() -> (channels: [RemoteChannel], snapshot: EngineSnapshot?, messages: [[String: Any]]) {
        lock.lock(); defer { lock.unlock() }; return (channels, snapshots.last, messages)
    }
    func append(_ data: Data) {
        lock.lock(); defer { lock.unlock() }
        if let snapshot = try? JSONDecoder().decode(EngineSnapshot.self, from: data) { snapshots.append(snapshot) }
        else if let row = try? JSONSerialization.jsonObject(with: data) as? [String: Any] { messages.append(row) }
    }
    func replaceAccount() throws {
        lock.lock(); account = "second"; lock.unlock()
        try Data("second-account-profile".utf8).write(to: root.appendingPathComponent("auth.json"), options: .atomic)
    }
}

final class RemoteControlEngineTests: XCTestCase {
    private let thread = "019a0000-0000-7000-8000-000000000001", host = "remote-control:work"
    private func command(_ method: String, _ params: [String: Any] = [:], id: String = UUID().uuidString) throws -> Data {
        try JSONSerialization.data(withJSONObject: ["protocolVersion": 1, "id": id, "method": method, "params": params])
    }
    private func until(_ condition: () async -> Bool, file: StaticString = #filePath, line: UInt = #line) async throws {
        let end = Date().addingTimeInterval(TestWait.limit)
        while !(await condition()) {
            if Date() >= end { XCTFail("Remote fixture did not settle", file: file, line: line); throw ActivityNavigationError.unavailable }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
    }
    private func events(_ method: String, host: String? = nil, at: Date = Date(), status: String = "completed", turn: String = "turn") -> [String: Any] {
        ["kind": "runtimeBatch", "hostId": host ?? self.host, "events": [["method": method, "threadId": thread,
            "turnId": turn, "status": status, "at": at.timeIntervalSince1970]]]
    }
    func testUnknownDeviceRequiresDirectoryConfirmationAndRetainsOnlyTheRoute() async throws {
        let fixture = try RemoteFixture(), monitor = fixture.services.makeMonitor()
        addTeardownBlock { await monitor.shutdown() }
        await monitor.startAsync(home: fixture.root, includeSSH: false) { _ in }
        let channel = try XCTUnwrap(fixture.read().channels.last), unknown = "remote-control:new"
        try await channel.send(events("turn/started", host: unknown))
        let rejected = await monitor.activities()
        XCTAssertTrue(rejected.isEmpty)
        XCTAssertEqual(fixture.fetchCount(), 1)
        fixture.setDirectory(added: true)
        let hint = ["kind": "remoteControlRoute", "hostId": unknown, "threadId": thread]
        try await channel.send(hint); try await channel.send(hint)
        try await until { await channel.remoteRoutes.count == 1 }
        let discovered = await channel.remoteRoutes
        XCTAssertEqual(discovered, [.init(host: unknown, thread: thread)])
        XCTAssertEqual(fixture.fetchCount(), 2)
        try await channel.send(events("turn/started", host: unknown))
        let accepted = await monitor.activities()
        XCTAssertEqual(accepted.first?.sourceHostID, unknown)
    }
    func testRuntimeLossRefreshesPresenceOnceAndOfflineHostCanResumeFromEvents() async throws {
        let fixture = try RemoteFixture(), monitor = fixture.services.makeMonitor()
        addTeardownBlock { await monitor.shutdown() }
        await monitor.startAsync(home: fixture.root, includeSSH: false) { _ in }
        let channel = try XCTUnwrap(fixture.read().channels.last)
        try await channel.send(events("turn/started"))
        fixture.setDirectory(online: false)
        let lost: [String: Any] = ["kind": "status", "hostId": host, "connected": false,
                                  "waitingForSession": false, "remoteRuntimeLost": true]
        try await channel.send(lost); try await channel.send(lost)
        try await until { await monitor.statuses()[self.host]?.remoteHostOnline == false }
        XCTAssertEqual(fixture.fetchCount(), 2)
        try await channel.send(lost)
        try await channel.send(events("turn/started", turn: "after-reconnect"))
        let restored = await monitor.activities()
        XCTAssertTrue(restored.contains { $0.sourceHostID == host && $0.phase == .running })
        XCTAssertEqual(fixture.fetchCount(), 2, "A live frame reconnects an already verified device without a directory request")
    }
    func testCatalogStatesExactNavigationAndUnreadSurviveEofButNotAccountReplacement() async throws {
        let fixture = try RemoteFixture()
        let wsl = WindowsWSLServices(capture: { _, _, _, _ in Data() }, watchRegistrations: { _ in nil })
        let runtime = EngineRuntime(demo: false, dismissalStore: nil, desktopServices: fixture.services,
            wslServices: wsl,
            navigationServices: .init { input in
                try WindowsActivityNavigation.resolve(input)
            }, output: { fixture.append($0) })
        _ = await runtime.receive(try command("initialize", ["enabledProviders": ["codex"], "monitorRemoteControl": true,
            "codexHome": EngineCodexSourceReport.path(fixture.root)]))
        try await until { fixture.read().snapshot?.sources.contains { $0.sourceName == "Workstation" } == true }
        _ = await runtime.receive(try command("refreshWSL"))
        try await until { fixture.read().snapshot?.wslAvailability == .unavailable }
        _ = await runtime.receive(try command("refreshTaskSources"))
        XCTAssertEqual(fixture.fetchCount(), 1, "WSL discovery and task-source retry use the current directory")
        let channel = try XCTUnwrap(fixture.read().channels.last)
        try await channel.send(["kind": "status", "hostId": host, "connected": false, "waitingForSession": true])
        XCTAssertEqual(fixture.read().snapshot?.sources.first { $0.transport == "remote-control" && $0.sourceName == "Workstation" }?.state, "idle")
        XCTAssertEqual(fixture.read().snapshot?.sources.first { $0.sourceName == "Notebook" }?.state, "offline")
        XCTAssertEqual(fixture.read().snapshot?.connections?.sources.first { $0.key == host }?.module.state, "idle")
        XCTAssertEqual(fixture.read().snapshot?.connections?.sources.first { $0.name == "Notebook" }?.module.state, "offline")
        let date = Date()
        try await channel.send(events("turn/started", at: date))
        XCTAssertEqual(fixture.read().snapshot?.tasks.first?.phase, "running")
        try await channel.send(["kind": "attention", "hostId": host, "threadId": thread, "requests": [["id": "approval", "kind": "approval"]]])
        XCTAssertEqual(fixture.read().snapshot?.requests.count, 1)
        try await channel.send(["kind": "attention", "hostId": host, "threadId": thread, "requests": [[String: String]]()])
        try await channel.send(events("turn/completed", at: date.addingTimeInterval(0.01)))
        let ending = try XCTUnwrap(fixture.read().snapshot?.tasks.first)
        XCTAssertTrue(ending.unread); XCTAssertEqual(ending.phase, "completed")
        let link = try XCTUnwrap(fixture.read().snapshot?.activityLinks?.first)
        _ = await runtime.receive(try command("prepareActivityOpen", ["context": link.context], id: "open"))
        let value = try XCTUnwrap(fixture.read().messages.last { $0["id"] as? String == "open" }?["value"] as? [String: Any])
        let url = try XCTUnwrap((value["url"] as? String).flatMap(URL.init(string:)))
        XCTAssertEqual(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first?.value, host)
        _ = await runtime.receive(try command("cancelActivityOpen", ["context": link.context]))
        await channel.disconnect()
        XCTAssertTrue(fixture.read().snapshot?.tasks.first?.unread == true, "EOF cannot acknowledge a completion")
        try fixture.replaceAccount()
        _ = await runtime.receive(try command("prepareActivityOpen", ["context": link.context], id: "stale"))
        XCTAssertEqual(fixture.read().messages.last { $0["id"] as? String == "stale" }?["code"] as? String, "staleActivityOpen")
        _ = await runtime.receive(try command("refreshRemoteControl"))
        try await until { fixture.read().channels.count >= 2 && fixture.read().snapshot?.tasks.isEmpty == true }
        try await channel.send(events("turn/started"))
        XCTAssertTrue(fixture.read().snapshot?.tasks.isEmpty == true, "The old channel cannot reintroduce an account's tasks")
        let next = try XCTUnwrap(fixture.read().channels.last)
        try await next.send(events("turn/started")); try await next.send(events("turn/completed"))
        XCTAssertTrue(fixture.read().snapshot?.tasks.first?.unread == true, "Identical host/thread/turn IDs in a new account remain unread")
        let current = try XCTUnwrap(fixture.read().snapshot?.activityLinks?.first)
        _ = await runtime.receive(try command("prepareActivityOpen", ["context": current.context]))
        _ = await runtime.receive(try command("failActivityOpen", ["context": current.context, "navigationMessage": "Synthetic open failure"]))
        XCTAssertTrue(fixture.read().snapshot?.tasks.first?.unread == true)
        XCTAssertEqual(fixture.read().snapshot?.navigationError?.message, "Synthetic open failure")
        _ = await runtime.receive(try command("prepareActivityOpen", ["context": current.context]))
        _ = await runtime.receive(try command("completeActivityOpen", ["context": current.context]))
        XCTAssertTrue(fixture.read().snapshot?.tasks.allSatisfy { !$0.unread } == true, "Only a successful current open acknowledges its captured ending")
        try await next.send(events("turn/started", turn: "interrupted"))
        try await next.send(events("turn/completed", status: "interrupted", turn: "interrupted"))
        XCTAssertEqual(fixture.read().snapshot?.tasks.first?.phase, "interrupted")
        XCTAssertTrue(fixture.read().snapshot?.tasks.first?.unread == true)
        let interrupted = try XCTUnwrap(fixture.read().snapshot?.activityLinks?.first)
        _ = await runtime.receive(try command("configure", ["monitorRemoteControl": false]))
        try await until { fixture.read().snapshot?.sources.allSatisfy { $0.transport != "remote-control" } == true }
        _ = await runtime.receive(try command("prepareActivityOpen", ["context": interrupted.context], id: "disabled"))
        XCTAssertEqual(fixture.read().messages.last { $0["id"] as? String == "disabled" }?["code"] as? String, "staleActivityOpen")
        await runtime.stop()
    }
    func testToggleRevokesNavigationAndExplicitRetryReconnectsWithoutWaitingForBackoff() async throws {
        let fixture = try RemoteFixture()
        // Exercise the same shared retry path with an isolated catalog/channel.
        let monitor = fixture.services.makeMonitor(retryInterval: 60)
        await monitor.startAsync(home: fixture.root, includeSSH: false, includeRemoteControl: true, useSSHFallback: false) { _ in }
        let first = try XCTUnwrap(fixture.read().channels.last)
        await first.disconnect()
        await monitor.retryInactiveHelpers()
        await monitor.startAsync(home: fixture.root, includeSSH: false, includeRemoteControl: true, useSSHFallback: false) { _ in }
        XCTAssertEqual(fixture.read().channels.count, 2)
        await monitor.startAsync(home: fixture.root, includeSSH: false, includeRemoteControl: false, useSSHFallback: false) { _ in }
        let disabled = await fixture.read().channels.last?.hosts
        XCTAssertEqual(disabled, ["local"])
        XCTAssertFalse(fixture.catalog.authorization.snapshot(home: fixture.root).verified)
        await monitor.shutdown()
    }
    func testRemoteNavigationRequiresTheExactAuthorizedHostAndIgnoresLocalRollouts() throws {
        let thread = thread, host = host, home = FileManager.default.temporaryDirectory
        var activity = SessionActivity(id: "codex:" + host + ":" + thread, sourceHostID: host)
        activity.applyRuntime(["method": "turn/started", "threadId": thread, "turnId": "turn"])
        var input = ActivityNavigationServices.Input(context: UUID().uuidString, activity: activity, home: home, transcript: nil)
        XCTAssertThrowsError(try WindowsActivityNavigation.resolve(input))
        input.remoteControlHosts = ["remote-control:other"]
        XCTAssertThrowsError(try WindowsActivityNavigation.resolve(input))
        input.remoteControlHosts = [host]
        XCTAssertTrue(try WindowsActivityNavigation.resolve(input).url?.contains("hostId=") == true)
    }
}

#if os(Windows)
final class WindowsRemoteControlGateTests: XCTestCase {
    func testSavedHintsCannotGrantAccessAndScopeReplacementFailsClosed() throws {
        let home = FileManager.default.temporaryDirectory, view = RemoteControlAuthorizationView(), host = "remote-control:work"
        let gate = WindowsRemoteControlGate(authorization: { view.snapshot(home: home) })
        XCTAssertEqual(try gate.update(["local", host]), ["local"]); XCTAssertFalse(gate.permit(host))
        view.publish(home: home, scope: "one", hosts: [host, "local", "remote-ssh-discovered:other"], verified: true, validate: { true })
        XCTAssertEqual(try gate.update(["local", host, "remote-control:foreign"]), ["local", host])
        XCTAssertTrue(gate.permit(host)); XCTAssertFalse(gate.permit("remote-control:foreign")); XCTAssertFalse(gate.permit("local"))
        view.publish(home: home, scope: "two", hosts: [host], verified: true, validate: { true })
        XCTAssertFalse(gate.validate()); XCTAssertFalse(gate.permit(host)); XCTAssertThrowsError(try gate.update([host]))
        let replacement = WindowsRemoteControlGate(authorization: { view.snapshot(home: home) })
        XCTAssertEqual(try replacement.update([host]), [host])
        view.clear(home: home); XCTAssertFalse(replacement.validate()); XCTAssertFalse(replacement.permit(host))
        view.publish(home: home, scope: nil, hosts: [host], verified: true, validate: { true })
        XCTAssertEqual(try WindowsRemoteControlGate(authorization: { view.snapshot(home: home) }).update(["local", host]), ["local"])
    }
}
#endif
