#if os(Windows)
import Foundation
import PacerCore

private struct WindowsLocalizationCatalog: LocalizationCatalog {
    let strings: [AppLanguage: [String: String]]
    init() {
        strings = Dictionary(uniqueKeysWithValues: AppLanguage.allCases.map { language in
            let url = Bundle.module.resourceURL?.appendingPathComponent("Localization/" + language.rawValue + ".json")
            let values = url.flatMap { try? Data(contentsOf: $0) }.flatMap { try? JSONDecoder().decode([String: String].self, from: $0) } ?? [:]
            return (language, values)
        })
    }
    func format(for key: String, language: AppLanguage) -> String? { strings[language]?[key] }
}

public enum WindowsResources {
    public static func configure() {
        L10n.configureResources(bundle: L10n.sharedResourceBundle, platform: WindowsLocalizationCatalog())
    }
}
#endif
