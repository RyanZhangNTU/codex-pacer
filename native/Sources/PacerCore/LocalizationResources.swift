import Foundation

public protocol LocalizationCatalog: Sendable {
    func format(for key: String, language: AppLanguage) -> String?
}

/// The shared catalog also works in test hosts whose default language is English.
public struct BundleLocalizationCatalog: LocalizationCatalog, @unchecked Sendable {
    private let bundles: [AppLanguage: Bundle]
    public init(bundle: Bundle) {
        bundles = Dictionary(uniqueKeysWithValues: AppLanguage.allCases.compactMap { language in
            guard let root = bundle.resourceURL else { return nil }
            for name in [language.rawValue, language.rawValue.lowercased()] {
                if let localized = Bundle(url: root.appendingPathComponent(name + ".lproj", isDirectory: true)) {
                    return (language, localized)
                }
            }
            return nil
        })
    }
    public func resourceURL(for language: AppLanguage) -> URL? { bundles[language]?.resourceURL }
    public func format(for key: String, language: AppLanguage) -> String? {
        let missing = "\u{1}pacer-missing\u{1}"
        guard let value = bundles[language]?.localizedString(forKey: key, value: missing, table: nil), value != missing else { return nil }
        return value
    }
}

/// Platform wording can override shared keys without changing fallback or formatting.
public final class LocalizationResources: @unchecked Sendable {
    private let shared: any LocalizationCatalog
    private let platform: (any LocalizationCatalog)?
    private let lock = NSLock()
    private var formats: [String: String] = [:]
    private var locales: [AppLanguage: Locale] = [:]
    public init(shared: any LocalizationCatalog, platform: (any LocalizationCatalog)? = nil) {
        self.shared = shared; self.platform = platform
    }
    public func text(_ key: String, arguments: [CVarArg] = [], language: AppLanguage) -> String {
        let cacheKey = language.rawValue + "\u{1}" + key
        lock.lock()
        let cached = formats[cacheKey]
        lock.unlock()
        let format: String
        if let cached { format = cached } else {
            format = platform?.format(for: key, language: language) ?? shared.format(for: key, language: language)
                ?? platform?.format(for: key, language: .english) ?? shared.format(for: key, language: .english) ?? key
            lock.lock(); formats[cacheKey] = format; lock.unlock()
        }
        guard !arguments.isEmpty else { return format }
        lock.lock()
        let locale = locales[language] ?? language.locale
        locales[language] = locale
        lock.unlock()
        return String(format: format, locale: locale, arguments: arguments)
    }
}
