import Foundation

/// Presentation only. Hiding a component never stops its underlying collector.
public struct CompactIslandLayout: Equatable, Codable, Sendable {
    public enum Component: String, CaseIterable, Codable, Sendable, Identifiable {
        case activity, status, tps, firstOutput
        case codexQuota, claudeQuota, quotaLabel, timeRemaining
        case lowQuotaWarning, quotaDelayWarning, sshWarning
        public var id: String { rawValue }
        public var label: String { L10n.text("layout.component." + rawValue) }
        public var shortLabel: String { L10n.text("layout.short." + rawValue) }
        public var provider: AgentProvider? {
            switch self {
            case .codexQuota: .codex
            case .claudeQuota: .claude
            default: nil
            }
        }
        /// Availability only affects presentation; disabled providers keep their saved positions.
        public func isAvailable(for providers: Set<AgentProvider>) -> Bool {
            if let provider { return providers.contains(provider) }
            switch self {
            case .quotaLabel, .timeRemaining, .lowQuotaWarning, .quotaDelayWarning: return !providers.isEmpty
            default: return true
            }
        }
        public var preferredLane: Lane {
            switch self {
            case .activity, .status, .tps, .firstOutput: .leading
            default: .trailing
            }
        }
        public var symbol: String {
            switch self {
            case .activity: "smallcircle.filled.circle"
            case .status: "text.alignleft"
            case .tps: "speedometer"
            case .firstOutput: "timer"
            case .codexQuota, .claudeQuota: "chart.pie"
            case .quotaLabel: "tag"
            case .timeRemaining: "hourglass"
            case .lowQuotaWarning: "gauge.with.dots.needle.33percent"
            case .quotaDelayWarning: "clock.arrow.circlepath"
            case .sshWarning: "network.slash"
            }
        }
        fileprivate static func saved(_ value: String) -> [Self] {
            switch value {
            case "statusIcon", "taskCount": [.activity]
            case "quotaMetric": [.codexQuota, .claudeQuota]
            case "quotaWindow": [.quotaLabel]
            case "resetCountdown": [.timeRemaining]
            case "quotaWarning": [.lowQuotaWarning]
            case "freshness": [.quotaDelayWarning]
            default: Self(rawValue: value).map { [$0] } ?? []
            }
        }
    }
    public enum Group: String, CaseIterable, Sendable {
        case tasks, performance, quota, warnings
        public var label: String { L10n.text("layout.group." + rawValue) }
        public var components: [Component] {
            switch self {
            case .tasks: [.activity, .status]
            case .performance: [.tps, .firstOutput]
            case .quota: [.codexQuota, .claudeQuota, .quotaLabel, .timeRemaining]
            case .warnings: [.lowQuotaWarning, .quotaDelayWarning, .sshWarning]
            }
        }
    }
    public enum Lane: String, CaseIterable, Codable, Sendable {
        case leading, trailing
        public var label: String { L10n.text("layout.lane." + rawValue) }
    }
    public static let defaultsKey = "compactIslandLayout"
    public let version = 5
    public var leading: [Component]
    public var trailing: [Component]
    public init(leading: [Component] = [], trailing: [Component] = []) {
        self.leading = leading; self.trailing = trailing
    }
    public static let standard = Self(leading: [.activity, .tps],
        trailing: [.lowQuotaWarning, .codexQuota, .claudeQuota, .quotaLabel, .quotaDelayWarning, .sshWarning])
    public subscript(_ lane: Lane) -> [Component] {
        get { lane == .leading ? leading : trailing }
        set { if lane == .leading { leading = newValue } else { trailing = newValue } }
    }
    public var components: Set<Component> { Set(leading + trailing) }
    public func visibleComponents(in lane: Lane, providers: Set<AgentProvider>) -> [Component] {
        self[lane].filter { $0.isAvailable(for: providers) }
    }
    public var normalized: Self {
        var seen: Set<Component> = []
        var result = Self()
        for lane in Lane.allCases { result[lane] = self[lane].filter { seen.insert($0).inserted } }
        return result
    }
    public static func load(from defaults: UserDefaults = .standard) -> Self {
        guard let data = defaults.data(forKey: defaultsKey), data.count <= 8192,
              let value = try? JSONDecoder().decode(Self.self, from: data) else { return .standard }
        return value.normalized
    }
    public func save(to defaults: UserDefaults = .standard) {
        if let data = try? JSONEncoder().encode(normalized) { defaults.set(data, forKey: Self.defaultsKey) }
    }
    public mutating func hide(_ component: Component) {
        for lane in Lane.allCases { self[lane].removeAll { $0 == component } }
    }
    public mutating func move(_ component: Component, to lane: Lane, before: Component? = nil) {
        guard component != before else { return }
        hide(component)
        let index = before.flatMap { self[lane].firstIndex(of: $0) } ?? self[lane].count
        self[lane].insert(component, at: index)
    }
    public mutating func shift(_ component: Component, by offset: Int, providers: Set<AgentProvider>? = nil) {
        guard let lane = Lane.allCases.first(where: { self[$0].contains(component) }),
              let index = self[lane].firstIndex(of: component) else { return }
        let positions = self[lane].indices.filter { index in
            providers.map { self[lane][index].isAvailable(for: $0) } ?? true
        }
        guard let position = positions.firstIndex(of: index) else { return }
        let target = positions[min(positions.count - 1, max(0, position + offset))]
        guard target != index else { return }
        self[lane].remove(at: index); self[lane].insert(component, at: target)
    }
    private enum CodingKeys: String, CodingKey { case version, leading, trailing, center }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let schema = try values.decode(Int.self, forKey: .version)
        guard (1...5).contains(schema) else {
            throw DecodingError.dataCorruptedError(forKey: .version, in: values, debugDescription: "Unsupported compact layout")
        }
        var leadingNames = try values.decode([String].self, forKey: .leading)
        if schema == 1 {
            leadingNames += try values.decodeIfPresent([String].self, forKey: .center) ?? []
        }
        trailing = try values.decode([String].self, forKey: .trailing).flatMap(Component.saved)
        if schema < 3, leadingNames == ["statusIcon", "status", "tps"],
           trailing == [.lowQuotaWarning, .codexQuota, .claudeQuota, .quotaLabel, .quotaDelayWarning] {
            leadingNames.insert("taskCount", at: 2)
            trailing.append(.sshWarning)
        }
        // Schema 5 merges the status icon and task count. An untouched former
        // default lane also drops status text, which stays an optional component.
        if schema < 5, leadingNames == ["statusIcon", "status", "taskCount", "tps"] {
            leadingNames = ["activity", "tps"]
        }
        leading = leadingNames.flatMap(Component.saved)
    }
    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(version, forKey: .version)
        try values.encode(leading.map(\.rawValue), forKey: .leading)
        try values.encode(trailing.map(\.rawValue), forKey: .trailing)
    }
}
