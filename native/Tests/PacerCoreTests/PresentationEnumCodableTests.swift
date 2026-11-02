import Foundation
import XCTest
@testable import PacerCore

final class PresentationEnumCodableTests: XCTestCase {
    private typealias P = CompactBarPresentation
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    private func check<T: RawRepresentable & Codable & Equatable>(_ values: [T], _ strings: [String],
                                                                  file: StaticString = #filePath, line: UInt = #line) throws where T.RawValue == String {
        XCTAssertEqual(values.map(\.rawValue), strings, file: file, line: line)
        for (value, string) in zip(values, strings) {
            let oldJSON = try encoder.encode(string)
            XCTAssertEqual(try decoder.decode(T.self, from: oldJSON), value, file: file, line: line)
            XCTAssertEqual(try encoder.encode(value), oldJSON, file: file, line: line)
            XCTAssertEqual(try decoder.decode(T.self, from: encoder.encode(value)), value, file: file, line: line)
        }
        XCTAssertThrowsError(try decoder.decode(T.self, from: Data(#""future-value""#.utf8)), file: file, line: line) {
            guard case DecodingError.dataCorrupted = $0 else {
                return XCTFail("Unknown enum strings must report dataCorrupted", file: file, line: line)
            }
        }
    }

    func testEveryCaseKeepsItsOriginalJSONStringAndRejectsUnknownStrings() throws {
        try check(CompactWarningPresentation.Item.Kind.allCases,
            ["fiveHour", "ssh", "quotaDelay", "exhausted", "lowBalance", "spike", "overBudget", "nearingBudget"])
        try check(DeepSeekAlertPresentation.Kind.allCases, ["exhausted", "lowBalance", "spike", "overBudget", "nearingBudget"])
        try check(DeepSeekConnectionPresentation.Action.allCases, ["signIn", "refresh"])
        try check(DeepSeekConnectionPresentation.Color.allCases, ["green", "secondary", "orange"])
        try check(AgentProvider.allCases, ["codex", "claude", "deepseek"])
        try check([QuotaDashboardPresentation.Verdict.spare, .steady, .fast], ["spare", "steady", "fast"])
        try check(P.SingleTask.allCases, ["stage", "count"])
        try check(P.Metric.allCases, ["remaining", "pace"])
        try check(P.RingChoice.allCases, ["", "none", "codex", "claude", "deepseek"])
    }

    private func roundTrip<T: Codable & Equatable>(_ type: T.Type, _ oldJSON: String,
                                                  file: StaticString = #filePath, line: UInt = #line) throws -> T {
        let oldBytes = Data(oldJSON.utf8), decoded = try decoder.decode(type, from: oldBytes)
        let encoded = try encoder.encode(decoded)
        XCTAssertEqual(try JSONSerialization.jsonObject(with: encoded) as? NSDictionary,
            try JSONSerialization.jsonObject(with: oldBytes) as? NSDictionary, file: file, line: line)
        XCTAssertEqual(try decoder.decode(type, from: encoded), decoded, file: file, line: line)
        return decoded
    }

    func testLegacyObjectsKeepTheirKeysValuesAndOptionalFields() throws {
        let options = try roundTrip(P.Options.self,
            #"{"singleTask":"count","metric":"pace","codexWindow":"five","claudeWindow":"auto","rings":["","deepseek"]}"#)
        XCTAssertEqual(options.singleTask, .count); XCTAssertEqual(options.metric, .pace)
        XCTAssertEqual(options.rings, [.automatic, .deepseek]); XCTAssertTrue(options.valid)
        for provider in ["codex", "claude", "deepseek"] {
            let entry = try roundTrip(P.Entry.self, "{\"provider\":\"\(provider)\",\"text\":\"43%\",\"stripText\":\"43\",\"dimmed\":false}")
            XCTAssertEqual(entry.provider.rawValue, provider)
            let ring = try roundTrip(P.Ring.self, "{\"provider\":\"\(provider)\",\"remaining\":43,\"dimmed\":true}")
            XCTAssertEqual(ring.provider, entry.provider)
            let window = try roundTrip(P.Window.self, "{\"provider\":\"\(provider)\",\"label\":\"fixture\",\"selection\":\"7d\",\"weeklyOnly\":true}")
            XCTAssertEqual(window.provider, entry.provider)
        }
        let warning = try roundTrip(CompactWarningPresentation.Item.self,
            #"{"kind":"fiveHour","provider":"codex","solid":false,"label":"5h","help":"fixture","affectedProviders":[]}"#)
        XCTAssertEqual(warning.kind, .fiveHour)
        let alert = try roundTrip(DeepSeekAlertPresentation.self,
            #"{"kind":"overBudget","budgetKind":"day","solid":true,"label":"D","help":"fixture"}"#)
        XCTAssertEqual(alert.kind, .overBudget)
        let connection = try roundTrip(DeepSeekConnectionPresentation.self,
            #"{"title":"fixture","text":"fixture","color":"orange","detectedText":"fixture","connected":false,"keyEditor":false,"showDetection":true,"action":"signIn","actionLabel":"fixture"}"#)
        XCTAssertEqual(connection.color, .orange); XCTAssertEqual(connection.action, .signIn)
        let noAction = try roundTrip(DeepSeekConnectionPresentation.self,
            #"{"title":"fixture","text":"fixture","color":"secondary","detectedText":"fixture","connected":false,"keyEditor":true,"showDetection":true}"#)
        XCTAssertNil(noAction.action); XCTAssertNil(noAction.actionLabel)
        let nullAction = try decoder.decode(DeepSeekConnectionPresentation.self, from: Data(
            #"{"title":"fixture","text":"fixture","color":"secondary","detectedText":"fixture","connected":false,"keyEditor":true,"showDetection":true,"action":null,"actionLabel":null}"#.utf8))
        XCTAssertEqual(nullAction, noAction)
    }

    func testLegacyQuotaAndBudgetVerdictsRoundTripAsStringsAndAcceptNull() throws {
        let reading = QuotaDashboardPresentation.Reading(provider: .codex, period: .weekly, snapshot: nil, now: PresentationScenarioFixtures.now)
        let period = try XCTUnwrap(PresentationScenarioFixtures.demoWallet(budget: true).daily)
        let budget = DeepSeekSoloPresentation.budget(period, at: PresentationScenarioFixtures.now)
        for verdict in [QuotaDashboardPresentation.Verdict.spare, .steady, .fast] {
            var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoder.encode(reading)) as? [String: Any])
            object["verdict"] = verdict.rawValue
            let restoredReading = try roundTrip(QuotaDashboardPresentation.Reading.self,
                String(decoding: JSONSerialization.data(withJSONObject: object), as: UTF8.self))
            XCTAssertEqual(restoredReading.verdict, verdict)
            object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoder.encode(budget)) as? [String: Any])
            object["verdict"] = verdict.rawValue
            let restoredBudget = try roundTrip(DeepSeekSoloPresentation.Budget.self,
                String(decoding: JSONSerialization.data(withJSONObject: object), as: UTF8.self))
            XCTAssertEqual(restoredBudget.verdict, verdict)
        }
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoder.encode(reading)) as? [String: Any])
        object["verdict"] = NSNull()
        XCTAssertNil(try decoder.decode(QuotaDashboardPresentation.Reading.self, from: JSONSerialization.data(withJSONObject: object)).verdict)
        object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoder.encode(budget)) as? [String: Any])
        object["verdict"] = NSNull()
        XCTAssertNil(try decoder.decode(DeepSeekSoloPresentation.Budget.self, from: JSONSerialization.data(withJSONObject: object)).verdict)
    }

    func testUnknownValuesAreRejectedAtTheirObjectFieldAndProjectionBoundary() throws {
        func rejects<T: Decodable>(_ type: T.Type, _ object: [String: Any], field: String) throws {
            let bytes = try JSONSerialization.data(withJSONObject: object)
            XCTAssertThrowsError(try decoder.decode(type, from: bytes)) {
                guard case DecodingError.dataCorrupted(let context) = $0 else { return XCTFail("Expected dataCorrupted") }
                XCTAssertEqual(context.codingPath.first?.stringValue, field)
            }
        }
        let options: [String: Any] = ["singleTask": "stage", "metric": "remaining", "codexWindow": "auto", "claudeWindow": "auto", "rings": ["", ""]]
        for (field, invalid) in [("singleTask", "future" as Any), ("metric", "future" as Any), ("rings", ["future", "none"] as Any)] {
            var changed = options; changed[field] = invalid
            try rejects(P.Options.self, changed, field: field)
            let request: [String: Any] = ["language": "en", "providers": ["codex"], "options": changed, "attached": false, "strip": false]
            XCTAssertNil(P.project(try JSONSerialization.data(withJSONObject: request)))
        }
        try rejects(P.Entry.self, ["provider": "future", "text": "fixture", "stripText": "fixture", "dimmed": false], field: "provider")
        try rejects(P.Ring.self, ["provider": "future", "dimmed": false], field: "provider")
        try rejects(P.Window.self, ["provider": "future", "label": "fixture", "selection": "7d", "weeklyOnly": false], field: "provider")
        try rejects(CompactWarningPresentation.Item.self, ["kind": "future", "solid": false, "help": "fixture", "affectedProviders": []], field: "kind")
        try rejects(DeepSeekAlertPresentation.self, ["kind": "future", "solid": false, "help": "fixture"], field: "kind")
        let connected = DeepSeekConnectionPresentation(source: .web, detected: nil, balance: nil, error: nil, refreshing: false, now: Date())
        let original = try XCTUnwrap(JSONSerialization.jsonObject(with: encoder.encode(connected)) as? [String: Any])
        for field in ["action", "color"] {
            var changed = original; changed[field] = "future"
            try rejects(DeepSeekConnectionPresentation.self, changed, field: field)
        }
        let reading = QuotaDashboardPresentation.Reading(provider: .codex, period: .weekly, snapshot: nil, now: Date())
        var changed = try XCTUnwrap(JSONSerialization.jsonObject(with: encoder.encode(reading)) as? [String: Any])
        changed["verdict"] = "future"
        try rejects(QuotaDashboardPresentation.Reading.self, changed, field: "verdict")
        let period = try XCTUnwrap(PresentationScenarioFixtures.demoWallet(budget: true).daily)
        let budget = DeepSeekSoloPresentation.budget(period, at: PresentationScenarioFixtures.now)
        changed = try XCTUnwrap(JSONSerialization.jsonObject(with: encoder.encode(budget)) as? [String: Any])
        changed["verdict"] = "future"
        try rejects(DeepSeekSoloPresentation.Budget.self, changed, field: "verdict")
    }

    func testUnknownAndMissingComponentsReturnHiddenPlaceholders() throws {
        let output = try XCTUnwrap(P.project(.init(language: "en", providers: [.codex])))
        var legacy = try XCTUnwrap(JSONSerialization.jsonObject(with: encoder.encode(output)) as? [String: Any])
        var components = try XCTUnwrap(legacy["components"] as? [[String: Any]])
        components.removeAll { ($0["id"] as? String) == "quota" }
        components[0]["id"] = "future-component"
        legacy["components"] = components
        let decoded = try decoder.decode(P.Output.self, from: JSONSerialization.data(withJSONObject: legacy))
        for component in [CompactIslandLayout.Component.quota, .activity] {
            let hidden = decoded.component(component)
            XCTAssertEqual(hidden.id, component.rawValue); XCTAssertFalse(hidden.visible)
            XCTAssertFalse(hidden.available); XCTAssertFalse(hidden.shown)
            XCTAssertNil(hidden.text); XCTAssertTrue(hidden.entries.isEmpty)
        }
        XCTAssertEqual(decoded.component(.tps), output.component(.tps))
        XCTAssertEqual(try decoder.decode(P.Output.self, from: encoder.encode(P.Output.empty)), .empty)
        let emptyLayout = try decoder.decode(CompactIslandLayout.self, from: Data(P.Output.empty.layoutJSON.utf8))
        XCTAssertTrue(emptyLayout.components.isEmpty)
        for component in CompactIslandLayout.Component.allCases { XCTAssertFalse(P.Output.empty.component(component).visible) }
    }
}
