import Foundation
import XCTest
@testable import PacerCore

final class EngineShellProjectionTests: XCTestCase {
    private func envelope(_ input: CompactBarPresentation.Request) throws -> [String: Any] {
        let value = try JSONSerialization.jsonObject(with: JSONEncoder().encode(input))
        return ["protocolVersion": 1, "id": "synthetic-projection", "method": "projectCompactBar",
                "params": ["shell": ["compact": value]]]
    }
    private func decode(_ value: [String: Any]) throws -> EngineCommand {
        try EngineCommand.decode(JSONSerialization.data(withJSONObject: value))
    }
    func testCompactQueryReturnsSharedLayoutWithoutEchoingUnknownInput() throws {
        let input = CompactBarPresentation.Request(providers: [.codex], action: .init(kind: "hide", component: "tps"))
        var wire = try envelope(input)
        wire["privateContent"] = "PRIVATE synthetic content"
        let bytes = try XCTUnwrap(EngineShellProjection.reply(decode(wire)))
        let reply = try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        XCTAssertEqual(reply["id"] as? String, "synthetic-projection")
        XCTAssertEqual(reply["protocolVersion"] as? Int, 1)
        XCTAssertEqual(reply["type"] as? String, "result")
        XCTAssertEqual(reply["ok"] as? Bool, true)
        let value = try JSONSerialization.data(withJSONObject: XCTUnwrap(reply["value"]))
        let output = try JSONDecoder().decode(CompactBarPresentation.Output.self, from: value)
        XCTAssertFalse((output.editorLeading + output.editorTrailing).contains("tps"))
        XCTAssertNoThrow(try JSONDecoder().decode(CompactIslandLayout.self, from: Data(output.layoutJSON.utf8)))
        XCTAssertNil(input.layout, "A projection edit cannot mutate the caller's saved layout")
        XCTAssertFalse(String(decoding: bytes, as: UTF8.self).contains("PRIVATE synthetic content"))
    }
    func testUnknownPresentationOptionsAndOversizeCommandsAreRejected() throws {
        var wire = try envelope(.init(providers: [.codex]))
        var params = try XCTUnwrap(wire["params"] as? [String: Any])
        var shell = try XCTUnwrap(params["shell"] as? [String: Any])
        var compact = try XCTUnwrap(shell["compact"] as? [String: Any])
        var options = try XCTUnwrap(compact["options"] as? [String: Any])
        options["metric"] = "unknown"; compact["options"] = options; shell["compact"] = compact
        params["shell"] = shell; wire["params"] = params
        XCTAssertThrowsError(try decode(wire))
        XCTAssertThrowsError(try EngineCommand.decode(Data(repeating: 32, count: EngineProtocol.maximumCommandBytes + 1)))
    }
    func testMissingAndUnsupportedPresentationQueriesFailSafely() throws {
        let command = try decode(["protocolVersion": 1, "id": "synthetic", "method": "projectCompactBar"])
        XCTAssertNil(EngineShellProjection.reply(command))
        let unsupported = try decode(["protocolVersion": 1, "id": "synthetic", "method": "unknownProjection"])
        XCTAssertFalse(EngineShellProjection.methods.contains(unsupported.method))
        XCTAssertNil(EngineShellProjection.reply(unsupported))
    }
    func testPreferenceAcknowledgementBindsCompletePayloadWithoutEchoingIt() throws {
        var wire = try envelope(.init(layout: "{\"version\":9,\"leading\":[],\"trailing\":[]}", providers: [.codex]))
        wire["method"] = "validatePreferences"
        var params = try XCTUnwrap(wire["params"] as? [String: Any]), shell = try XCTUnwrap(params["shell"] as? [String: Any])
        shell["preferences"] = "{\"schemaVersion\":1,\"privateSyntheticField\":\"SYNTHETIC_NOT_ECHOED\"}"
        params["shell"] = shell; wire["params"] = params
        let data = try XCTUnwrap(EngineShellProjection.reply(decode(wire)))
        let result = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let value = try XCTUnwrap(result["value"] as? [String: Any]), digest = try XCTUnwrap(value["digest"] as? String)
        XCTAssertEqual(digest.count, 64); XCTAssertTrue(digest.allSatisfy { $0.isNumber || ("a"..."f").contains(String($0)) })
        XCTAssertNoThrow(try JSONDecoder().decode(CompactIslandLayout.self, from: Data(try XCTUnwrap(value["layoutJSON"] as? String).utf8)))
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("SYNTHETIC_NOT_ECHOED"))
        shell["preferences"] = "{\"schemaVersion\":1,\"privateSyntheticField\":\"OTHER_SYNTHETIC\"}"
        params["shell"] = shell; wire["params"] = params
        let other = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(EngineShellProjection.reply(decode(wire)))) as? [String: Any])
        XCTAssertNotEqual((other["value"] as? [String: Any])?["digest"] as? String, digest)
    }
    func testMalformedOrFuturePreferenceAcknowledgementFailsWithoutChangingProjection() throws {
        for json in ["not JSON", "[]", "{}", "{\"schemaVersion\":999}"] {
            var wire = try envelope(.init(providers: [.codex])); wire["method"] = "validatePreferences"
            var params = try XCTUnwrap(wire["params"] as? [String: Any]), shell = try XCTUnwrap(params["shell"] as? [String: Any])
            shell["preferences"] = json; params["shell"] = shell; wire["params"] = params
            XCTAssertNil(EngineShellProjection.reply(try decode(wire)))
        }
    }

}
