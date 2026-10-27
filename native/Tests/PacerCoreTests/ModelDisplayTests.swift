import XCTest
@testable import PacerCore

final class ModelDisplayTests: XCTestCase {
    private let session = "019a0000-0000-7000-8000-0000000000b1"

    func testDisplayNamesShortenKnownFamiliesAndKeepUnknownIdentifiers() {
        XCTAssertEqual(ModelDisplay.name("claude-opus-5-5"), "Opus 5.5")
        XCTAssertEqual(ModelDisplay.name("claude-opus-5-5[1m]"), "Opus 5.5", "A context variant is not part of the name")
        XCTAssertEqual(ModelDisplay.name("claude-sonnet-4"), "Sonnet 4")
        XCTAssertEqual(ModelDisplay.name("claude-haiku-4-5-20251001"), "Haiku 4.5", "Snapshot dates are dropped")
        XCTAssertEqual(ModelDisplay.name("claude-3-5-sonnet-20241022"), "Sonnet 3.5", "Older Claude ids put the version first")
        XCTAssertEqual(ModelDisplay.name("gpt-6.1-sol"), "GPT-6.1 Sol")
        XCTAssertEqual(ModelDisplay.name("gpt-5.1-codex-max"), "GPT-5.1 Codex Max")
        XCTAssertEqual(ModelDisplay.name("gpt-5-mini"), "GPT-5 mini")
        XCTAssertEqual(ModelDisplay.name("gpt-4o"), "GPT-4o")
        for raw in ["gpt-oss-120b", "o4-mini", "qwen3-coder:30b", "claude-next", "claude-opus-2026-01"] {
            XCTAssertEqual(ModelDisplay.name(raw), raw, "Unrecognized ids stay as reported")
        }
    }

    func testEffortLabelsAreLocalizedAndOnlyBoundedTokensSurvive() {
        XCTAssertEqual(ModelDisplay.effortLabel("xhigh", language: .english), "XHigh")
        XCTAssertEqual(ModelDisplay.effortLabel("xhigh", language: .simplifiedChinese), "极高")
        XCTAssertEqual(ModelDisplay.effortLabel("minimal", language: .simplifiedChinese), "极低")
        XCTAssertEqual(ModelDisplay.effortLabel("max", language: .simplifiedChinese), "Max")
        XCTAssertNil(ModelDisplay.effortLabel("none"), "A model without an effort shows only its name")
        XCTAssertEqual(ModelDisplay.effortLabel("turbo"), "turbo", "A future level is shown as reported")
        XCTAssertEqual(ModelDisplay.sanitizedEffort("XHigh"), "xhigh")
        for raw: Any in [NSNull(), 3, "", "x high", String(repeating: "a", count: 33), "<b>"] {
            XCTAssertNil(ModelDisplay.sanitizedEffort(raw))
        }
        XCTAssertNil(ModelDisplay.sanitizedModel("<synthetic>"))
        XCTAssertNil(ModelDisplay.sanitizedModel(" "))
    }

    func testCodexTurnContextCarriesEffortAndSshProjectionAgrees() throws {
        let contexts: [[String: Any]] = [
            ["model": "gpt-6.1-sol", "effort": "xhigh"],
            ["model": "gpt-6.1-sol"],
            ["model": "gpt-6.1-terra"],
            ["model": "gpt-6.1-terra", "effort": "high"],
            ["model": "gpt-6.1-terra", "effort": NSNull()]
        ]
        let fixtures: [[String: Any]] = contexts.enumerated().map { index, values in
            ["type": "turn_context", "timestamp": "2026-10-27T00:00:0\(index)Z",
             "payload": values.merging(["turn_id": "turn-\(index)", "cwd": "/fixture", "developer_instructions": "PRIVATE"]) { old, _ in old }]
        }
        let input = try JSONSerialization.data(withJSONObject: fixtures).base64EncodedString()
        let output = try python(SessionLogProbe.library + "\nprint(json.dumps([sanitize(v) for v in json.loads(base64.b64decode('" + input + "').decode())]))")
        XCTAssertFalse(output.contains("PRIVATE"))
        let reduced = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(output.utf8)) as? [[String: Any]])
        var native = SessionActivity(id: session), ssh = SessionActivity(id: session)
        var observed: [[String?]] = []
        for (raw, projected) in zip(fixtures, reduced) {
            native.consume(try JSONSerialization.data(withJSONObject: raw))
            ssh.consume(try JSONSerialization.data(withJSONObject: projected))
            XCTAssertEqual(ssh.modelName, native.modelName); XCTAssertEqual(ssh.reasoningEffort, native.reasoningEffort)
            observed.append([native.modelName, native.reasoningEffort])
        }
        XCTAssertEqual(observed, [["gpt-6.1-sol", "xhigh"], ["gpt-6.1-sol", "xhigh"], ["gpt-6.1-terra", nil],
                                  ["gpt-6.1-terra", "high"], ["gpt-6.1-terra", nil]],
                       "An unreported effort is kept for the same model only; an explicit null clears it")
    }

    func testRuntimeMetadataUpdatesEffortAndMergedSourcesFillOnlyTheSameModel() {
        var streamed = SessionActivity(id: session, sessionID: session)
        func metadata(_ values: [String: Any]) {
            streamed.applyRuntime(["method": "metadata", "threadId": session, "at": 1_800_000_000.0].merging(values) { _, new in new })
        }
        metadata(["model": "gpt-6.1-sol", "reasoningEffort": "max"])
        XCTAssertEqual(streamed.reasoningEffort, "max")
        metadata(["name": "Renamed"])
        XCTAssertEqual(streamed.reasoningEffort, "max", "Metadata without a model leaves both alone")
        metadata(["model": "<synthetic>", "reasoningEffort": "low"])
        XCTAssertEqual(streamed.modelName, "gpt-6.1-sol"); XCTAssertEqual(streamed.reasoningEffort, "max")
        metadata(["model": "gpt-6.1-sol", "reasoningEffort": NSNull()])
        XCTAssertNil(streamed.reasoningEffort)

        var logged = SessionActivity(id: session, sessionID: session)
        logged.applyRuntime(["method": "metadata", "threadId": session, "at": 1_800_000_000.0, "model": "gpt-6.1-sol", "reasoningEffort": "high"])
        var desktop = SessionActivity(id: session, sessionID: session)
        desktop.applyRuntime(["method": "metadata", "threadId": session, "at": 1_800_000_000.0, "model": "gpt-6.1-sol"])
        desktop.mergeDisplayMetadata(from: logged)
        XCTAssertEqual(desktop.reasoningEffort, "high")
        var switched = SessionActivity(id: session, sessionID: session)
        switched.applyRuntime(["method": "metadata", "threadId": session, "at": 1_800_000_000.0, "model": "gpt-6.1-terra"])
        switched.mergeDisplayMetadata(from: logged)
        XCTAssertNil(switched.reasoningEffort, "Another model's effort is never borrowed")
        var unnamed = SessionActivity(id: session, sessionID: session)
        unnamed.mergeDisplayMetadata(from: logged)
        XCTAssertEqual(unnamed.modelName, "gpt-6.1-sol"); XCTAssertEqual(unnamed.reasoningEffort, "high")
    }

    private func python(_ script: String) throws -> String {
        let process = Process(), output = Pipe(), error = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = ["-u", "-c", script, Data("/private/tmp/pacer-no-user-data".utf8).base64EncodedString()]
        process.standardOutput = output; process.standardError = error
        try process.run(); let result = output.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, String(decoding: error.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self))
        return String(decoding: result, as: UTF8.self)
    }
}
