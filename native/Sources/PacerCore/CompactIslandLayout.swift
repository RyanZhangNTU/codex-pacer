import Foundation

/// Presentation only. Hiding a component never stops its underlying collector.
public struct CompactIslandLayout: Equatable, Codable, Sendable {
    public enum Component: String, CaseIterable, Codable, Sendable, Identifiable {
        case statusIcon, status, taskCount, tps, firstOutput
        case quotaMetric, quotaLabel, timeRemaining
        case lowQuotaWarning, quotaDelayWarning, sshWarning
        public var id: String { rawValue }
        public var label: String { L10n.text("layout.component." + rawValue) }
        public var shortLabel: String { L10n.text("layout.short." + rawValue) }
        public var preferredLane: Lane {
            switch self {
            case .statusIcon, .status, .taskCount, .tps, .firstOutput: .leading
            default: .trailing
            }
        }
        public var symbol: String {
            switch self {
            case .statusIcon: "sparkle"
            case .status: "text.alignleft"
            case .taskCount: "number.circle"
            case .tps: "speedometer"
            case .firstOutput: "timer"
            case .quotaMetric: "chart.pie"
            case .quotaLabel: "tag"
            case .timeRemaining: "hourglass"
            case .lowQuotaWarning: "gauge.with.dots.needle.33percent"
            case .quotaDelayWarning: "clock.arrow.circlepath"
            case .sshWarning: "network.slash"
            }
        }
        fileprivate static func saved(_ value: String) -> Self? {
            switch value {
            case "quotaWindow": .quotaLabel
            case "resetCountdown": .timeRemaining
            case "quotaWarning": .lowQuotaWarning
            case "freshness": .quotaDelayWarning
            default: Self(rawValue: value)
            }
        }
    }
    public enum Group: String, CaseIterable, Sendable {
        case tasks, performance, quota, warnings
        public var label: String { L10n.text("layout.group." + rawValue) }
        public var components: [Component] {
            switch self {
            case .tasks: [.statusIcon, .status, .taskCount]
            case .performance: [.tps, .firstOutput]
            case .quota: [.quotaMetric, .quotaLabel, .timeRemaining]
            case .warnings: [.lowQuotaWarning, .quotaDelayWarning, .sshWarning]
            }
        }
    }
    public enum Lane: String, CaseIterable, Codable, Sendable {
        case leading, trailing
        public var label: String { L10n.text("layout.lane." + rawValue) }
    }
    public static let defaultsKey = "compactIslandLayout"
    public let version = 3
    public var leading: [Component]
    public var trailing: [Component]
    public init(leading: [Component] = [], trailing: [Component] = []) {
        self.leading = leading; self.trailing = trailing
    }
    public static let standard = Self(leading: [.statusIcon, .status, .taskCount, .tps],
        trailing: [.lowQuotaWarning, .quotaMetric, .quotaLabel, .quotaDelayWarning, .sshWarning])
    public subscript(_ lane: Lane) -> [Component] {
        get { lane == .leading ? leading : trailing }
        set { if lane == .leading { leading = newValue } else { trailing = newValue } }
    }
    public var components: Set<Component> { Set(leading + trailing) }
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
    public mutating func shift(_ component: Component, by offset: Int) {
        guard let lane = Lane.allCases.first(where: { self[$0].contains(component) }),
              let index = self[lane].firstIndex(of: component) else { return }
        let target = min(self[lane].count - 1, max(0, index + offset))
        guard target != index else { return }
        self[lane].remove(at: index); self[lane].insert(component, at: target)
    }
    private enum CodingKeys: String, CodingKey { case version, leading, trailing, center }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let schema = try values.decode(Int.self, forKey: .version)
        guard (1...3).contains(schema) else {
            throw DecodingError.dataCorruptedError(forKey: .version, in: values, debugDescription: "Unsupported compact layout")
        }
        leading = try values.decode([String].self, forKey: .leading).compactMap(Component.saved)
        if schema == 1 {
            leading += try values.decodeIfPresent([String].self, forKey: .center)?.compactMap(Component.saved) ?? []
        }
        trailing = try values.decode([String].self, forKey: .trailing).compactMap(Component.saved)
        if schema < 3, leading == [.statusIcon, .status, .tps],
           trailing == [.lowQuotaWarning, .quotaMetric, .quotaLabel, .quotaDelayWarning] {
            leading.insert(.taskCount, at: 2)
            trailing.append(.sshWarning)
        }
    }
    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(version, forKey: .version)
        try values.encode(leading.map(\.rawValue), forKey: .leading)
        try values.encode(trailing.map(\.rawValue), forKey: .trailing)
    }
}
