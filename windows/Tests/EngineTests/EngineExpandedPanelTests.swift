import Foundation
import XCTest
@testable import PacerCore
@testable import PacerEngineSupport

final class EngineExpandedPanelTests: XCTestCase {
    private final class Frames: @unchecked Sendable {
        let lock = NSLock()
        var values: [EngineSnapshot] = []
        var errors: [String] = []
        func append(_ data: Data) {
            lock.lock(); defer { lock.unlock() }
            if let value = try? JSONDecoder().decode(EngineSnapshot.self, from: data) { values.append(value); return }
            if let reply = try? JSONSerialization.jsonObject(with: data) as? [String: Any], reply["type"] as? String == "error",
               let id = reply["id"] as? String { errors.append(id) }
        }
        var last: EngineSnapshot? { lock.lock(); defer { lock.unlock() }; return values.last }
        func failed(_ id: String) -> Bool { lock.lock(); defer { lock.unlock() }; return errors.contains(id) }
    }
    private func command(_ method: String, _ params: [String: Any] = [:], id: String = UUID().uuidString) throws -> Data {
        try JSONSerialization.data(withJSONObject: ["protocolVersion": 1, "id": id, "method": method, "params": params])
    }

    func testSnapshotCarriesSectionsOptionsAndPageSizeFromConfiguration() async throws {
        let frames = Frames(), now = Date()
        let runtime = EngineRuntime(demo: true, now: { now }, output: { frames.append($0) })
        _ = await runtime.receive(try command("initialize", ["enabledProviders": ["codex", "claude"]]))
        try await TestWait.until { frames.last?.expandedPanel != nil }
        let automatic = try XCTUnwrap(frames.last?.expandedPanel)
        XCTAssertEqual(automatic.sections.map(\.kind), ["tasks", "quota"], "Without a saved layout the panel stays as it was")
        XCTAssertEqual(automatic.sections.first?.actions, true)
        XCTAssertEqual(automatic.sections.last?.providers, [.codex, .claude])
        XCTAssertNotNil(automatic.sections.last?.split); XCTAssertNotNil(automatic.sections.last?.classic)
        XCTAssertEqual(automatic.gauges.map(\.provider), [.codex, .claude])
        XCTAssertEqual(frames.last?.presentation.pageSize, 3)

        var options = ExpandedPanelOptions(); options.quotaArrange = .stack; options.pageSize = 5; options.claudePeriods = .weekly
        let layout = ExpandedPanelLayout(blocks: [.claude, .tasks, .codex]).json
        _ = await runtime.receive(try command("configure", ["expandedPanel": ["layout": layout, "options": options.json, "deepseekDetailed": true]]))
        try await TestWait.until { frames.last?.expandedPanel?.sections.count == 3 }
        let chosen = try XCTUnwrap(frames.last?.expandedPanel)
        XCTAssertEqual(chosen.sections.map(\.providers), [[.claude], [], [.codex]])
        XCTAssertEqual(chosen.sections.map(\.actions), [true, false, false], "The first section carries the buttons")
        XCTAssertEqual(chosen.sections.first?.title, L10n.text("layout.group.quota")); XCTAssertEqual(chosen.sections.first?.detail, "Claude")
        XCTAssertEqual(chosen.gauges.last, .init(provider: .claude, period: .weekly, split: false))
        XCTAssertEqual(chosen.options, options)
        XCTAssertEqual(frames.last?.presentation.pageSize, 5)

        let oversized = String(repeating: " ", count: ExpandedPanelLayout.byteLimit + 1)
        _ = await runtime.receive(try command("configure", ["expandedPanel": ["layout": oversized]], id: "oversized-panel"))
        try await TestWait.until { frames.failed("oversized-panel") }
        _ = await runtime.receive(try command("configure", ["hideProjects": true]))
        try await TestWait.until { frames.last?.expandedPanel?.sections.count == 3 }
        XCTAssertEqual(frames.last?.expandedPanel?.options, options, "Leaving the group out keeps the panel")
    }

    func testEditorQueryAppliesSharedEditsWithoutEchoingInput() throws {
        let request = ExpandedPanelPresentation.Request(providers: [.codex, .deepseek], deepseekDetailed: true, language: "en",
            action: .init(kind: "toggle", block: "deepseekWeek"))
        var shell = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(request)) as? [String: Any])
        shell["privateContent"] = "PRIVATE synthetic content"
        let wire: [String: Any] = ["protocolVersion": 1, "id": "synthetic-panel", "method": "projectExpandedPanel", "params": ["shell": ["panel": shell]]]
        XCTAssertTrue(EngineShellProjection.methods.contains("projectExpandedPanel"))
        let bytes = try XCTUnwrap(EngineShellProjection.reply(EngineCommand.decode(JSONSerialization.data(withJSONObject: wire))))
        XCTAssertFalse(String(decoding: bytes, as: UTF8.self).contains("PRIVATE"))
        let reply = try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        let value = try XCTUnwrap(reply["value"] as? [String: Any])
        XCTAssertEqual(value["visible"] as? [String], ["tasks", "codex", "deepseek", "deepseekWeek"])
        XCTAssertEqual(value["layoutJSON"] as? String, #"{"blocks":["tasks","codex","claude","deepseek","deepseekWeek"],"version":1}"#)
        var bad = wire; bad["params"] = ["shell": ["panel": ["providers": ["codex"], "deepseekDetailed": true, "hasBudget": false, "language": "en",
            "action": ["kind": "toggle", "block": "future"]]]]
        XCTAssertNil(EngineShellProjection.reply(try EngineCommand.decode(JSONSerialization.data(withJSONObject: bad))))
    }
}
