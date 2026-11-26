import Foundation
import XCTest
import WinSDK
import WindowsInstallerSupport
@testable import PacerCore
@testable import PacerEngineSupport

final class WindowsAntigravityTests: XCTestCase {
    private func directory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("pacer-antigravity-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    private func hub(_ home: URL, pid: Int32, port: UInt16) throws -> URL {
        let daemon = home.appendingPathComponent("daemon")
        try FileManager.default.createDirectory(at: daemon, withIntermediateDirectories: true)
        let file = daemon.appendingPathComponent("hub_\(port).json")
        try JSONSerialization.data(withJSONObject: ["pid": pid, "httpPort": port, "csrfToken": "fixture"]).write(to: file)
        return file
    }

    func testHubRequiresCurrentUserSingleLinkExactProcessAndLoopbackListener() throws {
        let root = try directory(), listener = try LoopbackHTTPServer()
        defer { listener.stop() }
        let pid = Int32(GetCurrentProcessId()), port = listener.port
        let file = try hub(root, pid: pid, port: port)
        let image = try XCTUnwrap(Bundle.main.executableURL)
        let host = WindowsAntigravityLocalHost(server: { image })
        var creation = FILETIME(), exit = FILETIME(), kernel = FILETIME(), user = FILETIME()
        XCTAssertTrue(GetProcessTimes(GetCurrentProcess(), &creation, &exit, &kernel, &user))
        let started = UInt64(creation.dwHighDateTime) << 32 | UInt64(creation.dwLowDateTime)
        XCTAssertEqual(host.serverIdentity(hub: file, pid: pid, httpPort: port), "\(pid):\(started)")
        XCTAssertNil(host.serverIdentity(hub: root, pid: pid, httpPort: port))
        XCTAssertNil(WindowsAntigravityLocalHost(server: { root }).serverIdentity(hub: file, pid: pid, httpPort: port))
        let otherOwner = UnsafeMutableRawPointer.allocate(byteCount: 68, alignment: 8)
        defer { otherOwner.deallocate() }
        var length: DWORD = 68
        XCTAssertTrue(CreateWellKnownSid(WinWorldSid, nil, otherOwner, &length))
        XCTAssertThrowsError(try WindowsLocalProfileOwner.validate(otherOwner))
        let link = root.appendingPathComponent("second-link")
        XCTAssertTrue(CreateHardLinkW(WindowsFiles.wide(link), WindowsFiles.wide(file), nil))
        XCTAssertNil(host.serverIdentity(hub: file, pid: pid, httpPort: port))
        try FileManager.default.removeItem(at: link)

        // A second server in the same executable owns a different port.
        let closed = try LoopbackHTTPServer()
        let closedPort = closed.port
        closed.stop()
        XCTAssertNil(host.serverIdentity(hub: file, pid: pid, httpPort: closedPort))
    }

    func testDiscoveryFindsNewestLiveHubAmongThreeHundredStaleFiles() async throws {
        let root = try directory(), live = try LoopbackHTTPServer(), other = try LoopbackHTTPServer()
        defer { live.stop(); other.stop() }
        let pid = Int32(GetCurrentProcessId()), image = try XCTUnwrap(Bundle.main.executableURL)
        let host = WindowsAntigravityLocalHost(server: { image })
        let client = AntigravityLocalClient(home: root, io: .init(files: WindowsFileSystem(), events: WindowsActivityLogWatcher(),
                                                                  antigravity: host, now: { Date() }))
        let ports = (UInt16(2000)...2301).filter { $0 != live.port && $0 != other.port }
        for port in ports.prefix(300) { _ = try hub(root, pid: Int32.max, port: port) }
        let newest = try hub(root, pid: pid, port: live.port)
        let later = Date().addingTimeInterval(60)
        try FileManager.default.setAttributes([.modificationDate: later], ofItemAtPath: newest.path)
        let discovered = await client.discover()
        XCTAssertNotNil(discovered)

        let daemon = newest.deletingLastPathComponent()
        XCTAssertEqual(try WindowsFileSystem().entries(in: daemon, maximum: 301).count, 301)
        XCTAssertThrowsError(try WindowsFileSystem().entries(in: daemon, maximum: 300))
        let second = try hub(root, pid: pid, port: other.port)
        let recentStale = ports.prefix(31).map { daemon.appendingPathComponent("hub_\($0).json") }
        for file in recentStale { try FileManager.default.setAttributes([.modificationDate: later], ofItemAtPath: file.path) }
        try FileManager.default.setAttributes([.modificationDate: later.addingTimeInterval(-1)], ofItemAtPath: second.path)
        let unchanged = await client.discover()
        XCTAssertEqual(unchanged, discovered, "The live hub ranked 33rd must be ignored")
        try FileManager.default.removeItem(at: try XCTUnwrap(recentStale.first))
        let ambiguous = await client.discover()
        XCTAssertNil(ambiguous, "The same hub ranked 32nd makes the binding ambiguous")
    }

