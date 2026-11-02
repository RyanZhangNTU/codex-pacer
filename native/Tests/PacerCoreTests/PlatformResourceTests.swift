import XCTest
@testable import PacerCore

final class PlatformResourceTests: XCTestCase {
    private struct Catalog: LocalizationCatalog {
        let entries: [AppLanguage: [String: String]]
        func format(for key: String, language: AppLanguage) -> String? { entries[language]?[key] }
    }

    func testPlatformSharedAndEnglishFallbackOrder() {
        let shared = Catalog(entries: [.english: ["both": "shared English", "shared": "English", "english": "fallback", "format": "%@ %d"],
            .simplifiedChinese: ["both": "共享", "shared": "中文", "precedence": "共享优先"]])
        let platform = Catalog(entries: [.english: ["both": "platform English", "precedence": "platform fallback", "platform": "platform only"],
            .simplifiedChinese: ["both": "平台", "format": "%@：%d"]])
        let resources = LocalizationResources(shared: shared, platform: platform)
        for _ in 0..<2 {
            XCTAssertEqual(resources.text("both", language: .simplifiedChinese), "平台")
            XCTAssertEqual(resources.text("both", language: .english), "platform English")
            XCTAssertEqual(resources.text("shared", language: .simplifiedChinese), "中文")
            XCTAssertEqual(resources.text("precedence", language: .simplifiedChinese), "共享优先")
            XCTAssertEqual(resources.text("platform", language: .simplifiedChinese), "platform only")
            XCTAssertEqual(resources.text("english", language: .simplifiedChinese), "fallback")
            XCTAssertEqual(resources.text("missing", language: .simplifiedChinese), "missing")
            XCTAssertEqual(resources.text("format", arguments: ["fixture", 7], language: .simplifiedChinese), "fixture：7")
            XCTAssertEqual(resources.text("format", arguments: ["fixture", 7], language: .english), "fixture 7")
        }
    }

    func testEmptyPlatformCatalogPreservesSharedFallback() {
        let resources = LocalizationResources(shared: Catalog(entries: [.english: ["key": "English"], .simplifiedChinese: ["key": "中文"]]))
        XCTAssertEqual(resources.text("key", language: .simplifiedChinese), "中文")
        XCTAssertEqual(resources.text("key", language: .english), "English")
        XCTAssertEqual(resources.text("unknown", language: .english), "unknown")
    }
}
