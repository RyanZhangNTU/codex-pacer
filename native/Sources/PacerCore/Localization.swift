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

    public static let sharedResourceBundle: Bundle = Bundle.module
    private final class Snapshot: @unchecked Sendable {
        let bundle: Bundle
        let catalog: BundleLocalizationCatalog
        let resources: LocalizationResources
        init(bundle: Bundle, platform: (any LocalizationCatalog)? = nil) {
            self.bundle = bundle
            catalog = BundleLocalizationCatalog(bundle: bundle)
            resources = LocalizationResources(shared: catalog, platform: platform)
        }
    }
    private final class ResourceState: @unchecked Sendable {
        let lock = NSLock()
        var snapshot: Snapshot?
    }
    private static let state = ResourceState()
    private static var current: Snapshot {
        state.lock.lock(); defer { state.lock.unlock() }
        if let snapshot = state.snapshot { return snapshot }
        let snapshot = Snapshot(bundle: sharedResourceBundle)
        state.snapshot = snapshot
        return snapshot
    }
    /// Hosts configure packaged resources before creating clients or views.
    public static func configureResources(bundle: Bundle, platform: (any LocalizationCatalog)? = nil) {
        let snapshot = Snapshot(bundle: bundle, platform: platform)
        state.lock.lock(); state.snapshot = snapshot; state.lock.unlock()
    }
    public static var resourceBundle: Bundle { current.bundle }
    static func localizationResourceURL(for language: AppLanguage) -> URL? { current.catalog.resourceURL(for: language) }

    public static func text(_ key: String, _ arguments: CVarArg..., language selected: AppLanguage? = nil) -> String {
        current.resources.text(key, arguments: arguments, language: selected ?? language)
    }

    public static func date(_ value: Date, date dateStyle: Date.FormatStyle.DateStyle = .abbreviated,
                            time timeStyle: Date.FormatStyle.TimeStyle = .shortened) -> String {
        value.formatted(Date.FormatStyle(date: dateStyle, time: timeStyle).locale(locale))
    }

    /// A reset short enough for one row: the time today, the weekday within the
    /// coming six days, otherwise the date.
    public static func moment(_ value: Date, relativeTo now: Date, calendar: Calendar = .current,
                              locale: Locale? = nil) -> String {
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: now), to: calendar.startOfDay(for: value)).day ?? 0
        var style = days == 0 ? Date.FormatStyle(date: .omitted, time: .shortened)
            : (1...6).contains(days) ? Date.FormatStyle().weekday(.abbreviated).hour().minute()
            : Date.FormatStyle().month(.abbreviated).day().hour().minute()
        style.calendar = calendar
        style.timeZone = calendar.timeZone
        return value.formatted(style.locale(locale ?? Self.locale))
    }
}
