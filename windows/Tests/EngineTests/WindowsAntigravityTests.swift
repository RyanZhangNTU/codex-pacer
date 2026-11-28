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
        private var fractions = [0.8, 0.4]
        func lowerBothGroups() { lock.withLock { fractions = [0.1, 0.05] } }
        func setFractions(gemini: Double, thirdParty: Double) { lock.withLock { fractions = [gemini, thirdParty] } }
        func replace(_ value: Int?) { lock.withLock { started = value } }
        func serverIdentity(hub: URL, pid: Int32, httpPort: UInt16) -> String? {
            processIdentity(pid: pid)
        }
        func hubChangeTime(_ hub: URL) -> UInt64? { 1 }
        func processIdentity(pid: Int32) -> String? {
            lock.withLock { started.map { "\(pid):\($0)" } }
        }
        func post(_ request: AntigravityLocalRequest) async throws -> (Int, Data) {
            if request.path.hasSuffix("/GetUserStatus") {
                return (200, Data(#"{"userStatus":{"email":"user@example.invalid"}}"#.utf8))
            }
            guard request.path.hasSuffix("/RetrieveUserQuotaSummary") else { return (404, Data()) }
            await gate.pauseIfArmed()
            let fractions = lock.withLock { self.fractions }
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

    /// The island's dial follows the selected group, but the bar still warns when the other group runs out.
    func testCompactWarningReadsTheUnselectedGroup() async throws {
        let root = try directory(), home = root.appendingPathComponent("activity")
        _ = try hub(home, pid: 42, port: 34343)
        let capture = Capture(), session = Session()
        session.setFractions(gemini: 0.8, thirdParty: 0)
        let definition = try XCTUnwrap(HarnessRegistry.localHarnesses.first { $0.descriptor.id == .antigravity })
        let runtime = EngineRuntime(demo: false, dismissalStore: nil, antigravityHost: session, localQuotaDirectory: root.appendingPathComponent("history"),
            allowsStorageRecovery: false, localHarnessDefinitions: [definition], installationDetection: { .init(installed: [.antigravity]) },
            output: { capture.receive($0) })
        let initialize = try JSONSerialization.data(withJSONObject: ["protocolVersion": 1, "id": "initialize", "method": "initialize",
            "supportsHarnessModules": true, "params": ["codexHome": root.appendingPathComponent("codex").path, "claudeHome": root.appendingPathComponent("claude").path,
            "deepseekHome": root.appendingPathComponent("deepseek").path, "harnessHomes": ["antigravity": home.path],
            "enabledProviders": ["antigravity"], "monitorSSH": false, "monitorWSL": false]])
        _ = await runtime.receive(initialize)
        let loaded = try await TestWait.until { capture.snapshot?.groupedQuota?.first?.buckets.count == 2 }
        XCTAssertTrue(loaded)
        XCTAssertEqual(capture.snapshot?.quota.first { $0.provider == "antigravity" }?.windows.map(\.id), ["antigravity:gemini-5h"],
                       "Gemini stays the selected group on the dial")
        let warning = try XCTUnwrap(capture.snapshot?.compactWarnings?.first { $0.kind == .fiveHour && $0.provider == "antigravity" },
                                    "An empty Claude/GPT group warns while Gemini is selected")
        XCTAssertTrue(warning.solid)
        XCTAssertTrue(warning.help.contains(AntigravityQuotaGroup.thirdParty.name))
        XCTAssertFalse(warning.help.contains(AntigravityQuotaGroup.gemini.name))
        await runtime.stop()
    }

    func testEngineProjectsSelectedBucketAndKeepsQuotaAfterHubLoss() async throws {
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
        func dashboard() -> EngineQuotaDashboard.Provider? { capture.snapshot?.quotaDashboard?.providers.first { $0.provider == .antigravity } }
        func reading() -> String? {
            capture.snapshot?.groupedQuota?.first.map { quota in
                "\(quota.capturedAt) " + quota.buckets.map { "\($0.id)=\($0.windows.first?.remainingPercent ?? -1)" }.joined(separator: ",")
            }
        }
        let lowered = try XCTUnwrap(reading())
        await session.gate.arm()
        try await command("refresh", [:])
        let pending = try await TestWait.until { await session.gate.waiting }
        XCTAssertTrue(pending)
        let loading = try await TestWait.until { dashboard()?.history?.refreshing == true }
        XCTAssertTrue(loading)
        // Closing Antigravity takes its server away, not its quota: the last
        // reading stays on screen instead of "quota unavailable".
        session.replace(nil)
        try await command("refreshLocalHarness", ["provider": "antigravity"])
        let kept = try await TestWait.until { dashboard()?.history?.refreshing == false }
        XCTAssertTrue(kept)
        XCTAssertEqual(reading(), lowered); XCTAssertEqual(projected(), ["antigravity:3p-5h"])
        XCTAssertEqual(dashboard()?.status?.state, .hidden)
        await session.gate.release()
        try await command("refresh", [:])
        XCTAssertEqual(reading(), lowered, "The closed server's late answer never replaces the kept reading")
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

    private func initializeAntigravity(_ runtime: EngineRuntime, root: URL, home: URL) async throws {
        let frame = try JSONSerialization.data(withJSONObject: ["protocolVersion": 1, "id": "initialize", "method": "initialize",
            "supportsHarnessModules": true, "params": ["codexHome": root.appendingPathComponent("codex").path,
            "claudeHome": root.appendingPathComponent("claude").path, "deepseekHome": root.appendingPathComponent("deepseek").path,
            "harnessHomes": ["antigravity": home.path], "providerModes": ["antigravity": "enabled"], "monitorSSH": false, "monitorWSL": false]])
        _ = await runtime.receive(frame)
    }

    /// Pacer started while Antigravity is closed shows the last saved reading,
    /// which then ages into the delay mark like any other module's quota.
    func testEngineRestoresLastQuotaWhileAntigravityIsClosedAndMarksItDelayed() async throws {
        let root = try directory(), home = root.appendingPathComponent("activity"), history = root.appendingPathComponent("history")
        _ = try hub(home, pid: 42, port: 34343)
        let definition = try XCTUnwrap(HarnessRegistry.localHarnesses.first { $0.descriptor.id == .antigravity })
        func runtime(_ session: Session, _ capture: Capture, at clock: @escaping @Sendable () -> Date) -> EngineRuntime {
            EngineRuntime(demo: false, now: clock, dismissalStore: nil, antigravityHost: session, localQuotaDirectory: history,
                allowsStorageRecovery: false, localHarnessDefinitions: [definition], installationDetection: { .init(installed: [.antigravity]) },
                output: { capture.receive($0) })
        }
        let open = Capture(), first = runtime(Session(), open, at: { Date() })
        try await initializeAntigravity(first, root: root, home: home)
        let loaded = try await TestWait.until { open.snapshot?.groupedQuota?.first?.buckets.count == 2 }
        XCTAssertTrue(loaded)
        let saved = try XCTUnwrap(open.snapshot?.groupedQuota?.first)
        XCTAssertNil(open.snapshot?.compactWarnings?.first { $0.kind == .quotaDelay })
        await first.stop()

        let closed = Session(); closed.replace(nil)
        let later = Date().addingTimeInterval(11 * 60), capture = Capture(), second = runtime(closed, capture, at: { later })
        try await initializeAntigravity(second, root: root, home: home)
        let restored = try await TestWait.until { capture.snapshot?.groupedQuota?.first?.capturedAt == saved.capturedAt }
        XCTAssertTrue(restored)
        XCTAssertEqual(capture.snapshot?.groupedQuota?.first?.buckets.map(\.id), ["gemini", "3p"])
        XCTAssertEqual(capture.snapshot?.quotaDashboard?.providers.first { $0.provider == .antigravity }?.status?.state, .hidden)
        let delay = try XCTUnwrap(capture.snapshot?.compactWarnings?.first { $0.kind == .quotaDelay },
                                  "Eleven minutes on, the kept reading is late like any other module's")
        XCTAssertEqual(delay.affectedProviders, ["antigravity"]); XCTAssertFalse(delay.solid)
        await second.stop()
    }

    /// The Settings guide follows "Keep in menu bar" as Antigravity saves it:
    /// a temporary file renamed over `app_storage.json`.
    func testModuleFollowsAntigravityKeepInMenuBarSetting() async throws {
        let root = try directory(), home = root.appendingPathComponent("activity")
        let folder = root.appendingPathComponent("Roaming/Antigravity", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent("app_storage.json")
        let session = Session(); session.replace(nil)
        let capture = Capture()
        let definition = try XCTUnwrap(HarnessRegistry.localHarnesses.first { $0.descriptor.id == .antigravity })
        let runtime = EngineRuntime(demo: false, dismissalStore: nil, antigravityHost: session, localQuotaDirectory: root.appendingPathComponent("history"),
            allowsStorageRecovery: false, localHarnessDefinitions: [definition], installationDetection: { .init(installed: [.antigravity]) },
            output: { capture.receive($0) }, antigravityAppSettings: { file })
        try await initializeAntigravity(runtime, root: root, home: home)
        func keepsRunning() -> Bool?? { capture.snapshot?.modules?.first { $0.provider == "antigravity" }.map(\.keepsRunningInBackground) }
        func save(_ text: String) throws {
            let temporary = folder.appendingPathComponent("app_storage.json.tmp-\(UUID().uuidString)")
            try Data(text.utf8).write(to: temporary)
            XCTAssertTrue(MoveFileExW(WindowsFiles.wide(temporary), WindowsFiles.wide(file), DWORD(MOVEFILE_REPLACE_EXISTING)))
        }
        let defaulted = try await TestWait.until { keepsRunning() == .some(false) }
        XCTAssertTrue(defaulted, "Without the file, Antigravity's Windows default quits with the window")
        try save(#"{"agy.homeGreeting.next":"x","runInBackground":"true"}"#)
        let on = try await TestWait.until { keepsRunning() == .some(true) }
        XCTAssertTrue(on)
        try save(#"{"runInBackground":"false"}"#)
        let off = try await TestWait.until { keepsRunning() == .some(false) }
        XCTAssertTrue(off, "The renamed file stays watched")
        let frame = try JSONSerialization.data(withJSONObject: ["protocolVersion": 1, "id": "off", "method": "configure",
            "supportsHarnessModules": true, "params": ["providerModes": ["antigravity": "disabled"]]])
        _ = await runtime.receive(frame)
        XCTAssertEqual(keepsRunning(), .some(nil), "A module that is off has no guide")
        await runtime.stop()
    }

    func testProgressApprovalIDsOnlyIncludeMatchingAntigravityRequests() throws {
        var sample = DemoScenario.antigravityTasks(at: Date())
        let progress = try XCTUnwrap(sample.requests.first(where: \.requestsProgressApproval))
        sample.requests.append(.init(id: "other-tool", threadID: progress.threadID, sourceHostID: nil,
                                     sourceName: nil, kind: .approval, detectedAt: Date(), provider: .antigravity))
        XCTAssertEqual(EngineModule.approvalIDs(for: .antigravity, in: sample), [progress.id])
        XCTAssertNil(EngineModule.approvalIDs(for: .workbuddy, in: sample))
        sample.requests.removeAll(where: \.requestsProgressApproval)
        XCTAssertEqual(EngineModule.approvalIDs(for: .antigravity, in: sample), [])
    }

    func testGuideDemoProjectsMissedConversationAndApprovalAtTheirStages() async throws {
        let capture = Capture()
        let date = Date(timeIntervalSinceReferenceDate: 812_345_678.25)
        let runtime = EngineRuntime(demo: true, now: { date }, dismissalStore: nil, output: { capture.receive($0) }, demoAntigravityGuide: true)
        func send(_ method: String, _ params: [String: Any]) async throws {
            let frame = try JSONSerialization.data(withJSONObject: ["protocolVersion": 1, "id": method, "method": method,
                "supportsHarnessModules": true, "params": params])
            _ = await runtime.receive(frame)
        }
        try await send("initialize", ["providerModes": ["antigravity": "enabled"]])
        let stages: [(Int, HarnessProgressGuide.Stage)] = [(0, .adding), (4, .conversationMissedTool), (1, .newConversation), (2, .allowTool), (3, .ready)]
        for (index, stage) in stages {
            try await send("demoStage", ["demoStage": index])
            let module = try XCTUnwrap(capture.snapshot?.modules?.first { $0.provider == "antigravity" })
            let guide = try XCTUnwrap(module.progressGuide)
            XCTAssertEqual(guide.stage, stage)
            XCTAssertEqual(module.progressApprovals, index == 2 ? ["demo-progress-approval"] : [])
            XCTAssertEqual(guide.floatPicture, index == 2 ? .antigravityApproval : nil)
            XCTAssertEqual(guide.picture, index == 3 ? nil : .antigravityApproval)
            if stage == .ready {
                XCTAssertNil(guide.approvalCard)
            } else {
                let card = try XCTUnwrap(guide.approvalCard)
                XCTAssertEqual(card.choices, ["Yes, allow this time", "Yes, and always allow in this conversation", "Yes, and always allow", "No"])
                XCTAssertEqual(card.noHint, "(tell the agent what to do instead)")
                XCTAssertEqual(card.skip, "Skip")
                XCTAssertEqual(card.submit, "Submit")
            }
            if stage == .conversationMissedTool {
                XCTAssertEqual(module.missedProgressConversation?.id, "demo-missed-conversation")
                XCTAssertEqual(module.missedProgressConversation?.firstInputAt, date)
            } else {
                XCTAssertNil(module.missedProgressConversation)
            }
            if stage == .newConversation || stage == .conversationMissedTool {
                let title = L10n.text(stage == .newConversation ? "progress_guide.plugin.conversation" : "progress_guide.plugin.conversation_missed_tool")
                let current = try XCTUnwrap(guide.steps.firstIndex { $0.state == .current })
                XCTAssertEqual(current, 1)
                XCTAssertEqual(guide.steps[current].title, title)
                XCTAssertNil(guide.steps[current].detail)
                XCTAssertEqual(guide.example, L10n.text("progress_guide.plugin.example"))
                XCTAssertEqual(guide.floatTitle, title)
                XCTAssertNil(guide.floatNext)
            } else {
                XCTAssertNil(guide.example)
            }
            if stage == .allowTool {
                let step = try XCTUnwrap(guide.steps.first { $0.state == .current })
                XCTAssertNotNil(step.detail)
                for title in [step.title, try XCTUnwrap(guide.floatTitle)] {
                    let choice = try XCTUnwrap(title.range(of: "Yes, and always allow"))
                    let submit = try XCTUnwrap(title.range(of: "Submit"))
                    XCTAssertLessThan(choice.upperBound, submit.lowerBound)
                }
            }
        }
        await runtime.stop()
    }

    private func inspectGrants(profile: URL, allow: [String], deny: [String]) async throws -> LocalHarnessProgressSetup.State? {
        let target = LocalHarnessProgressSetup.Target(pluginProfile: profile, reporter: profile.appendingPathComponent("pacer.exe").path, enabled: true)
        let storage = WindowsProgressPluginStorage(profile: profile)
        XCTAssertEqual(LocalHarnessProgressSetup.apply(target, storage: storage), .configured)
        let data = try JSONSerialization.data(withJSONObject: ["userSettings": ["globalPermissionGrants": ["allow": allow, "deny": deny]]])
        try data.write(to: target.home.appendingPathComponent("config.json"))
        var queue = ProgressSetupQueue<LocalHarnessProgressSetup.Target>()
        let ticket = try XCTUnwrap(queue.request(target))
        return await LocalHarnessProgressSetup.sync(ticket, storage: storage, inspectOnly: true,
            prepare: { _ in XCTFail("Inspection must reuse the installed reporter"); return nil }, owns: { _, _, _ in true })
    }

    func testInspectReadsOnlyEffectiveProgressGrantsFromTemporaryProfile() async throws {
        let profile = try directory(), grant = "mcp(codex-pacer_pacer_progress/report_progress)"
        let cases: [([String], [String], LocalHarnessProgressConnection?)] = [
            ([grant], [], .trusted),
            (["mcp(codex-pacer_pacer_progress/*)"], [], .trusted),
            (["mcp(*)"], [grant], .needsTrust),
            ([grant], ["mcp(*)"], .needsTrust),
            (["mcp(codex-pacer_pacer_progress/report_progress_extra)"], [], nil)
        ]
        for (allow, deny, expected) in cases {
            let state = try await inspectGrants(profile: profile, allow: allow, deny: deny)
            XCTAssertEqual(state?.setup, .configured)
            XCTAssertEqual(state?.connection, expected)
        }
    }

    func testInspectReadsUserOwnedConfigUnderAdministratorsOwnedProfile() async throws {
        let profile = try directory()
        let admin = UnsafeMutableRawPointer.allocate(byteCount: 68, alignment: MemoryLayout<UInt64>.alignment)
        defer { admin.deallocate() }
        var size: DWORD = 68
        XCTAssertTrue(CreateWellKnownSid(WinBuiltinAdministratorsSid, nil, admin, &size))
        var path = WindowsLocalProfileStorage.wide(profile)
        let result = SetNamedSecurityInfoW(&path, SE_FILE_OBJECT, DWORD(OWNER_SECURITY_INFORMATION), admin, nil, nil, nil)
        if result == ERROR_INVALID_OWNER || result == ERROR_PRIVILEGE_NOT_HELD || result == ERROR_ACCESS_DENIED {
            throw XCTSkip("This token cannot assign the temporary profile to Administrators.")
        }
        XCTAssertEqual(result, DWORD(ERROR_SUCCESS))
        let state = try await inspectGrants(profile: profile, allow: ["mcp(codex-pacer_pacer_progress/report_progress)"], deny: [])
        XCTAssertEqual(state?.setup, .configured)
        XCTAssertEqual(state?.connection, .trusted)
    }

    /// Windows often gives the profile folder to Administrators or SYSTEM; the
    /// plugin's root must not need the user as owner, while a folder below it does.
    func testPluginRootAcceptsTheProfileFolderWhateverItsOwner() throws {
        let home = FileManager.default.homeDirectoryForCurrentUser
        XCTAssertNoThrow(try WindowsProgressPluginStorage().validate(home))
        XCTAssertNoThrow(try WindowsProgressPluginStorage(profile: home).validate(home.appendingPathComponent(".gemini-pacer-missing")))
        let other = try directory()
        XCTAssertNoThrow(try WindowsProgressPluginStorage(profile: other).validate(other))
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
        // As Antigravity 2.35.2 writes them: the tool's schema and the server's instructions.
        try Data(#"{"name":"report_progress","parameters":{"additionalProperties":false,"properties":{"percent":{"maximum":100,"minimum":0,"type":"integer"}},"required":["percent"],"type":"object"}}"#.utf8)
            .write(to: mcp.appendingPathComponent("report_progress.json"))
        try Data(ProgressPrompt.toolDescription.utf8).write(to: mcp.appendingPathComponent("instructions.md"))
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
