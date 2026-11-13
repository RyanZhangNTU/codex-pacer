@testable import PacerEngineSupport
import Foundation
import XCTest
@testable import PacerCore

private final class ModuleClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value = Date()
    var now: Date { lock.lock(); defer { lock.unlock() }; return value }
    func advance(_ seconds: TimeInterval) { lock.lock(); value.addTimeInterval(seconds); lock.unlock() }
}

private actor ModuleDetector {
    var value: ProviderInstallationDetection
    private(set) var reads = 0
    init(_ value: ProviderInstallationDetection) { self.value = value }
    func read() -> ProviderInstallationDetection { reads += 1; return value }
    func replace(_ value: ProviderInstallationDetection) { self.value = value }
}
private final class ModuleSnapshots: @unchecked Sendable {
    private let lock = NSLock()
    private var latest: EngineSnapshot?
    private var error: String?
    func append(_ data: Data) {
        lock.lock(); defer { lock.unlock() }
        if let snapshot = try? JSONDecoder().decode(EngineSnapshot.self, from: data) { latest = snapshot }
        else if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any], object["type"] as? String == "error" {
            error = object["code"] as? String
        }
    }
    func snapshot() -> EngineSnapshot? { lock.lock(); defer { lock.unlock() }; return latest }
    func lastError() -> String? { lock.lock(); defer { lock.unlock() }; return error }
}

final class EngineModuleTests: XCTestCase {
    private let automatic = ["codex": "automatic", "claude": "automatic", "deepseek": "automatic"]
    private func command(_ method: String, _ parameters: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: ["protocolVersion": 1, "id": UUID().uuidString, "method": method, "params": parameters])
    }
    private func homes(_ root: URL) -> [String: Any] {
        func path(_ name: String) -> String { root.appendingPathComponent(name).withUnsafeFileSystemRepresentation { String(cString: $0!) } }
        return ["codexHome": path("codex"), "claudeHome": path("claude"), "deepseekHome": path("deepseek"), "providerModes": automatic]
    }
    func testAutomaticModesAndExplicitOverridesReachTheRealSourceSelection() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("pacer-module-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let detector = ModuleDetector(.init(codexInstalled: false, claudeInstalled: true)), capture = ModuleSnapshots()
        let runtime = EngineRuntime(demo: false, dismissalStore: nil, installationDetection: { await detector.read() }, output: { capture.append($0) })
        _ = await runtime.receive(try command("initialize", homes(root)))
        XCTAssertEqual(Set(capture.snapshot()?.sources.map(\.provider) ?? []), ["claude"])
        XCTAssertEqual(capture.snapshot()?.modules?.first { $0.provider == "codex" }, .init(provider: "codex", mode: "automatic", installed: false, enabled: false))
        _ = await runtime.receive(try command("configure", ["providerModes": ["codex": "enabled", "claude": "disabled"]]))
        XCTAssertEqual(Set(capture.snapshot()?.sources.map(\.provider) ?? []), ["codex"])
        await detector.replace(.init(codexInstalled: false, claudeInstalled: false))
        await runtime.maintenanceRefresh()
        XCTAssertEqual(capture.snapshot()?.modules?.first { $0.provider == "codex" }, .init(provider: "codex", mode: "enabled", installed: false, enabled: true))
        _ = await runtime.receive(try command("configure", ["providerModes": ["deepseek": "disabled"]]))
        let reads = await detector.reads
        await runtime.maintenanceRefresh()
        let after = await detector.reads; XCTAssertEqual(after, reads, "Explicit choices must not keep probing installed apps")
        await runtime.stop()
    }
    func testMaintenanceReevaluatesOnlyAutomaticChoicesAndUpdatesSourceMetadata() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("pacer-module-refresh-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let detector = ModuleDetector(.init(codexInstalled: true, claudeInstalled: false)), capture = ModuleSnapshots()
        let clock = ModuleClock()
        let runtime = EngineRuntime(demo: false, now: { clock.now }, dismissalStore: nil, installationDetection: { await detector.read() },
                                    output: { capture.append($0) })
        _ = await runtime.receive(try command("initialize", homes(root)))
        XCTAssertEqual(Set(capture.snapshot()?.sources.map(\.provider) ?? []), ["codex"])
        let sequence = capture.snapshot()?.sequence
        await detector.replace(.init(codexInstalled: false, claudeInstalled: true, deepseekInstalled: true))
        clock.advance(599)
        await runtime.maintenanceRefresh()
        let early = await detector.reads
        XCTAssertEqual(early, 1, "The minute maintenance tick probes installed apps at most every ten minutes")
        XCTAssertEqual(Set(capture.snapshot()?.sources.map(\.provider) ?? []), ["codex"])
        clock.advance(2)
        await runtime.maintenanceRefresh()
        XCTAssertEqual(Set(capture.snapshot()?.sources.map(\.provider) ?? []), ["claude", "deepseek"])
        XCTAssertNotEqual(capture.snapshot()?.sequence, sequence)
        XCTAssertEqual(capture.snapshot()?.modules?.first { $0.provider == "codex" }?.enabled, false)
        let reads = await detector.reads; XCTAssertEqual(reads, 2)
        await runtime.stop()
    }
    func testInvalidModesAreAtomicAndDemoNeverUsesInstalledProviders() async throws {
        let capture = ModuleSnapshots()
        let runtime = EngineRuntime(demo: true, now: { Date(timeIntervalSince1970: 1_800_000_000) },
            installationDetection: { XCTFail("Demo must remain independent of real installations"); return .init(codexInstalled: false, claudeInstalled: false) },
            output: { capture.append($0) })
        _ = await runtime.receive(try command("initialize", ["providerModes": automatic]))
        XCTAssertEqual(capture.snapshot()?.modules?.filter(\.enabled).count, 3)
        _ = await runtime.receive(try command("configure", ["providerModes": ["codex": "disabled"]]))
        let original = try XCTUnwrap(capture.snapshot())
        XCTAssertFalse(original.tasks.contains { $0.provider == "codex" })
        for parameters: [String: Any] in [
            ["providerModes": ["codex": "enable"], "hideProjects": true],
            ["providerModes": ["unknown": "automatic"], "hideProjects": true],
            ["providerModes": automatic, "enabledProviders": [] as [String], "hideProjects": true]
        ] {
            _ = await runtime.receive(try command("configure", parameters))
            XCTAssertEqual(capture.lastError(), "invalidConfiguration")
            _ = await runtime.receive(try command("refresh", [:]))
            XCTAssertEqual(capture.snapshot()?.tasks.map(\.title), original.tasks.map(\.title))
            XCTAssertEqual(capture.snapshot()?.modules, original.modules)
        }
        await runtime.stop()
    }
}
