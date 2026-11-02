#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Foundation
import XCTest
@testable import PacerCore

final class ClaudeSharedPortTests: XCTestCase {
    private final class Files: PlatformFileSystem, @unchecked Sendable {
        private let lock = NSRecursiveLock()
        private var values: [String: Data] = [:]
        private var metadataValues: [String: PlatformFileMetadata] = [:]
        private var reads: [String: Int] = [:]
        private var revision = 0
        func put(_ data: Data, at url: URL, regular: Bool = true) {
            lock.lock(); defer { lock.unlock() }
            revision += 1; values[url.path] = data
            metadataValues[url.path] = .init(identity: String(revision), size: UInt64(data.count),
                modified: Date(timeIntervalSince1970: Double(revision)), created: nil, isRegularFile: regular)
        }
        func directory(_ url: URL) {
            lock.lock(); defer { lock.unlock() }
            metadataValues[url.path] = .init(identity: url.path, size: 0, modified: .distantPast,
                created: nil, isRegularFile: false, isDirectory: true)
        }
        func metadata(_ url: URL, followingSymbolicLinks: Bool) -> PlatformFileMetadata? {
            lock.lock(); defer { lock.unlock() }; return metadataValues[url.path]
        }
        func read(_ url: URL, offset: UInt64, maximumBytes: Int) throws -> Data {
            lock.lock(); defer { lock.unlock() }
            reads[url.path, default: 0] += 1
            return Data((values[url.path] ?? Data()).dropFirst(Int(offset)).prefix(maximumBytes))
        }
        func replace(_ url: URL, with data: Data) -> Bool { put(data, at: url); return true }
        func entries(in directory: URL) throws -> [URL] {
            lock.lock(); defer { lock.unlock() }
            return metadataValues.keys.map { URL(fileURLWithPath: $0) }.filter { $0.deletingLastPathComponent().path == directory.path }
        }
        func readCount(_ url: URL) -> Int { lock.lock(); defer { lock.unlock() }; return reads[url.path, default: 0] }
    }
    private final class Events: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [String] = []
        func append(_ value: String) { lock.lock(); values.append(value); lock.unlock() }
        var snapshot: [String] { lock.lock(); defer { lock.unlock() }; return values }
    }
    private let date = Date(timeIntervalSince1970: 1_800_000_000)
    private let account = "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"
    private let organization = "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb"
    private let cli = "cccccccc-cccc-cccc-cccc-cccccccccccc"
    private func json(_ object: Any) throws -> Data { try JSONSerialization.data(withJSONObject: object, options: [.fragmentsAllowed]) }

    func testJSONNumbersRejectBooleansNonfiniteValuesAndOtherTypesOnEveryPlatform() throws {
        for text in ["true", "false", "null", "\"1\"", "{}", "[]"] {
            let value = try JSONSerialization.jsonObject(with: Data(text.utf8), options: [.fragmentsAllowed])
            XCTAssertNil(ClaudeQuotaDecoder.number(value), text)
        }
        for value in [0.0, 1, -1, 0.5, 123.25] {
            let decoded = try JSONSerialization.jsonObject(with: json(value), options: [.fragmentsAllowed])
            XCTAssertEqual(ClaudeQuotaDecoder.number(decoded), value)
        }
        for value in [Double.infinity, -.infinity, .nan] { XCTAssertNil(ClaudeQuotaDecoder.number(NSNumber(value: value))) }
        for value in [NSNumber(value: Int8(0)), NSNumber(value: Int8(1)), NSNumber(value: UInt8(1))] {
            XCTAssertEqual(ClaudeQuotaDecoder.number(value), value.doubleValue)
        }
        XCTAssertThrowsError(try ClaudeQuotaDecoder.decodeUsage(json(["five_hour": ["utilization": true, "resets_at": date.timeIntervalSince1970 + 300]])))
        let scope = String(repeating: "a", count: 64)
        let cache: [String: Any] = ["version": true, "account_binding": scope, "scope": scope,
            "access_token": "synthetic-token", "expires_at": date.timeIntervalSince1970 + 100]
        XCTAssertNil(try ClaudeQuotaCredentialCache.decode(json(cache), accountBinding: scope, expectedScope: scope, now: date))
    }

    func testAccountIdentityUsesInjectedFileIdentityAndNeverReadsAnotherProfile() throws {
        let files = Files(), user = URL(fileURLWithPath: "/synthetic/shared-user-" + UUID().uuidString, isDirectory: true)
        let home = user.appendingPathComponent(".claude"), config = user.appendingPathComponent(".claude.json")
        try files.put(json(["oauthAccount": ["accountUuid": account, "organizationUuid": organization]]), at: config)
        let first = try XCTUnwrap(ClaudeCredentialStore.identity(userHome: user, home: home, files: files))
        XCTAssertEqual(ClaudeCredentialStore.identity(userHome: user, home: home, files: files)?.scope, first.scope)
        XCTAssertEqual(files.readCount(config), 1)
        XCTAssertNil(ClaudeCredentialStore.identity(userHome: user, home: user.appendingPathComponent("custom"), files: files))
        XCTAssertEqual(files.readCount(config), 1)
        try files.put(json(["oauthAccount": ["accountUuid": cli, "organizationUuid": organization]]), at: config)
        XCTAssertNotEqual(ClaudeCredentialStore.identity(userHome: user, home: home, files: files)?.scope, first.scope)
        XCTAssertEqual(files.readCount(config), 2)
    }

    func testDesktopConfigurationValidatesItsFileBeforeReadingAccountIdentity() throws {
        let files = Files(), config = URL(fileURLWithPath: "/synthetic/desktop/config.json"), events = Events()
        files.put(Data("{}".utf8), at: config)
        XCTAssertNil(ClaudeDesktopCredentialStore.configuration(at: config, files: files, identity: { events.append("identity"); return nil }))
        XCTAssertTrue(events.snapshot.isEmpty)
        try files.put(json(["lastKnownAccountUuid": account.uppercased(), "oauth:tokenCacheV2": Data("v10-synthetic".utf8).base64EncodedString()]), at: config)
        let value = ClaudeDesktopCredentialStore.configuration(at: config, files: files, identity: { events.append("identity"); return nil })
        XCTAssertEqual(value?.account, account)
        XCTAssertEqual(events.snapshot, ["identity"])
    }

    func testDesktopRecordsUseInjectedRootsAndRejectSymbolicEntriesAndAmbiguousRoutes() async throws {
        let files = Files(), base = URL(fileURLWithPath: "/synthetic/desktop"), home = URL(fileURLWithPath: "/synthetic/claude")
        let root = base.appendingPathComponent("claude-code-sessions/" + account), org = root.appendingPathComponent(organization)
        files.directory(root); files.directory(org)
        try files.put(json(["lastKnownAccountUuid": account]), at: base.appendingPathComponent("config.json"))
        let local = "local_dddddddd-dddd-dddd-dddd-dddddddddddd", linked = "local_eeeeeeee-eeee-eeee-eeee-eeeeeeeeeeee"
        func record(_ id: String) throws -> Data {
            try json(["sessionId": id, "cliSessionId": cli, "sshConfig": ["sshHost": "fixture", "sshPort": 2222],
                "bridgeSessionIds": ["session_synthetic-cloud"]])
        }
        try files.put(record(local), at: org.appendingPathComponent(local + ".json"))
        let linkedURL = org.appendingPathComponent(linked + ".json")
        try files.put(record(linked), at: linkedURL, regular: false)
        XCTAssertEqual(ClaudeDesktopRecords.remoteMirrorSessionIDs(claudeHome: home, defaultClaudeHome: home, directory: base, files: files), [cli])
        XCTAssertTrue(ClaudeDesktopRecords.remoteMirrorSessionIDs(claudeHome: home.appendingPathComponent("custom"), defaultClaudeHome: home, directory: base, files: files).isEmpty)
        XCTAssertEqual(ClaudeDesktopRecords.cloudSessionIDs(directory: base, files: files), ["synthetic-cloud"])
        XCTAssertEqual(files.readCount(linkedURL), 0)
        let route = ClaudeSSHRoute(hostname: "fixture", user: "synthetic", port: 2222)
        let matched = await ClaudeDesktopRecords.desktopSessionID(for: cli, sourceHostID: "remote-ssh-discovered:fixture", directory: base, files: files) { _, _ in route }
        XCTAssertEqual(matched, local)
        try files.put(record(linked), at: linkedURL)
        XCTAssertTrue(ClaudeDesktopRecords.remoteMirrorSessionIDs(claudeHome: home, defaultClaudeHome: home, directory: base, files: files).isEmpty)
        let ambiguous = await ClaudeDesktopRecords.desktopSessionID(for: cli, sourceHostID: "remote-ssh-discovered:fixture", directory: base, files: files) { _, _ in route }
        XCTAssertNil(ambiguous)
    }

    func testInjectedCredentialAndTransportCleanupKeepTheOriginalConnectionBoundary() async throws {
        let files = Files(), events = Events(), capturedAt = date, scope = String(repeating: "a", count: 64)
        let data = try json(["five_hour": ["utilization": 20, "resets_at": date.timeIntervalSince1970 + 300]])
        let value = ClaudeQuotaClient(statusLineURL: URL(fileURLWithPath: "/synthetic/absent.json"), files: files,
            credentialProvider: { .init(token: "synthetic-token", expiresAt: capturedAt.addingTimeInterval(100), plan: nil, scope: scope) },
            identityProvider: { (scope, "synthetic-org") }, transport: { request in
                (data, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
            }, now: { capturedAt }, persistVerifiedCredentials: true,
            rememberCredential: { _, _ in events.append("remember"); return true },
            finishConnectionAttempt: { events.append("finish") }, discardCredentialMemory: { events.append("discard") },
            invalidateTransport: { events.append("transport") })
        _ = try await value.readQuota()
        XCTAssertEqual(events.snapshot, ["remember", "finish"])
        await value.shutdown()
        XCTAssertEqual(events.snapshot, ["remember", "finish", "discard", "transport"])
        let web = ClaudeWebQuotaClient(cookieProvider: { nil }, metadataProvider: { .init() },
            transport: { _ in XCTFail("No request during shutdown"); throw ClaudeQuotaError.connectionFailed }, now: { capturedAt },
            invalidateTransport: { events.append("web") })
        await web.shutdown()
        let cloud = ClaudeCloudProjectMonitor(cookieProvider: { nil },
            transport: { _ in XCTFail("No request during shutdown"); throw ClaudeCloudFailure.connection }, now: { capturedAt },
            invalidateTransport: { events.append("cloud") })
        await cloud.shutdown()
        XCTAssertEqual(Array(events.snapshot.suffix(2)), ["web", "cloud"])
    }

    func testDesktopRecordReadsStopAtTheExistingFileBudget() throws {
        let files = Files(), base = URL(fileURLWithPath: "/synthetic/bounded-desktop")
        let root = base.appendingPathComponent("claude-code-sessions/" + account), org = root.appendingPathComponent(organization)
        files.directory(root); files.directory(org)
        try files.put(json(["lastKnownAccountUuid": account]), at: base.appendingPathComponent("config.json"))
        var urls: [URL] = []
        for index in 0..<129 {
            let id = "local_00000000-0000-0000-0000-" + String(format: "%012d", index)
            let url = org.appendingPathComponent(id + ".json")
            urls.append(url)
            try files.put(json(["sessionId": id, "cliSessionId": cli, "bridgeSessionIds": ["session_synthetic-\(index)"]]), at: url)
        }
        let ids = ClaudeDesktopRecords.cloudSessionIDs(directory: base, files: files)
        XCTAssertEqual(ids.count, 128)
        XCTAssertEqual(urls.reduce(0) { $0 + files.readCount($1) }, 128)
        XCTAssertFalse(ids.contains("synthetic-128"))
        XCTAssertEqual(files.readCount(urls[128]), 0)
    }
}
