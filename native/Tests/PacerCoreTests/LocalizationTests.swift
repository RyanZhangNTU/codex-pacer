import XCTest
@testable import PacerCore

final class LocalizationTests: XCTestCase {
    func testSystemPreferenceUsesFirstSupportedLanguageAndEnglishFallback() {
        XCTAssertEqual(LanguagePreference.system.resolved(preferredLanguages: ["en-SG", "zh-Hans-CN"]), .english)
        XCTAssertEqual(LanguagePreference.system.resolved(preferredLanguages: ["zh-Hans-CN", "en"]), .simplifiedChinese)
        XCTAssertEqual(LanguagePreference.system.resolved(preferredLanguages: ["zh-Hant-TW"]), .simplifiedChinese)
        XCTAssertEqual(LanguagePreference.system.resolved(preferredLanguages: ["ja-JP", "zh_CN", "en"]), .simplifiedChinese)
        XCTAssertEqual(LanguagePreference.system.resolved(preferredLanguages: ["fr-FR"]), .english)
        XCTAssertEqual(LanguagePreference.system.resolved(preferredLanguages: []), .english)
        XCTAssertEqual(LanguagePreference.english.resolved(preferredLanguages: ["zh-Hans"]), .english)
        XCTAssertEqual(LanguagePreference.simplifiedChinese.resolved(preferredLanguages: ["en"]), .simplifiedChinese)
    }

    func testExplicitOverridePersistsOnlyInTheAppAndSystemRemovesIt() throws {
        let name = "com.codexpacer.language-tests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let systemBefore = LanguagePreference.systemLanguages()
        defaults.set("keep", forKey: "otherPreference")
        XCTAssertEqual(LanguagePreference.load(from: defaults), .system)
        LanguagePreference.english.save(to: defaults)
        XCTAssertEqual(LanguagePreference.load(from: defaults), .english)
        XCTAssertEqual(defaults.stringArray(forKey: "AppleLanguages"), ["en"])
        LanguagePreference.simplifiedChinese.save(to: defaults)
        XCTAssertEqual(defaults.stringArray(forKey: "AppleLanguages"), ["zh-Hans"])
        LanguagePreference.system.save(to: defaults)
        XCTAssertNil(defaults.persistentDomain(forName: name)?["AppleLanguages"])
        XCTAssertEqual(defaults.string(forKey: "otherPreference"), "keep")
        XCTAssertEqual(LanguagePreference.systemLanguages(), systemBefore)
    }

    func testBothCatalogsAreCompleteAndFormatArgumentsMatch() throws {
        func catalog(_ language: AppLanguage) throws -> [String: String] {
            let directory = try XCTUnwrap(L10n.resourceBundle.url(forResource: language.rawValue, withExtension: "lproj"))
            return try XCTUnwrap(PropertyListSerialization.propertyList(from: Data(contentsOf: directory.appendingPathComponent("Localizable.strings")),
                options: [], format: nil) as? [String: String])
        }
        let english = try catalog(.english), chinese = try catalog(.simplifiedChinese)
        XCTAssertGreaterThan(english.count, 250)
        XCTAssertEqual(Set(english.keys), Set(chinese.keys))
        let expression = try NSRegularExpression(pattern: #"%(?:(\d+)\$)?(ld|d|g|(?:\.\d+)?f|@)"#)
        func arguments(_ value: String) -> [String] {
            expression.matches(in: value, range: NSRange(value.startIndex..., in: value)).enumerated().map { offset, match in
                let text = value as NSString
                let index = match.range(at: 1).location == NSNotFound ? String(offset + 1) : text.substring(with: match.range(at: 1))
                return index + ":" + text.substring(with: match.range(at: 2))
            }.sorted()
        }
        for key in english.keys {
            XCTAssertFalse(english[key]!.isEmpty, key)
            XCTAssertFalse(chinese[key]!.isEmpty, key)
            XCTAssertEqual(arguments(english[key]!), arguments(chinese[key]!), key)
            XCTAssertNil(english[key]!.range(of: #"\p{Han}"#, options: .regularExpression), key)
        }
    }

    func testFormattingKeepsNamesAndInterpolatedValues() {
        XCTAssertEqual(L10n.text("quota.days", 7, language: .english), "7-day quota")
        XCTAssertEqual(L10n.text("quota.days", 7, language: .simplifiedChinese), "7 天额度")
        XCTAssertEqual(L10n.text("quota.compact_days", 7, language: .english), "7d")
        XCTAssertEqual(L10n.text("quota.remaining", 51, language: .english), "51% remaining")
        XCTAssertEqual(L10n.text("common.quit", language: .english), "Quit Codex Pacer")
        XCTAssertEqual(L10n.text("common.quit", language: .simplifiedChinese), "退出 Codex Pacer")
        XCTAssertEqual(L10n.text("chart.expiry_item", 2, "Oct 5", language: .english), "Resets expiring on Oct 5: 2")
        XCTAssertTrue(L10n.text("cli.timeout", "Initialize CLI", 8.0, "initialize", language: .english).contains("8 seconds (initialize)"))
        XCTAssertTrue(L10n.text("cli.path_missing", "/custom path/codex", language: .simplifiedChinese).contains("/custom path/codex"))
        for language in AppLanguage.allCases {
            XCTAssertTrue(L10n.text("cli.error_code", "-32601", language: language).contains("-32601"))
            XCTAssertFalse(L10n.text("cli.error_code", "-32601", language: language).contains("32,601"))
        }
    }
}
