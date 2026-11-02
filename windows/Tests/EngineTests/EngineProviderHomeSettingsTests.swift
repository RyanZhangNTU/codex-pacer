import Foundation
import XCTest
@testable import PacerCore

private final class ProviderHomeFrames: @unchecked Sendable {
    private let lock = NSLock()
    private var frames: [Data] = []
    func append(_ value: Data) { lock.lock(); defer { lock.unlock() }; frames.append(value) }
    func all() -> [Data] { lock.lock(); defer { lock.unlock() }; return frames }
    func report() throws -> EngineProviderHomeReport {
        struct Result: Decodable { let value: EngineProviderHomeReport }
        return try JSONDecoder().decode(Result.self, from: XCTUnwrap(all().last)).value
    }
    func error() throws -> String? {
        (try JSONSerialization.jsonObject(with: XCTUnwrap(all().last)) as? [String: Any])?["code"] as? String
    }
    func snapshots() -> [EngineSnapshot] { all().compactMap { try? JSONDecoder().decode(EngineSnapshot.self, from: $0) } }
}

final class EngineProviderHomeSettingsTests: XCTestCase {
    private func command(_ method: String, _ params: [String: Any] = [:]) throws -> Data {
        try JSONSerialization.data(withJSONObject: ["protocolVersion": 1, "id": "provider-home", "method": method, "params": params])
    }
    private func root() throws -> URL {
        let value = FileManager.default.temporaryDirectory.appendingPathComponent("pacer-provider-中文 space-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: value, withIntermediateDirectories: true)
        return value
    }
    func testInspectionNormalizesQuotedUnicodeFoldersAndRejectsFilesRelativeAndMissingPaths() throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let path = EngineCodexSourceReport.path(root), file = root.appendingPathComponent("file")
        try Data("fixture".utf8).write(to: file)
        for provider in [AgentProvider.claude, .deepseek] {
            let report = EngineProviderHomeReport.inspect(provider: provider, home: " \"" + path + "\" ", fallback: file)
            XCTAssertEqual(report.provider, provider.rawValue); XCTAssertEqual(report.home, path)
            XCTAssertEqual(report.effectiveHome, path); XCTAssertNil(report.issue); XCTAssertTrue(report.readable)
            for invalid in ["relative/home", EngineCodexSourceReport.path(file), path + "/missing"] {
                let rejected = EngineProviderHomeReport.inspect(provider: provider, home: invalid, fallback: root)
                XCTAssertNotNil(rejected.issue); XCTAssertFalse(rejected.readable)
            }
            let restored = EngineProviderHomeReport.inspect(provider: provider, home: "  ", fallback: root.appendingPathComponent("not-created"))
            XCTAssertEqual(restored.home, ""); XCTAssertNil(restored.issue); XCTAssertFalse(restored.readable)
        }
    }
    func testQueriesDoNotReconfigureSourcesAndEmptyOverridesRestoreIndependentDefaults() async throws {
        let frames = ProviderHomeFrames(), root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let runtime = EngineRuntime(demo: true, output: { frames.append($0) })
        _ = await runtime.receive(try command("initialize"))
        let before = frames.snapshots().count, path = EngineCodexSourceReport.path(root)
        var defaults: [String: String] = [:]
        for provider in ["claude", "deepseek"] {
            _ = await runtime.receive(try command("inspectProviderHome", ["provider": provider, "sourceHome": ""]))
            defaults[provider] = try frames.report().effectiveHome
            XCTAssertNil(try frames.report().issue)
            XCTAssertTrue(try frames.report().effectiveHome.lowercased().contains("demo"))
            _ = await runtime.receive(try command("inspectProviderHome", ["provider": provider, "sourceHome": path]))
            XCTAssertEqual(try frames.report().effectiveHome, path)
        }
        XCTAssertEqual(frames.snapshots().count, before, "Draft validation must not publish or start a collector")
        _ = await runtime.receive(try command("configure", ["claudeHome": path, "deepseekHome": path]))
        _ = await runtime.receive(try command("configure", ["hideProjects": true]))
        for provider in ["claude", "deepseek"] {
            _ = await runtime.receive(try command("inspectProviderHome", ["provider": provider]))
            XCTAssertEqual(try frames.report().effectiveHome, path, "An omitted source in a partial update must preserve the custom folder")
        }
        _ = await runtime.receive(try command("configure", ["claudeHome": "", "deepseekHome": ""]))
        for provider in ["claude", "deepseek"] {
            _ = await runtime.receive(try command("inspectProviderHome", ["provider": provider]))
            XCTAssertEqual(try frames.report().effectiveHome, defaults[provider])
        }
        for snapshot in frames.snapshots() {
            XCTAssertFalse(String(data: try JSONEncoder().encode(snapshot), encoding: .utf8)!.contains(path), "Routine snapshots cannot expose source paths")
        }
        await runtime.stop()
    }
    func testMalformedQueriesRequireInitializationAndCannotChangeTheSnapshot() async throws {
        let frames = ProviderHomeFrames(), runtime = EngineRuntime(demo: true, output: { frames.append($0) })
        _ = await runtime.receive(try command("inspectProviderHome", ["provider": "claude"]))
        XCTAssertEqual(try frames.error(), "initializeRequired")
        _ = await runtime.receive(try command("initialize"))
        let before = frames.snapshots().count
        for params: [String: Any] in [[:], ["provider": "codex"], ["provider": "other"], ["provider": "claude", "sourceHome": "bad\npath"],
                                      ["provider": "deepseek", "sourceHome": "bad\0path"], ["provider": "claude", "sourceHome": String(repeating: "x", count: 32769)]] {
            _ = await runtime.receive(try command("inspectProviderHome", params))
            XCTAssertEqual(try frames.error(), "invalidCommand")
        }
        XCTAssertEqual(frames.snapshots().count, before)
        await runtime.stop()
    }
    func testClaudeSourceSwitchRemovesOldTasksAndReadsOnlyTheNewFixture() async throws {
        let frames = ProviderHomeFrames(), root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let first = root.appendingPathComponent("first"), second = root.appendingPathComponent("second")
        let clock = Date(timeIntervalSince1970: 1_800_000_000)
        for (home, session) in [(first, "fixture-first"), (second, "fixture-second")] {
            try FileManager.default.createDirectory(at: home.appendingPathComponent("pacer"), withIntermediateDirectories: true)
            let record = try XCTUnwrap(ClaudeActivityRecord.encode(["kind": "prompt", "origin": "hook", "sessionId": session,
                "promptId": "fixture-turn", "at": clock.timeIntervalSince1970]))
            try (record + Data([10])).write(to: home.appendingPathComponent("pacer/events.jsonl"))
        }
        let runtime = EngineRuntime(demo: false, now: { clock }, dismissalStore: nil,
            installationDetection: { .init(codexInstalled: false, claudeInstalled: false, deepseekInstalled: false) }, output: { frames.append($0) })
        _ = await runtime.receive(try command("initialize", ["enabledProviders": ["claude"], "claudeHome": EngineCodexSourceReport.path(first)]))
        XCTAssertTrue(try XCTUnwrap(frames.snapshots().last).tasks.contains { $0.id.contains("fixture-first") })
        _ = await runtime.receive(try command("configure", ["claudeHome": EngineCodexSourceReport.path(second)]))
        let changed = try XCTUnwrap(frames.snapshots().last)
        XCTAssertTrue(changed.tasks.contains { $0.id.contains("fixture-second") })
        XCTAssertFalse(changed.tasks.contains { $0.id.contains("fixture-first") })
        XCTAssertEqual(changed.sources.filter { $0.provider == "claude" }.map(\.id), ["claude:local-logs"])
        await runtime.stop()
    }
}
