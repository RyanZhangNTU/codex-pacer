import Foundation
import CryptoKit
import PacerCore

/// Read-only shell queries use the same presentation types as the Mac host.
enum EngineShellProjection {
    static let methods: Set<String> = ["projectCompactBar", "projectExpandedPanel", "layoutQuotaChart", "validatePreferences", "guidePages"]
    struct Request: Decodable {
        let preferences: String?
        let compact: CompactBarPresentation.Request?
        let panel: ExpandedPanelPresentation.Request?
        let chart: QuotaCycleChartPresentation?
        let plotWidth: Double?
        let guide: EngineGuidePages.Request?
    }
    private struct PreferencesReply: Encodable {
        let digest: String
        let layoutJSON: String
        let warnings: [String]
    }
    private struct Reply<Value: Encodable>: Encodable {
        let protocolVersion = EngineProtocol.version
        let type = "result", ok = true
        let id: String
        let value: Value
    }
    static func reply(_ command: EngineCommand) -> Data? {
        guard let request = command.params?.shell else { return nil }
        func encode<T: Encodable>(_ value: T) -> Data? {
            guard let data = try? JSONEncoder().encode(Reply(id: command.id, value: value)),
                  data.count <= EngineProtocol.maximumSnapshotBytes else { return nil }
            return data
        }
        switch command.method {
        case "validatePreferences":
            guard let json = request.preferences, json.utf8.count <= 60 * 1024,
                  let data = json.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  object["schemaVersion"] as? Int == 1, object.count <= 96,
                  let input = request.compact, input.action == nil, input.context == nil,
                  let value = CompactBarPresentation.project(input) else { return nil }
            let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            return encode(PreferencesReply(digest: digest, layoutJSON: value.layoutJSON, warnings: value.warnings))
        case "guidePages":
            guard let guide = request.guide, let value = EngineGuidePages.project(guide) else { return nil }
            return encode(value)
        case "projectCompactBar":
            guard let input = request.compact, let value = CompactBarPresentation.project(input) else { return nil }
            return encode(value)
        case "projectExpandedPanel":
            guard let input = request.panel, let value = ExpandedPanelPresentation.project(input) else { return nil }
            return encode(value)
        case "layoutQuotaChart":
            guard let chart = request.chart, let width = request.plotWidth, width.isFinite, (43...10000).contains(width),
                  AppLanguage(rawValue: chart.language) != nil, chart.points.count <= 240, chart.expiries.count <= 4096,
                  chart.startedAt.isFinite, chart.resetsAt.isFinite, chart.resetsAt > chart.startedAt,
                  chart.expiries.allSatisfy({ $0.timestamp.isFinite && $0.fraction.isFinite && (0...1).contains($0.fraction)
                      && (1...1000000).contains($0.count) }),
                  chart.expiries.reduce(0, { $0 + $1.count }) <= 1000000 else { return nil }
            return encode(chart.markers(plotWidth: width))
        default: return nil
        }
    }
}
