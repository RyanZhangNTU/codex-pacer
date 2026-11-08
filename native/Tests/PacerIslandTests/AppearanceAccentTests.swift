import AppKit
import SwiftUI
import XCTest
@testable import PacerCore
@testable import PacerIsland
import PacerTestSupport

@MainActor
final class AppearanceAccentTests: XCTestCase {
    override func tearDown() {
        PacerAccent.current = .multicolor
        super.tearDown()
    }

    private func brightness(_ color: Color) throws -> CGFloat {
        let rgb = try XCTUnwrap(NSColor(color).usingColorSpace(.sRGB))
        return rgb.redComponent + rgb.greenComponent + rgb.blueComponent
    }

    func testMulticolorKeepsEachServicesColorAndOneColorShadesThemApart() throws {
        PacerAccent.current = .multicolor
        for provider in AgentProvider.allCases {
            XCTAssertEqual(provider.tint, provider.brand, "Multicolor draws every service in its own color")
            XCTAssertNil(PacerAccent.multicolor.tint(for: provider))
        }
        XCTAssertEqual(PacerAccent.multicolor.control, Color.accentColor, "Multicolor leaves controls to the system accent")
        XCTAssertEqual(PacerAccent.allCases.first, .multicolor, "Multicolor leads the row, as in the system's own picker")

        let codexBrand = AgentProvider.codex.brand
        for accent in PacerAccent.allCases where accent != .multicolor {
            PacerAccent.current = accent
            let color = try XCTUnwrap(accent.color)
            XCTAssertEqual(accent.control, color)
            XCTAssertEqual(AgentProvider.codex.tint, color, "\(accent): Codex takes the accent at full strength")
            let codex = try brightness(AgentProvider.codex.tint), claude = try brightness(AgentProvider.claude.tint),
                deepseek = try brightness(AgentProvider.deepseek.tint)
            XCTAssertLessThan(codex, claude, "\(accent): Claude, usually the inner ring, is a lighter shade")
            XCTAssertLessThan(claude, deepseek, "\(accent): DeepSeek is lighter still")
            XCTAssertEqual(AgentProvider.codex.brand, codexBrand, "Service icons keep their own color whatever the accent")
        }
        XCTAssertEqual(PacerPalette.attention, Color(red: 1.0, green: 0.74, blue: 0.38), "Things that need you stay amber")
    }

    func testSavedChoicesFallBackToMulticolorAndAutoAndMapToAppearances() throws {
        let name = testDefaultsName("AppearanceAccentTests")
        defer { removeTestDefaults(name) }
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        XCTAssertEqual(PacerAccent(defaults: defaults), .multicolor)
        XCTAssertEqual(AppTheme(defaults: defaults), .auto)
        defaults.set("green", forKey: PacerAccent.defaultsKey)
        defaults.set("dark", forKey: AppTheme.defaultsKey)
        XCTAssertEqual(PacerAccent(defaults: defaults), .green)
        XCTAssertEqual(AppTheme(defaults: defaults), .dark)
        defaults.set("teal", forKey: PacerAccent.defaultsKey)
        defaults.set("sepia", forKey: AppTheme.defaultsKey)
        XCTAssertEqual(PacerAccent(defaults: defaults), .multicolor, "An unknown saved value falls back")
        XCTAssertEqual(AppTheme(defaults: defaults), .auto)

        XCTAssertNil(AppTheme.auto.appearance, "Auto follows the system")
        XCTAssertEqual(AppTheme.light.appearance?.name, .aqua)
        XCTAssertEqual(AppTheme.dark.appearance?.name, .darkAqua)
        for accent in PacerAccent.allCases { XCTAssertNotEqual(accent.label, "appearance.accent." + accent.rawValue) }
        for theme in AppTheme.allCases { XCTAssertNotEqual(theme.label, "appearance.theme." + theme.rawValue) }
    }

    func testAppliedSettingsGiveTheIslandTheSavedAccent() async throws {
        let name = testDefaultsName("AppearanceAccentTests.model")
        defer { removeTestDefaults(name) }
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defaults.set(false, forKey: "monitorSSH")
        let model = IslandModel(defaults: defaults,
            installation: .init(codexInstalled: true, claudeInstalled: false, deepseekInstalled: false))
        defaults.set(PacerAccent.pink.rawValue, forKey: PacerAccent.defaultsKey)
        model.applySettings(sourceChanged: false)
        XCTAssertEqual(PacerAccent.current, .pink)
        XCTAssertEqual(AgentProvider.codex.tint, PacerAccent.pink.color)
        defaults.removeObject(forKey: PacerAccent.defaultsKey)
        model.applySettings(sourceChanged: false)
        XCTAssertEqual(PacerAccent.current, .multicolor)
        await model.shutdown()
    }
}
