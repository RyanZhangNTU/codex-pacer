import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
@testable import PacerCore

final class RemoteControlAuthorizationTests: XCTestCase {
    private final class Files: PlatformFileSystem, @unchecked Sendable {
        let lock = NSLock()
        var values: [String: Data] = [:], revisions: [String: Int] = [:]
        var reads = 0
        func entries(in directory: URL) throws -> [URL] { [] }
        func metadata(_ url: URL, followingSymbolicLinks: Bool) -> PlatformFileMetadata? {
            lock.lock(); defer { lock.unlock() }
            guard let data = values[url.path] else { return nil }
            return .init(identity: url.path, size: UInt64(data.count), modified: Date(timeIntervalSince1970: Double(revisions[url.path] ?? 0)),
                         created: nil, isRegularFile: true)
        }
        func read(_ url: URL, offset: UInt64, maximumBytes: Int) throws -> Data {
            lock.lock(); defer { lock.unlock() }; reads += 1
            return Data((values[url.path] ?? Data()).dropFirst(Int(offset)).prefix(maximumBytes))
        }
        func replace(_ url: URL, with data: Data) -> Bool {
            lock.lock(); defer { lock.unlock() }; values[url.path] = data; revisions[url.path, default: 0] += 1; return true
        }
        func readCount() -> Int { lock.lock(); defer { lock.unlock() }; return reads }
    }
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
    private final class RPC: ChildProcessConnection, ChildProcessLauncher, @unchecked Sendable {
        let exited = ShutdownSignal(), ioClosed = ShutdownSignal(), lock = NSLock()
        var account = "account", methods: [String] = []
        var output: (@Sendable (Data) -> Void)?
        var isRunning: Bool { !exited.isFinished }
        var terminationStatus: Int32? { isRunning ? nil : 0 }
        func errorMessage() -> String { "" }
        func close() { exited.finish(); ioClosed.finish() }
        func terminateImmediately() { close() }
        func launch(_ request: ChildProcessRequest, output: @escaping @Sendable (Data) -> Void,
                    ended: @escaping @Sendable () -> Void) throws -> any ChildProcessConnection {
            lock.lock(); self.output = output; lock.unlock(); return self
        }
        func write(_ data: Data) throws {
            let row = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            let method = try XCTUnwrap(row["method"] as? String)
            guard let id = row["id"] else { return }
            lock.lock(); methods.append(method); let account = account, output = output; lock.unlock()
            let params = row["params"] as? [String: Any]
            let result: [String: Any]
            switch method {
            case "initialize": result = [:]
            case "account/read":
                XCTAssertEqual(params?["refreshToken"] as? Bool, false)
                result = ["account": ["type": "chatgpt"], "workspaceRouting": ["chatgptAccountId": account]]
            case "getAuthStatus":
                XCTAssertEqual(params?["refreshToken"] as? Bool, false); XCTAssertEqual(params?["includeToken"] as? Bool, true)
                let claims = try JSONSerialization.data(withJSONObject: ["https://api.openai.com/auth": ["chatgpt_account_id": account, "chatgpt_account_user_id": "user"]])
                let payload = claims.base64EncodedString().replacingOccurrences(of: "=", with: "").replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
                result = ["authMethod": "chatgpt", "authToken": "e30." + payload + ".synthetic"]
            default: XCTFail("A catalog must not send a model request"); result = [:]
            }
            output?(try JSONSerialization.data(withJSONObject: ["id": id, "result": result]) + Data([10]))
        }
    }
    private func enroll(_ files: Files, _ home: URL, client: String = "client", selected: String = "work") throws {
        _ = files.replace(home.appendingPathComponent(".codex-global-state.json"), with: try JSONSerialization.data(withJSONObject: [
            "electron-remote-control-client-enrollments": ["fixture": ["accountUserId": "user", "clientId": client, "privateKey": "PRIVATE"]],
            "selected-remote-host-id": "remote-control:" + selected]))
    }
    private func fixture(_ files: Files, _ home: URL, account: String = "account",
                         fetch: @escaping @Sendable (URLRequest) async throws -> Data) throws -> RemoteControlCatalog {
        try enroll(files, home); _ = files.replace(home.appendingPathComponent("auth.json"), with: Data("synthetic".utf8))
        return RemoteControlCatalog(fetch: fetch, files: files) { home in
            let rpc = RPC(); rpc.account = account
            return CodexClient(executable: home.appendingPathComponent("synthetic"), home: home, timeout: 1,
                               processes: rpc, executables: Executables(), files: files)
        }
    }
    private func devices() throws -> Data {
        try JSONSerialization.data(withJSONObject: ["items": [["env_id": "work", "name": "Work", "online": true],
                                                            ["env_id": "offline", "name": "Notebook", "online": false]]])
    }
    func testVerifiedGrantIsFileBoundAndTokenRefreshKeepsTheAccountScope() async throws {
        let files = Files(), home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let data = try devices(), catalog = try fixture(files, home) { _ in data }
        let targets = await catalog.targets(home: home)
        XCTAssertEqual(targets?.map(\.name), ["Work", "Notebook"])
        let first = catalog.authorization.snapshot(home: home)
        XCTAssertTrue(first.verified); XCTAssertEqual(first.hostIDs, ["remote-control:work", "remote-control:offline"])
        XCTAssertNotNil(first.scope); XCTAssertFalse(String(describing: first).contains("synthetic"))
        let reads = files.readCount()
        for _ in 0..<20 { XCTAssertTrue(catalog.authorization.snapshot(home: home).verified) }
        XCTAssertEqual(files.readCount(), reads, "Unchanged stamps must not repeatedly parse Desktop metadata")
        try enroll(files, home, selected: "offline")
        XCTAssertTrue(catalog.authorization.snapshot(home: home).verified, "Selection changes do not change the account")
        _ = files.replace(home.appendingPathComponent("auth.json"), with: Data("refreshed-token".utf8))
        XCTAssertFalse(catalog.authorization.snapshot(home: home).verified, "Changed auth suspends IO immediately")
        _ = await catalog.targets(home: home)
        XCTAssertEqual(catalog.authorization.snapshot(home: home).scope, first.scope)
        XCTAssertTrue(catalog.authorization.snapshot(home: home).verified)
        XCTAssertFalse(catalog.authorization.snapshot(home: home.appendingPathComponent("other")).verified)
        try enroll(files, home, client: "other-client")
        XCTAssertFalse(catalog.authorization.snapshot(home: home).verified)
        await catalog.shutdown()
        XCTAssertFalse(catalog.authorization.snapshot(home: home).verified)
        XCTAssertEqual(catalog.authorization.snapshot(home: home).scope, first.scope, "Sleep stops IO without discarding the account's unread scope")
    }
    func testTransientFailureKeepsVerifiedCacheButAuthorizationFailureRevokesIt() async throws {
        actor Replies {
            var status = 200
            func set(_ status: Int) { self.status = status }
            func read(_ data: Data) throws -> Data { if status != 200 { throw RemoteControlCatalog.CatalogError.status(status) }; return data }
        }
        let files = Files(), home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let replies = Replies(), data = try devices(), catalog = try fixture(files, home) { _ in try await replies.read(data) }
        _ = await catalog.targets(home: home)
        let first = catalog.authorization.snapshot(home: home)
        await replies.set(429); await catalog.invalidate()
        let cached = await catalog.targets(home: home)
        XCTAssertEqual(cached?.count, 2); XCTAssertTrue(catalog.authorization.snapshot(home: home).verified)
        XCTAssertEqual(catalog.authorization.snapshot(home: home).scope, first.scope)
        await replies.set(401); await catalog.invalidate()
        let rejected = await catalog.targets(home: home)
        XCTAssertNil(rejected); XCTAssertTrue(catalog.authorization.snapshot(home: home).revoked)
        XCTAssertFalse(catalog.authorization.snapshot(home: home).verified); XCTAssertNil(catalog.authorization.snapshot(home: home).scope)
        await replies.set(200); await catalog.invalidate()
        let retried = await catalog.targets(home: home)
        XCTAssertEqual(retried?.count, 2); XCTAssertTrue(catalog.authorization.snapshot(home: home).verified)
        await catalog.shutdown()
    }
    func testInFlightReplacementCannotPublishOldGrantAndOversizedMetadataIsNotRead() async throws {
        let files = Files(), home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let data = try devices(), catalog = try fixture(files, home) { _ in
            _ = files.replace(home.appendingPathComponent("auth.json"), with: Data("different-profile".utf8)); return data
        }
        let targets = await catalog.targets(home: home)
        XCTAssertNil(targets); XCTAssertFalse(catalog.authorization.snapshot(home: home).verified)
        _ = files.replace(home.appendingPathComponent(".codex-global-state.json"), with: Data(repeating: 32, count: 8 * 1024 * 1024 + 1))
        let count = files.readCount()
        XCTAssertNil(RemoteControlCatalogIdentity.read(home: home, files: files))
        XCTAssertEqual(files.readCount(), count, "Check the size before allocating metadata")
        await catalog.shutdown()
    }
    func testAccountNamespaceInvalidatesOldNavigationAndNeverSharesAcknowledgments() throws {
        let files = Files(), home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = CompletionDismissalStore(fileURL: home.appendingPathComponent("dismissals"), files: files)
        let thread = "019a0000-0000-7000-8000-000000000001", host = "remote-control:work", date = Date()
        func ending(_ host: String?) -> SessionActivity {
            var value = SessionActivity(id: AgentProvider.codex.activityID(sessionID: thread, sourceHostID: host), sourceHostID: host)
            value.applyRuntime(["method": "turn/started", "threadId": thread, "turnId": "turn", "at": date.timeIntervalSince1970 - 1])
            value.applyRuntime(["method": "turn/completed", "threadId": thread, "turnId": "turn", "at": date.timeIntervalSince1970])
            return value
        }
        let remote = ending(host), local = ending(nil)
        var inbox = CompletionInbox(dismissalStore: store)
        inbox.bindSourceHomes(provider: .codex, localHome: home, remoteControlHostIDs: [host], remoteControlAccountScope: "account-a")
        inbox.observe([remote, local], at: date, retention: 600)
        let token = inbox.sourceToken(for: remote), localToken = inbox.sourceToken(for: local)
        inbox.dismiss(remote)
        inbox.bindSourceHomes(provider: .codex, localHome: home, remoteControlHostIDs: [host], remoteControlAccountScope: "account-b")
        XCTAssertFalse(inbox.isCurrentSource(token)); XCTAssertTrue(inbox.isCurrentSource(localToken))
        inbox.observe([remote, local], at: date, retention: 600)
        XCTAssertTrue(inbox.unreadActivities.contains { $0.id == remote.id }, "A new account cannot inherit the former account's read state")
        var returned = CompletionInbox(dismissalStore: store)
        returned.bindSourceHomes(provider: .codex, localHome: home, remoteControlHostIDs: [host], remoteControlAccountScope: "account-a")
        returned.observe([remote], at: date, retention: 600)
        XCTAssertTrue(returned.activities.isEmpty, "Returning to the same account restores its own acknowledgment")
    }
}
