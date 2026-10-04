import Foundation

public enum AppLanguage: String, CaseIterable, Sendable {
    case english = "en"
    case simplifiedChinese = "zh-Hans"

    public var locale: Locale {
        let region = Locale.current.region?.identifier
        return Locale(identifier: region.map { rawValue + "_" + $0 } ?? rawValue)
    }
}

public enum LanguagePreference: String, CaseIterable, Sendable {
    case system
    case simplifiedChinese = "zh-Hans"
    case english = "en"

    public static let defaultsKey = "appLanguage"
    public static func load(from defaults: UserDefaults = .standard) -> Self {
        defaults.string(forKey: defaultsKey).flatMap(Self.init(rawValue:)) ?? .system
    }
    public func resolved(preferredLanguages: [String] = Self.systemLanguages()) -> AppLanguage {
        switch self {
        case .english: return .english
        case .simplifiedChinese: return .simplifiedChinese
        case .system:
            for identifier in preferredLanguages {
                let language = identifier.replacingOccurrences(of: "_", with: "-").lowercased().split(separator: "-").first
                if language == "zh" { return .simplifiedChinese }
                if language == "en" { return .english }
            }
            return .english
        }
    }
    public static func systemLanguages(defaults: UserDefaults = .standard) -> [String] {
        // Ignore this app's explicit override when the user chooses Follow macOS.
        defaults.persistentDomain(forName: UserDefaults.globalDomain)?["AppleLanguages"] as? [String]
            ?? Locale.preferredLanguages
    }
    public func save(to defaults: UserDefaults = .standard) {
        defaults.set(rawValue, forKey: Self.defaultsKey)
        // This is the application's preferences domain, never NSGlobalDomain.
        // Relaunch lets AppKit, open panels and Sparkle use the same language.
        if self == .system { defaults.removeObject(forKey: "AppleLanguages") }
        else { defaults.set([rawValue], forKey: "AppleLanguages") }
    }
    public var label: String {
        switch self {
        case .system: return L10n.text("language.system")
        case .simplifiedChinese: return "简体中文"
        case .english: return "English"
        }
    }
}

public enum L10n {
    /// A language is fixed for one launch, including stored notices and errors.
    public static let language = LanguagePreference.load().resolved()
    public static var locale: Locale { language.locale }

    public static let resourceBundle: Bundle = {
        // Resolve the packaged copy explicitly before SwiftPM's bundle lookup.
        if let url = Bundle.main.url(forResource: "CodexPacerIsland_PacerCore", withExtension: "bundle"),
           let bundle = Bundle(url: url) { return bundle }
        return Bundle.module
    }()
    private static let bundles: [AppLanguage: Bundle] = Dictionary(uniqueKeysWithValues: AppLanguage.allCases.compactMap {
        guard let path = resourceBundle.path(forResource: $0.rawValue, ofType: "lproj"), let bundle = Bundle(path: path) else { return nil }
        return ($0, bundle)
    })

    public static func text(_ key: String, _ arguments: CVarArg..., language selected: AppLanguage? = nil) -> String {
        let selected = selected ?? language
        let fallback = bundles[.english]?.localizedString(forKey: key, value: key, table: nil) ?? key
        let format = bundles[selected]?.localizedString(forKey: key, value: fallback, table: nil) ?? fallback
        guard !arguments.isEmpty else { return format }
        return String(format: format, locale: selected.locale, arguments: arguments)
    }

    public static func date(_ value: Date, date dateStyle: Date.FormatStyle.DateStyle = .abbreviated,
                            time timeStyle: Date.FormatStyle.TimeStyle = .shortened) -> String {
        value.formatted(Date.FormatStyle(date: dateStyle, time: timeStyle).locale(locale))
    }
}