    func testInstallStampInvalidatesWhenEitherBinaryChangesAndDataAloneDetectsModule() throws {
        let root = try directory(), app = root.appendingPathComponent("Antigravity.exe")
        let server = root.appendingPathComponent(WindowsAntigravityInstallation.serverPath)
        try FileManager.default.createDirectory(at: server.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("Google fixture".utf8).write(to: app)
        var checks = 0
        let resolver = WindowsAntigravityInstallation { url in
            checks += 1
            return (try? Data(contentsOf: url)) == Data("Google fixture".utf8)
        }
        XCTAssertNil(resolver.resolve { [app] })
        try Data().write(to: server)
        XCTAssertNil(WindowsAntigravityInstallation().resolve { [app] }, "A text file has no product version")
        XCTAssertEqual(resolver.resolve { [app] }?.path, app.path)
        XCTAssertNotNil(resolver.resolve { XCTFail("Unchanged installation was enumerated again"); return [] })
        XCTAssertEqual(checks, 1)
        try Data([1]).write(to: server)
        XCTAssertNotNil(resolver.resolve { [app] })
        XCTAssertEqual(checks, 2)
        try Data("Foreign fixture".utf8).write(to: app)
        XCTAssertNil(resolver.resolve { [app] })
        XCTAssertNil(resolver.resolve { [server] })
        let definition = try XCTUnwrap(HarnessRegistry.localHarnesses.first { $0.descriptor.id == .antigravity })
        XCTAssertTrue(definition.platforms.contains(.windows))
        func detected() -> Bool {
            WindowsProviderInstallation.detect(userHome: root, environment: [:], applicationURLs: [.codex: [], .claude: [], .deepseek: [], .antigravity: [app]],
                systemBinDirectories: [], packageLocations: { _ in [] }, registeredHandlers: { _ in [] }).isInstalled(.antigravity)
        }
        XCTAssertFalse(detected())
        try FileManager.default.createDirectory(at: definition.defaultHome(userHome: root), withIntermediateDirectories: true)
        XCTAssertTrue(detected(), "An empty Antigravity data directory counts")
    }

    private func post(_ server: LoopbackHTTPServer, cap: Int = 32) -> Task<(Int, Data), Error> {
        Task {
            try await WindowsAntigravityLocalHost(server: { nil }).post(.init(port: server.port, path: "/fixture",
                headers: ["Content-Type": "application/json"], body: Data("{}".utf8), maximumBytes: cap))
        }
    }

    private func opened(_ server: LoopbackHTTPServer) async throws {
        let ready = try await TestWait.until { server.opened }
        XCTAssertTrue(ready)
    }

    func testLocalPostIgnoresProxyReturnsRedirectWithoutBodyAndRequestsIdentity() async throws {
        let proxy = try LoopbackHTTPServer(), server = try LoopbackHTTPServer()
        defer { proxy.stop(); server.stop() }
        let names = ["http_proxy", "https_proxy", "all_proxy", "no_proxy"]
        let original = ProcessInfo.processInfo.environment
        for name in names {
            let value = name == "no_proxy" ? "" : "http://127.0.0.1:\(proxy.port)"
            _ = SetEnvironmentVariableW(Array(name.utf16) + [0], Array(value.utf16) + [0])
        }
        defer {
            for name in names {
                let key = Array(name.utf16) + [0]
                if let old = WindowsEnvironment.value(name, in: original) { _ = SetEnvironmentVariableW(key, Array(old.utf16) + [0]) }
                else { _ = SetEnvironmentVariableW(key, nil) }
            }
        }
        let read = post(server)
        try await opened(server)
        server.respond(302, headers: ["Location": "http://127.0.0.1:\(proxy.port)/redirect", "Content-Length": "9999"])
        let (code, body) = try await read.value
        XCTAssertEqual(code, 302); XCTAssertTrue(body.isEmpty); XCTAssertFalse(proxy.opened)
        let head = try XCTUnwrap(server.requests.first)
        XCTAssertTrue(head.hasPrefix("POST /fixture HTTP/1.1"))
        XCTAssertTrue(head.lowercased().contains("\r\naccept-encoding: identity\r\n"))
    }

    func testLocalPostBoundsDeclaredAndStreamedBytesAndMapsTimeout() async throws {
        for headers in [["Content-Length": "5"], ["Transfer-Encoding": "chunked"], ["Content-Encoding": "gzip"]] {
            let server = try LoopbackHTTPServer()
            defer { server.stop() }
            let read = post(server, cap: 4)
            try await opened(server)
            server.respond(200, headers: headers)
            if headers["Transfer-Encoding"] != nil { server.send("5\r\n12345\r\n0\r\n\r\n") }
            do { _ = try await read.value; XCTFail("Accepted an oversized or compressed response") }
            catch AntigravityLocalClient.Failure.oversized {}
        }
        let exact = try LoopbackHTTPServer(), silent = try LoopbackHTTPServer()
        defer { exact.stop(); silent.stop() }
        let read = post(exact, cap: 4)
        try await opened(exact)
        exact.respond(200, headers: ["Content-Length": "4"]); exact.send("test")
        let (_, body) = try await read.value
        XCTAssertEqual(body, Data("test".utf8))
        let waiting = post(silent)
        try await opened(silent)
        do { _ = try await waiting.value; XCTFail("Expected a timeout") }
        catch let error as URLError { XCTAssertEqual(error.code, .timedOut) }
    }

    func testLocalPostTimesOutWhileBytesKeepArriving() async throws {
        let server = try LoopbackHTTPServer()
        defer { server.stop() }
        let start = GetTickCount64(), read = post(server)
        try await opened(server)
        let writer = Task {
            try await Task.sleep(nanoseconds: 1_000_000_000)
            server.respond(200, headers: ["Content-Length": "8"])
            for _ in 0..<8 {
                try await Task.sleep(nanoseconds: 500_000_000)
                guard server.send(Data([65])) else { return }
            }
        }
        defer { writer.cancel() }
        do { _ = try await read.value; XCTFail("A slow response exceeded the request deadline") }
        catch let error as URLError { XCTAssertEqual(error.code, .timedOut) }
        XCTAssertLessThan(GetTickCount64() - start, 2900, "Receiving headers must not restart the two-second deadline")
    }

    private final class Session: AntigravityLocalHost, @unchecked Sendable {
        private let lock = NSLock()
        private let reset = ISO8601DateFormatter().string(from: Date().addingTimeInterval(3600))
        private var started: Int? = 100
        actor Gate {
            private var armed = false
            private var waiter: CheckedContinuation<Void, Never>?
            var waiting: Bool { waiter != nil }
            func arm() { armed = true }
            func pauseIfArmed() async {
                guard armed else { return }
                armed = false
                await withCheckedContinuation { waiter = $0 }
            }
            func release() { waiter?.resume(); waiter = nil }
        }
        let gate = Gate()
        private var low = false
        func lowerBothGroups() { lock.withLock { low = true } }
        func replace(_ value: Int?) { lock.withLock { started = value } }
        func serverIdentity(hub: URL, pid: Int32, httpPort: UInt16) -> String? {
            lock.withLock { started.map { "\(pid):\($0)" } }
        }
        func post(_ request: AntigravityLocalRequest) async throws -> (Int, Data) {
            if request.path.hasSuffix("/GetUserStatus") {
                return (200, Data(#"{"userStatus":{"email":"user@example.invalid"}}"#.utf8))
            }
            guard request.path.hasSuffix("/RetrieveUserQuotaSummary") else { return (404, Data()) }
            await gate.pauseIfArmed()
            let fractions = lock.withLock { low ? [0.1, 0.05] : [0.8, 0.4] }
            let buckets: [[String: Any]] = zip(["gemini-5h", "3p-5h"], fractions).map { id, fraction in
                ["bucketId": id, "remainingFraction": fraction, "window": "5h", "resetTime": reset]
            }
            return (200, try JSONSerialization.data(withJSONObject: ["response": ["groups": [["buckets": buckets]]]]))
        }
    }

    func testRecycledPidRevokesOldGeneration() async throws {
        let root = try directory(), session = Session()
        _ = try hub(root, pid: 42, port: 34343)
        let client = AntigravityLocalClient(home: root, io: .init(files: WindowsFileSystem(), events: WindowsActivityLogWatcher(),
                                                                  antigravity: session, now: { Date() }))
        let discovered = await client.discover()
        let first = try XCTUnwrap(discovered)
        session.replace(101)
        do { _ = try await client.call(.quota, generation: first); XCTFail("Reused a previous process's binding") }
        catch AntigravityLocalClient.Failure.revoked {}
        let next = await client.discover()
        XCTAssertNotNil(next); XCTAssertNotEqual(first, next)
    }

    private final class Capture: @unchecked Sendable {
        private let lock = NSLock()
        private var latest: EngineSnapshot?
        private var notices: [EngineNotice] = []
        var alerts: [EngineNotice] { lock.withLock { notices } }
        var snapshot: EngineSnapshot? { lock.withLock { latest } }
        func receive(_ frame: Data) {
            XCTAssertFalse(String(decoding: frame, as: UTF8.self).contains("user@example.invalid"))
            if let value = try? JSONDecoder().decode(EngineSnapshot.self, from: frame) {
                lock.withLock { latest = value; notices += value.notices }
            }
        }
    }

    func testEngineProjectsSelectedBucketAndRetiresQuotaOnHubLoss() async throws {
        let root = try directory(), home = root.appendingPathComponent("activity"), history = root.appendingPathComponent("history")
        _ = try hub(home, pid: 42, port: 34343)
        let capture = Capture(), session = Session()
        let definition = try XCTUnwrap(HarnessRegistry.localHarnesses.first { $0.descriptor.id == .antigravity })
        let runtime = EngineRuntime(demo: false, dismissalStore: nil, antigravityHost: session, localQuotaDirectory: history,
            allowsStorageRecovery: false, localHarnessDefinitions: [definition], installationDetection: { .init(installed: [.antigravity]) },
            output: { capture.receive($0) })
        func command(_ method: String, _ params: [String: Any]) async throws {
            let data = try JSONSerialization.data(withJSONObject: ["protocolVersion": 1, "id": UUID().uuidString, "method": method,
                "supportsHarnessModules": true, "params": params])
            _ = await runtime.receive(data)
        }
        try await command("initialize", ["codexHome": root.appendingPathComponent("codex").path, "claudeHome": root.appendingPathComponent("claude").path,
            "deepseekHome": root.appendingPathComponent("deepseek").path, "harnessHomes": ["antigravity": home.path],
            "enabledProviders": ["antigravity"], "monitorSSH": false, "monitorWSL": false])
        let loaded = try await TestWait.until { capture.snapshot?.groupedQuota?.first?.buckets.count == 2 }
        XCTAssertTrue(loaded)
        func projected() -> [String]? { capture.snapshot?.quota.first(where: { $0.provider == "antigravity" })?.windows.map(\.id) }
        XCTAssertEqual(projected(), ["antigravity:gemini-5h"])
        let full = try XCTUnwrap(capture.snapshot?.groupedQuota?.first)
        XCTAssertEqual(full.buckets.map(\.id), ["gemini", "3p"]); XCTAssertEqual(full.accountScope?.count, 64)
        let key = try XCTUnwrap(definition.descriptor.quotaGroups?.defaultsKey)
        try await command("configure", ["harnessQuotaGroups": [key: "3p"]])
        XCTAssertEqual(projected(), ["antigravity:3p-5h"])
        XCTAssertEqual(capture.snapshot?.groupedQuota?.first?.buckets.map(\.id), ["gemini", "3p"])
        XCTAssertEqual(capture.snapshot?.quotaDashboard?.providers.first { $0.provider == .antigravity }?.history?.buckets.count, 2)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: history.path).contains("Antigravity"))
        let historyFolder = history.appendingPathComponent("Antigravity", isDirectory: true)
        let cache = try XCTUnwrap(FileManager.default.contentsOfDirectory(at: historyFolder, includingPropertiesForKeys: nil)
            .first { $0.lastPathComponent.hasPrefix("cycle-") && $0.pathExtension == "json" })
        let damaged = Data("damaged fixture".utf8)
        try damaged.write(to: cache)
        session.lowerBothGroups()
        try await command("refresh", [:])
        let warned = try await TestWait.until { capture.alerts.filter { $0.kind == "lowQuota" }.count == 2 }
        XCTAssertTrue(warned)
        for group in AntigravityQuotaGroup.allCases { XCTAssertTrue(capture.alerts.contains { $0.detail.contains(group.name) }) }
        await session.gate.arm()
        try await command("refresh", [:])
        let pending = try await TestWait.until { await session.gate.waiting }
        XCTAssertTrue(pending)
        session.replace(nil)
        try await command("refreshLocalHarness", ["provider": "antigravity"])
        let retired = try await TestWait.until { capture.snapshot?.groupedQuota == nil }
        XCTAssertTrue(retired); XCTAssertNil(projected())
        await session.gate.release()
        try await command("configure", ["enabledProviders": [] as [String]])
        XCTAssertNil(capture.snapshot?.groupedQuota)
        await runtime.stop()
        let backup = try XCTUnwrap(FileManager.default.contentsOfDirectory(at: historyFolder, includingPropertiesForKeys: nil)
            .first { $0.lastPathComponent.hasPrefix(cache.lastPathComponent + ".damaged-") })
        XCTAssertEqual(try Data(contentsOf: backup), damaged)
        XCTAssertNoThrow(try JSONSerialization.jsonObject(with: Data(contentsOf: cache)))
        if let files = FileManager.default.enumerator(at: history, includingPropertiesForKeys: nil) {
            for case let file as URL in files where WindowsFileSystem().metadata(file)?.isRegularFile == true {
                XCTAssertNil(try Data(contentsOf: file).range(of: Data("user@example.invalid".utf8)))
            }
        }
    }

    func testLockedPluginRemovalRetainsJournalUntilGeneratedCachesCanBeRemoved() throws {
        let profile = try directory(), reporter = profile.appendingPathComponent("pacer.exe").path
        let storage = WindowsProgressPluginStorage()
        let target = LocalHarnessProgressSetup.Target(pluginProfile: profile, reporter: reporter, enabled: true)
        let config = target.home.appendingPathComponent("config.json"), sentinel = Data("{\"fixture\":true}".utf8)
        try FileManager.default.createDirectory(at: target.home, withIntermediateDirectories: true)
        try sentinel.write(to: config)
        XCTAssertEqual(LocalHarnessProgressSetup.apply(target, storage: storage), .configured)
        let plugin = target.home.appendingPathComponent("plugins/codex-pacer")
        let caches = profile.appendingPathComponent(".gemini/antigravity")
        let mcp = caches.appendingPathComponent("mcp/" + AntigravityProgressPlugin.server)
        let data = caches.appendingPathComponent("plugin_data/codex-pacer")
        for dir in [mcp, data] { try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true) }
        try Data(#"{"properties":{"percent":{"type":"integer"}}}"#.utf8).write(to: mcp.appendingPathComponent("report_progress.json"))
        let child = Process(), input = Pipe()
        child.executableURL = URL(fileURLWithPath: try XCTUnwrap(ProcessInfo.processInfo.environment["ComSpec"] ?? ProcessInfo.processInfo.environment["COMSPEC"]))
        child.arguments = ["/d", "/q", "/c", "set /p fixture="]
        child.currentDirectoryURL = plugin
        child.standardInput = input
        try child.run()
        defer { if child.isRunning { try? input.fileHandleForWriting.close(); child.waitUntilExit() } }
        let off = LocalHarnessProgressSetup.Target(pluginProfile: profile, reporter: reporter, enabled: false)
        XCTAssertEqual(LocalHarnessProgressSetup.apply(off, storage: storage), .removalPending)
        XCTAssertFalse(storage.exists(LocalHarnessProgressSetup.flag(target.home)))
        try input.fileHandleForWriting.close()
        child.waitUntilExit()
        XCTAssertNil(LocalHarnessProgressSetup.apply(off, storage: storage))
        for dir in [plugin, mcp, data] { XCTAssertFalse(storage.exists(dir)) }

        XCTAssertEqual(LocalHarnessProgressSetup.apply(target, storage: storage), .configured)
        let runtime = profile.appendingPathComponent(WindowsCodexProgressPaths.directoryName).path
        try WindowsLocalHarnessProgressCleanup.unregister(executable: reporter, runtimeRoot: runtime, fixtureRoot: profile.path, checkOnly: true)
        XCTAssertTrue(storage.exists(plugin))
        try WindowsLocalHarnessProgressCleanup.unregister(executable: reporter, runtimeRoot: runtime, fixtureRoot: profile.path, checkOnly: false)
        XCTAssertFalse(storage.exists(plugin))
        XCTAssertEqual(try Data(contentsOf: config), sentinel)
    }
}
