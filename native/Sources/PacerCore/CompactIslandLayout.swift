import Foundation

/// Presentation only. Hiding a component never stops its underlying collector.
public struct CompactIslandLayout: Equatable, Codable, Sendable {
    public enum Component: String, CaseIterable, Codable, Sendable, Identifiable {
        case statusIcon, status, tps, taskCount, subagentCount, firstOutput
        case quotaWarning, quotaMetric, quotaWindow, pace, resetCountdown, freshness
        case pin, refresh, settings, quit, collapse
        public var id: String { rawValue }
        public var label: String { L10n.text("layout.component." + rawValue) }
        public var shortLabel: String {
            switch self {
            case .statusIcon, .status, .tps, .quotaWarning, .quotaMetric, .quotaWindow, .freshness:
                L10n.text("layout.short." + rawValue)
            default: label
            }
        }
        public var preferredLane: Lane {
            switch self {
            case .statusIcon, .status, .tps, .taskCount, .subagentCount, .firstOutput: .leading
            default: .trailing
            }
        }
        public var symbol: String {
            switch self {
            case .statusIcon: "brain.head.profile"
            case .status: "text.alignleft"
            case .tps: "speedometer"
            case .taskCount: "square.stack"
            case .subagentCount: "person.2"
            case .firstOutput: "timer"
            case .quotaWarning: "exclamationmark.triangle"
            case .quotaMetric: "chart.pie"
            case .quotaWindow: "calendar"
            case .pace: "gauge"
            case .resetCountdown: "arrow.counterclockwise"
            case .freshness: "clock.badge.checkmark"
            case .pin: "pin"
            case .refresh: "arrow.clockwise"
            case .settings: "gearshape"
            case .quit: "power"
            case .collapse: "chevron.up"
            }
        }
    }
    public enum Group: String, CaseIterable, Sendable {
        case tasks, performance, quota, controls
        public var label: String { L10n.text("layout.group." + rawValue) }
        public var components: [Component] {
            switch self {
            case .tasks: [.statusIcon, .status, .taskCount, .subagentCount]
            case .performance: [.tps, .firstOutput]
            case .quota: [.quotaMetric, .pace, .quotaWindow, .resetCountdown, .quotaWarning, .freshness]
            case .controls: [.pin, .refresh, .settings, .quit, .collapse]
            }
        }
    }
    public enum Lane: String, CaseIterable, Codable, Sendable {
        case leading, trailing
        public var label: String { L10n.text("layout.lane." + rawValue) }
    }
    public static let defaultsKey = "compactIslandLayout"
    public let version = 2
    public var leading: [Component]
    public var trailing: [Component]
    public init(leading: [Component] = [], trailing: [Component] = []) {
        self.leading = leading; self.trailing = trailing
    }
    public static let standard = Self(leading: [.statusIcon, .status, .tps],
        trailing: [.quotaWarning, .quotaMetric, .quotaWindow, .freshness])
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
        guard schema == 1 || schema == 2 else {
            throw DecodingError.dataCorruptedError(forKey: .version, in: values, debugDescription: "Unsupported compact layout")
        }
        leading = try values.decode([String].self, forKey: .leading).compactMap(Component.init(rawValue:))
        if schema == 1 {
            leading += try values.decodeIfPresent([String].self, forKey: .center)?.compactMap(Component.init(rawValue:)) ?? []
        }
        trailing = try values.decode([String].self, forKey: .trailing).compactMap(Component.init(rawValue:))
    }
    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(version, forKey: .version)
        try values.encode(leading.map(\.rawValue), forKey: .leading)
        try values.encode(trailing.map(\.rawValue), forKey: .trailing)
    }
}
