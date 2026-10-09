import Foundation

/// Presentation only. Hiding a component never stops its underlying collector.
public struct CompactIslandLayout: Equatable, Codable, Sendable {
    public enum Component: String, CaseIterable, Codable, Sendable, Identifiable {
        case statusIcon, status, tps, taskCount, subagentCount, firstOutput
        case quotaWarning, quotaMetric, quotaWindow, pace, resetCountdown, freshness
        case pin, refresh, settings, quit, collapse
        public var id: String { rawValue }
        public var label: String { L10n.text("layout.component." + rawValue) }
    }
    public enum Lane: String, CaseIterable, Codable, Sendable {
        case leading, center, trailing
        public var label: String { L10n.text("layout.lane." + rawValue) }
    }
    public static let defaultsKey = "compactIslandLayout"
    public var version = 1
    public var leading: [Component]
    public var center: [Component]
    public var trailing: [Component]
    public init(leading: [Component] = [], center: [Component] = [], trailing: [Component] = []) {
        self.leading = leading; self.center = center; self.trailing = trailing
    }
    public static let standard = Self(leading: [.statusIcon, .status, .tps],
        trailing: [.quotaWarning, .quotaMetric, .quotaWindow, .freshness])
    public subscript(_ lane: Lane) -> [Component] {
        get { switch lane { case .leading: leading; case .center: center; case .trailing: trailing } }
        set { switch lane { case .leading: leading = newValue; case .center: center = newValue; case .trailing: trailing = newValue } }
    }
    public var components: Set<Component> { Set(leading + center + trailing) }
    public var normalized: Self {
        var seen: Set<Component> = []
        var result = Self()
        for lane in Lane.allCases { result[lane] = self[lane].filter { seen.insert($0).inserted } }
        return result
    }
    public static func load(from defaults: UserDefaults = .standard) -> Self {
        guard let data = defaults.data(forKey: defaultsKey), data.count <= 8192,
              let value = try? JSONDecoder().decode(Self.self, from: data), value.version == 1 else { return .standard }
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
    private enum CodingKeys: String, CodingKey { case version, leading, center, trailing }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        version = try values.decode(Int.self, forKey: .version)
        // Newer component names do not discard the user's known choices.
        leading = try values.decode([String].self, forKey: .leading).compactMap(Component.init(rawValue:))
        center = try values.decode([String].self, forKey: .center).compactMap(Component.init(rawValue:))
        trailing = try values.decode([String].self, forKey: .trailing).compactMap(Component.init(rawValue:))
    }
}
