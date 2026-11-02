import Foundation

/// Read-only shell queries use the same presentation types as the Mac host.
enum EngineShellProjection {
    static let methods: Set<String> = ["projectCompactBar", "layoutQuotaChart"]
    struct Request: Decodable {
        let compact: CompactBarPresentation.Request?
        let chart: QuotaCycleChartPresentation?
        let plotWidth: Double?
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
        case "projectCompactBar":
            guard let input = request.compact, let value = CompactBarPresentation.project(input) else { return nil }
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
