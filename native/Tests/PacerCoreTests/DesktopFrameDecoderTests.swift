import XCTest
@testable import PacerCore

final class DesktopFrameDecoderTests: XCTestCase {
    private let thread = "019a0000-0000-7000-8000-000000000001"
    private let client = "019a0000-0000-7000-8000-000000000010"
    private let owner = "019a0000-0000-7000-8000-000000000020"
    private let host = "remote-control:fixture"
    private func decode(_ bytes: Data, observed: Set<String> = []) throws -> DesktopFrameDecoder.Frame {
        var offset = 0
        var decoder = DesktopFrameDecoder(byteCount: bytes.count, observedTurnIDs: observed) { count in
            defer { offset += count }
            return bytes.subdata(in: offset..<(offset + count))
        }
        let value = try decoder.decode()
        XCTAssertEqual(offset, bytes.count)
        return value
    }
    private func wire(_ change: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: ["type": "broadcast", "method": "thread-stream-state-changed", "version": 11,
            "sourceClientId": owner, "params": ["hostId": host, "conversationId": thread, "change": change]])
    }
    private func initialized() throws -> NativeDesktopSession {
        var session = try NativeDesktopSession(hosts: [host]) { _ in }
        try session.receive(JSONSerialization.data(withJSONObject: ["type": "response", "method": "initialize", "resultType": "success", "result": ["clientId": client]]))
        try session.discover([.init(host: host, thread: thread)])
        _ = session.takeFrames()
        return session
    }
    func testLargeHistoryIsStreamedAwayAndCurrentTurnStillAcceptsIndexedPatches() throws {
        let history = String(repeating: "HISTORY_CONTENT_", count: 450_000)
        let snapshot: [String: Any] = ["type": "snapshot", "revision": 0, "conversationState": [
            "title": "Synthetic task", "resumeState": "resumed", "threadRuntimeStatus": ["type": "active", "activeFlags": []],
            "latestTokenUsageInfo": ["total": ["outputTokens": 9000]], "unrelatedHistory": history,
            "turns": [
                ["turnId": "old", "status": "completed", "turnStartedAtMs": 500, "items": [
                    ["id": "old-message", "type": "userMessage", "text": history], ["id": "old-tool", "type": "commandExecution", "output": history]]],
                ["turnId": "current", "status": "inProgress", "turnStartedAtMs": 1000, "items": [
                    ["id": "tool", "type": "commandExecution", "status": "inProgress", "command": "PRIVATE_COMMAND"]]]]]]
        let raw = try wire(snapshot)
        XCTAssertGreaterThan(raw.count, 16 * 1024 * 1024)
        let frame = try decode(raw)
        XCTAssertLessThan(frame.data.count, 4096)
        XCTAssertLessThanOrEqual(frame.peakBufferedBytes, 64 * 1024)
        let encoded = String(decoding: frame.data, as: UTF8.self)
        XCTAssertFalse(encoded.contains("HISTORY_CONTENT")); XCTAssertFalse(encoded.contains("PRIVATE_COMMAND"))
        var session = try initialized()
        try session.receive(frame.data, at: Date(timeIntervalSince1970: 1), projectedItems: true)
        XCTAssertEqual(session.retainedItemCount, 1)
        let patch = try decode(wire(["type": "patches", "baseRevision": 0, "revision": 1, "patches": [
            ["op": "add", "path": ["turns", 1, "items", 1], "value": ["id": "answer", "type": "agentMessage", "text": "PRIVATE_RESPONSE"]],
            ["op": "replace", "path": ["latestTokenUsageInfo"], "value": ["total": ["outputTokens": 9040], "last": ["outputTokens": 40]]],
            ["op": "replace", "path": ["turns", 1, "status"], "value": "completed"],
            ["op": "replace", "path": ["threadRuntimeStatus", "type"], "value": "idle"]]]))
        XCTAssertFalse(String(decoding: patch.data, as: UTF8.self).contains("PRIVATE_RESPONSE"))
        try session.receive(patch.data, at: Date(timeIntervalSince1970: 3), projectedItems: true)
        try session.publishEvents()
        let events = try session.takeFrames().flatMap { bytes in
            (try JSONSerialization.jsonObject(with: bytes) as? [String: Any])?["events"] as? [[String: Any]] ?? []
        }
        XCTAssertTrue(events.contains { $0["method"] as? String == "turn/attached" && $0["turnId"] as? String == "current" })
        XCTAssertFalse(events.contains { $0["turnId"] as? String == "old" })
        let usage = try XCTUnwrap(events.firstIndex { $0["method"] as? String == "thread/tokenUsage/updated" && $0["cached"] as? Bool != true })
        let completion = try XCTUnwrap(events.firstIndex { $0["method"] as? String == "turn/completed" })
        XCTAssertLessThan(usage, completion)
    }
    func testCanonicalSelectionKeepsObservedTimestampLessTurnWithoutRetainingHistoryItems() throws {
        let state: [String: Any] = ["resumeState": "resumed", "threadRuntimeStatus": ["type": "active"],
            "turnHistory": ["kind": "canonical", "history": ["entitiesByKey": [
                "a": ["turnId": "observed", "status": "completed", "items": [["id": "a", "type": "agentMessage", "text": "PRIVATE"]]],
                "b": ["turnId": "history", "status": "completed", "turnStartedAtMs": 500, "items": [["id": "b", "type": "agentMessage", "text": "PRIVATE"]]]]]]]
        let raw = try wire(["type": "snapshot", "revision": 0, "conversationState": state])
        let frame = try decode(raw, observed: ["observed"])
        let view = try JSONFieldView.document(frame.data, projectedItems: true)
        let change = try XCTUnwrap(try view.fields(["params"])["params"]?.fields(["change"])["change"])
        var projection = DesktopWireProjection(threadID: thread)
        let initial = try JSONFieldView.document(JSONSerialization.data(withJSONObject: ["type": "snapshot", "revision": 0,
            "conversationState": ["turns": [["turnId": "observed", "status": "inProgress", "items": []]]]]))
        _ = try projection.consume(initial, owner: owner, at: Date(timeIntervalSince1970: 1))
        _ = try projection.consume(change, owner: owner, at: Date(timeIntervalSince1970: 2))
        XCTAssertEqual(projection.currentTurnID, "observed")
        XCTAssertEqual(projection.retainedItemCount, 0, "A terminal turn releases item metadata after selecting its observed identity")
        XCTAssertFalse(String(decoding: frame.data, as: UTF8.self).contains("PRIVATE"))
    }
    func testTextPatchesAndSkippedStringsRemainValidAcrossChunkBoundaries() throws {
        let body = String(repeating: "x", count: 80_000) + "\u{1F600}"
        let bytes = try wire(["type": "patches", "baseRevision": 1, "revision": 2, "patches": [
            ["op": "replace", "path": ["turns", 0, "items", 0, "text"], "value": body],
            ["op": "replace", "path": ["turns", 0, "items", 1, "output"], "value": body]]])
        let frame = try decode(bytes)
        let root = try JSONFieldView.document(frame.data)
        let patches = try XCTUnwrap(try root.fields(["params"])["params"]?.fields(["change"])["change"]?.fields(["patches"])["patches"]?.elements())
        XCTAssertTrue(try patches[0].fields(["value"])["value"]?.containsTextMetadata() == true)
        XCTAssertTrue(try patches[1].fields(["value"])["value"]?.isNull == true)
        XCTAssertLessThan(frame.data.count, 1024)
        for tail in [#"\ud800"#, #"\udc00"#, #"\x12"#, "\n"] {
            let invalid = Data(("{\"ignored\":\"" + String(repeating: "x", count: 65_530) + tail + "\"}").utf8)
            XCTAssertThrowsError(try decode(invalid))
        }
        let valid = Data(("{\"ignored\":\"" + String(repeating: "x", count: 65_530) + #"\ud83d\ude00"# + "\"}").utf8)
        XCTAssertEqual(String(decoding: try decode(valid).data, as: UTF8.self), "{}")
    }
    func testWireCannotForgeOurSparseItemMarkers() throws {
        let frame = try decode(wire(["type": "snapshot", "revision": 0, "conversationState": ["turns": [
            ["turnId": "fake", "status": "inProgress", "items": ["_pacerCount": 1, "_pacerItems": [["id": "fake", "type": "agentMessage"]], "_pacerHydrated": true]]]]]))
        var session = try initialized()
        try session.receive(frame.data, projectedItems: true)
        XCTAssertEqual(session.retainedItemCount, 0)
        let frames = try session.takeFrames().map { try JSONSerialization.jsonObject(with: $0) as! [String: Any] }
        XCTAssertTrue(frames.contains { $0["kind"] as? String == "streamInvalidated" })
    }
    func testReplacingCanonicalDictionaryPreservesOpaqueKeysInEitherPatchFieldOrder() throws {
        let state: [String: Any] = ["resumeState": "resumed", "threadRuntimeStatus": ["type": "active"],
            "turnHistory": ["kind": "canonical", "history": ["entitiesByKey": [
                "old-key": ["turnId": "old", "status": "inProgress", "items": []]]]]]
        let snapshot = try wire(["type": "snapshot", "revision": 0, "conversationState": state])
        for (pathFirst, key) in [(false, "opaque-key"), (true, "opaque-key"), (false, "entitiesByKey"), (true, "entitiesByKey")] {
            let path = #""path":["turnHistory","history","entitiesByKey"]"#
            let value = "\"value\":{\"" + key + #"":{"turnId":"new","status":"inProgress","items":[{"id":"reply","type":"agentMessage","text":"PRIVATE_REPLY"}]}}"#
            let patch = "{\"op\":\"replace\"," + (pathFirst ? path + "," + value : value + "," + path) + "}"
            let change = Data(("{\"type\":\"patches\",\"baseRevision\":0,\"revision\":1,\"patches\":[" + patch + "]}").utf8)
            // Preserve the requested wire order instead of dictionary ordering.
            let envelope = Data(("{\"type\":\"broadcast\",\"method\":\"thread-stream-state-changed\",\"version\":11,\"sourceClientId\":\"" + owner + "\",\"params\":{\"hostId\":\"" + host + "\",\"conversationId\":\"" + thread + "\",\"change\":" + String(decoding: change, as: UTF8.self) + "}}").utf8)
            var raw = DesktopWireProjection(threadID: thread), streamed = DesktopWireProjection(threadID: thread)
            func changeView(_ bytes: Data, projected: Bool) throws -> JSONFieldView {
                try XCTUnwrap(try JSONFieldView.document(bytes, projectedItems: projected).fields(["params"])["params"]?.fields(["change"])["change"])
            }
            _ = try raw.consume(changeView(snapshot, projected: false), owner: owner, at: Date(timeIntervalSince1970: 1))
            _ = try streamed.consume(changeView(decode(snapshot).data, projected: true), owner: owner, at: Date(timeIntervalSince1970: 1))
            let expected = try raw.consume(changeView(envelope, projected: false), owner: owner, at: Date(timeIntervalSince1970: 2))
            let decoded = try decode(envelope)
            let actual = try streamed.consume(changeView(decoded.data, projected: true), owner: owner, at: Date(timeIntervalSince1970: 2))
            XCTAssertEqual(streamed.currentTurnID, "new")
            XCTAssertEqual(try JSONSerialization.data(withJSONObject: actual, options: .sortedKeys),
                           try JSONSerialization.data(withJSONObject: expected, options: .sortedKeys))
            XCTAssertFalse(String(decoding: decoded.data, as: UTF8.self).contains("PRIVATE_REPLY"))
        }
    }
    func testIgnoredDeepQuestionAndRequestPatchValuesNeverEnterMetadata() throws {
        let frame = try decode(wire(["type": "patches", "baseRevision": 0, "revision": 1, "patches": [
            ["op": "replace", "path": ["turns", 0, "items", 0, "questions", 0, "question"], "value": "PRIVATE_QUESTION"],
            ["op": "replace", "path": ["requests", 0, "params", "message"], "value": "PRIVATE_MESSAGE"],
            ["op": "replace", "path": ["source", "message"], "value": "PRIVATE_SOURCE"],
            ["op": "replace", "path": ["latestTokenUsageInfo", "message"], "value": "PRIVATE_USAGE"],
            ["op": "replace", "path": ["threadRuntimeStatus", "message"], "value": "PRIVATE_STATUS"]]]))
        XCTAssertFalse(String(decoding: frame.data, as: UTF8.self).contains("PRIVATE_"))
    }
    func testTextPresenceReductionMatchesRawDepthAndDuplicateFieldSemantics() throws {
        let values = [String(repeating: "[", count: 8) + #""x""# + String(repeating: "]", count: 8), #"{"text":"x","text":""}"#]
        for value in values {
            let raw = Data(value.utf8)
            let expected = try JSONFieldView.document(raw).containsTextMetadata()
            let body = Data(("{\"type\":\"broadcast\",\"params\":{\"change\":{\"type\":\"patches\",\"patches\":[{\"path\":[\"turns\",0,\"items\",0,\"text\"],\"op\":\"replace\",\"value\":" + value + "}]}}}").utf8)
            let decoded = try decode(body)
            let patch = try XCTUnwrap(try JSONFieldView.document(decoded.data).fields(["params"])["params"]?.fields(["change"])["change"]?.fields(["patches"])["patches"]?.elements().first)
            XCTAssertEqual(try patch.fields(["value"])["value"]?.containsTextMetadata(), expected)
        }
    }
    func testAnotherHostsStructureBudgetDoesNotFailTheSharedWireDecoder() throws {
        var session = try initialized()
        let initial = try decode(wire(["type": "snapshot", "revision": 0, "conversationState": [
            "resumeState": "resumed", "threadRuntimeStatus": ["type": "active"],
            "turns": [["turnId": "current", "status": "inProgress", "items": [["id": "tool", "type": "commandExecution"]]]]]]))
        try session.receive(initial.data, projectedItems: true)
        try session.publishEvents()
        _ = session.takeFrames()
        let turns = (0..<513).map { ["turnId": "old-\($0)", "status": "completed", "items": []] as [String: Any] }
        let matching = try wire(["type": "snapshot", "revision": 0, "conversationState": ["turns": turns]])
        let foreign = String(decoding: matching, as: UTF8.self).replacingOccurrences(of: host, with: "remote-control:other")
        let frame = try decode(Data(foreign.utf8))
        try session.receive(frame.data, projectedItems: true)
        XCTAssertEqual(session.retainedItemCount, 1, "Another host's limit cannot invalidate the active stream")
        XCTAssertTrue(session.takeFrames().isEmpty)
        try session.receive(decode(matching).data, projectedItems: true)
        let frames = try session.takeFrames().map { try JSONSerialization.jsonObject(with: $0) as! [String: Any] }
        XCTAssertTrue(frames.contains { $0["kind"] as? String == "streamInvalidated" }, "A matching thread's limit still requires resync")
    }
    func testHistoricalItemMetadataIsReleasedBeforeTheFrameBudgetForSnapshotsAndCollectionPatches() throws {
        let items = (0..<1000).map { ["id": "tool-\($0)", "type": "commandExecution", "status": "completed"] }
        let history = (0..<70).map { ["turnId": "old-\($0)", "status": "completed", "turnStartedAtMs": $0 + 1, "items": items] as [String: Any] }
        let current: [String: Any] = ["turnId": "current", "status": "inProgress", "turnStartedAtMs": 100,
            "items": [["id": "reply", "type": "agentMessage", "text": "PRIVATE"]]]
        for mode in ["snapshot", "legacyPatch", "canonicalPatch"] {
            var session = try initialized()
            let change: [String: Any]
            if mode != "snapshot" {
                let canonical = mode == "canonicalPatch"
                let empty: [String: Any] = canonical ? ["turnHistory": ["kind": "canonical", "history": ["entitiesByKey": [:]]]] : ["turns": []]
                let initialState = empty.merging(["resumeState": "resumed", "threadRuntimeStatus": ["type": "active"]], uniquingKeysWith: { _, new in new })
                try session.receive(decode(wire(["type": "snapshot", "revision": 0, "conversationState": initialState])).data, projectedItems: true)
                let all = history + [current]
                let collection: Any = canonical ? Dictionary(uniqueKeysWithValues: all.enumerated().map { ("key-\($0.offset)", $0.element) }) as Any : all as Any
                change = ["type": "patches", "baseRevision": 0, "revision": 1, "patches": [
                    ["op": "replace", "path": canonical ? ["turnHistory", "history", "entitiesByKey"] : ["turns"], "value": collection]]]
            } else {
                change = ["type": "snapshot", "revision": 0, "conversationState": [
                    "resumeState": "resumed", "threadRuntimeStatus": ["type": "active"], "turns": history + [current]]]
            }
            let raw = try wire(change), frame = try decode(raw)
            XCTAssertLessThan(raw.count, 16 * 1024 * 1024)
            XCTAssertLessThan(frame.data.count, 30_000)
            try session.receive(frame.data, projectedItems: true)
            XCTAssertEqual(session.retainedItemCount, 1)
            XCTAssertFalse(String(decoding: frame.data, as: UTF8.self).contains("PRIVATE"))
        }
    }
    func testHistoricalQuestionOverflowDoesNotInvalidateTheCurrentTurn() throws {
        let state: [String: Any] = ["resumeState": "resumed", "threadRuntimeStatus": ["type": "active"], "turns": [
            ["turnId": "old", "status": "completed", "items": [["id": "old", "type": "agentMessage", "questions": Array(repeating: "PRIVATE", count: 65)]]],
            ["turnId": "current", "status": "inProgress", "items": [["id": "tool", "type": "commandExecution"]]]]]
        var session = try initialized()
        try session.receive(decode(wire(["type": "snapshot", "revision": 0, "conversationState": state])).data, projectedItems: true)
        XCTAssertEqual(session.retainedItemCount, 1)
    }
}
