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

/// DeepSeek's former Content choice, read only: without a saved panel layout,
/// Detailed (the default) adds spend and week when DeepSeek is the only service.
enum DeepSeekPanelStyle: String, CaseIterable {
    case detailed, simple
    static let defaultsKey = "deepseekPanelStyle"

    static func load(from defaults: UserDefaults = .standard) -> Self {
        defaults.string(forKey: defaultsKey).flatMap(Self.init(rawValue:)) ?? .detailed
    }
}
