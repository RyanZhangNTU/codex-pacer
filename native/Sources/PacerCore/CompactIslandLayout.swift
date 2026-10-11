import Foundation

/// Presentation only. Hiding a component never stops its underlying collector.
public struct CompactIslandLayout: Equatable, Codable, Sendable {
    public enum Component: String, CaseIterable, Codable, Sendable, Identifiable {
        case activity, status, tps, firstOutput
        case quota, quotaGauge, quotaLabel, timeRemaining
        /// One slot for every enabled warning; Reminders chooses which kinds it shows.
        case warnings
        public var id: String { rawValue }
        public var label: String { L10n.text("layout.component." + rawValue) }
        public var shortLabel: String { L10n.text("layout.short." + rawValue) }
        public var detail: String { L10n.text("layout.detail." + rawValue) }
        /// Quota components combine every enabled provider, so they need at least one.
        public func isAvailable(for providers: Set<AgentProvider>) -> Bool {
            switch self {
            case .quota, .quotaGauge, .quotaLabel, .timeRemaining: return !providers.isEmpty
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
            case .quota: "percent"
            case .quotaGauge: "circle.circle"
            case .quotaLabel: "tag"
            case .timeRemaining: "hourglass"
            case .warnings: "exclamationmark.triangle"
            }
        }
        fileprivate static func saved(_ value: String) -> [Self] {
            switch value {
            case "statusIcon", "taskCount": [.activity]
            case _ where Warning(legacyComponent: value) != nil: [.warnings]
            default: Self(rawValue: value).map { [$0] } ?? []
            }
        }
        /// Earlier names expand before schema rules compare whole lanes.
        fileprivate static func legacyNames(_ value: String) -> [String] {
            switch value {
            case "quotaMetric": ["codexQuota", "claudeQuota"]
            case "quotaWindow": ["quotaLabel"]
            case "resetCountdown": ["timeRemaining"]
            case "quotaWarning": ["lowQuotaWarning"]
            case "freshness": ["quotaDelayWarning"]
            default: [value]
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
            case .quota: [.quota, .quotaGauge, .quotaLabel, .timeRemaining]
            case .warnings: [.warnings]
            }
        }
    }
    /// What the warnings component can show, in display order.
    public enum Warning: String, CaseIterable, Codable, Sendable {
        case fiveHour, ssh, quotaDelay
        public var label: String { L10n.text("warning." + rawValue) }
        /// Schemas before 7 had one component per warning.
        fileprivate init?(legacyComponent name: String) {
            switch name {
            case "lowQuotaWarning": self = .fiveHour
            case "sshWarning": self = .ssh
            case "quotaDelayWarning": self = .quotaDelay
            default: return nil
            }
        }
    }
    public enum Lane: String, CaseIterable, Codable, Sendable {
        case leading, trailing
        public var label: String { L10n.text("layout.lane." + rawValue) }
    }
    public static let defaultsKey = "compactIslandLayout"
    public let version = 7
    public var leading: [Component]
    public var trailing: [Component]
    public var warnings: Set<Warning>
    public init(leading: [Component] = [], trailing: [Component] = [], warnings: Set<Warning> = Set(Warning.allCases)) {
        self.leading = leading; self.trailing = trailing; self.warnings = warnings
    }
    public static let standard = Self(leading: [.activity, .tps], trailing: [.warnings, .quotaGauge, .quota])
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
        var result = Self(warnings: warnings)
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
    private enum CodingKeys: String, CodingKey { case version, leading, trailing, center, warnings }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let schema = try values.decode(Int.self, forKey: .version)
        guard (1...7).contains(schema) else {
            throw DecodingError.dataCorruptedError(forKey: .version, in: values, debugDescription: "Unsupported compact layout")
        }
        var leadingNames = try values.decode([String].self, forKey: .leading)
        if schema == 1 {
            leadingNames += try values.decodeIfPresent([String].self, forKey: .center) ?? []
        }
        var trailingNames = try values.decode([String].self, forKey: .trailing).flatMap(Component.legacyNames)
        leadingNames = leadingNames.flatMap(Component.legacyNames)
        if schema < 3, leadingNames == ["statusIcon", "status", "tps"],
           trailingNames == ["lowQuotaWarning", "codexQuota", "claudeQuota", "quotaLabel", "quotaDelayWarning"] {
            leadingNames.insert("taskCount", at: 2)
            trailingNames.append("sshWarning")
        }
        // Schema 5 merges the status icon and task count. An untouched former
        // default lane also drops status text, which stays an optional component.
        if schema < 5, leadingNames == ["statusIcon", "status", "taskCount", "tps"] {
            leadingNames = ["activity", "tps"]
        }
        if schema < 6 { Self.mergeProviderQuotas(&leadingNames, &trailingNames) }
        // Schema 7 merges the separate warnings into one slot at the first
        // one's position; the kinds that were shown stay enabled.
        let enabled: Set<Warning>
        if schema < 7 {
            let shown = Set((leadingNames + trailingNames).compactMap(Warning.init(legacyComponent:)))
            enabled = shown.isEmpty ? Set(Warning.allCases) : shown
        } else {
            enabled = try values.decodeIfPresent([String].self, forKey: .warnings).map { Set($0.compactMap(Warning.init(rawValue:))) }
                ?? Set(Warning.allCases)
        }
        let decoded = Self(leading: leadingNames.flatMap(Component.saved), trailing: trailingNames.flatMap(Component.saved),
            warnings: enabled).normalized
        leading = decoded.leading; trailing = decoded.trailing; warnings = decoded.warnings
    }
    /// Schema 6 shows one quota value that alternates between providers. Lanes
    /// that showed both provider values keep both visible as the rings plus
    /// that value at the first one's position; a single provider value becomes
    /// the value alone. The untouched former default lane adopts the new default.
    private static func mergeProviderQuotas(_ leading: inout [String], _ trailing: inout [String]) {
        if trailing == ["lowQuotaWarning", "codexQuota", "claudeQuota", "quotaLabel", "quotaDelayWarning", "sshWarning"] {
            trailing = standard.trailing.map(\.rawValue)
            return
        }
        let providerValues: Set<String> = ["codexQuota", "claudeQuota"]
        let replacement = Set(leading + trailing).isSuperset(of: providerValues) ? ["quotaGauge", "quota"] : ["quota"]
        var replaced = false
        func merge(_ names: [String]) -> [String] {
            names.flatMap { name -> [String] in
                guard providerValues.contains(name) else { return [name] }
                defer { replaced = true }
                return replaced ? [] : replacement
            }
        }
        leading = merge(leading); trailing = merge(trailing)
    }
    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(version, forKey: .version)
        try values.encode(leading.map(\.rawValue), forKey: .leading)
        try values.encode(trailing.map(\.rawValue), forKey: .trailing)
        try values.encode(Warning.allCases.filter(warnings.contains).map(\.rawValue), forKey: .warnings)
    }
}
