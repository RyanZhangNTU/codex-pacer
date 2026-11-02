import Foundation
import PacerCore

typealias ExpandedQuotaStyle = QuotaDashboardPresentation.Style

extension QuotaDashboardPresentation.Style {
    static let defaultsKey = "expandedQuotaStyle"
    static func load(from defaults: UserDefaults = .standard) -> Self {
        defaults.string(forKey: defaultsKey).flatMap(Self.init(rawValue:)) ?? .split
    }
    func save(to defaults: UserDefaults = .standard) { defaults.set(rawValue, forKey: Self.defaultsKey) }
}

/// DeepSeek alone: the full dashboard, or only the dial and what sits beside it.
enum DeepSeekPanelStyle: String, CaseIterable, Identifiable {
    case detailed, simple
    static let defaultsKey = "deepseekPanelStyle"
    var id: String { rawValue }
    var label: String { L10n.text("deepseek.panel_style." + rawValue) }

    static func load(from defaults: UserDefaults = .standard) -> Self {
        defaults.string(forKey: defaultsKey).flatMap(Self.init(rawValue:)) ?? .detailed
    }
    func save(to defaults: UserDefaults = .standard) { defaults.set(rawValue, forKey: Self.defaultsKey) }
}
