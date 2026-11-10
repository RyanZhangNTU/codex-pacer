import AppKit
import SwiftUI
import XCTest
@testable import PacerCore
@testable import PacerIsland
import PacerTestSupport

@MainActor
final class IslandMaterialTests: XCTestCase {
    override func tearDown() {
        PacerPalette.light = false
        PacerAccent.current = .multicolor
        super.tearDown()
    }

    private func rgb(_ color: Color) throws -> [Int] {
        let value = try XCTUnwrap(NSColor(color).usingColorSpace(.sRGB))
        return [value.redComponent, value.greenComponent, value.blueComponent].map { Int(($0 * 255).rounded()) }
    }
    private func alpha(_ color: Color) throws -> Double {
        Double(try XCTUnwrap(NSColor(color).usingColorSpace(.sRGB)).alphaComponent)
    }

    func testSavedMaterialsKeepLightGlassAndGraphite() throws {
        let name = testDefaultsName("IslandMaterialTests")
        defer { removeTestDefaults(name) }
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        let fallback: IslandAppearance = IslandAppearance.supportsLiquidGlass ? .liquidGlass : .classic
        XCTAssertEqual(IslandAppearance.stored(in: defaults), fallback)
        for material in [IslandAppearance.classic, .graphite, .liquidGlassLight] {
            defaults.set(material.rawValue, forKey: "islandAppearance")
            XCTAssertEqual(IslandAppearance.stored(in: defaults), material, "\(material) is kept on every system")
        }
        defaults.set(IslandAppearance.liquidGlass.rawValue, forKey: "islandAppearance")
        XCTAssertEqual(IslandAppearance.stored(in: defaults), fallback, "Only dark glass needs the system material")
        defaults.set("frosted", forKey: "islandAppearance")
        XCTAssertEqual(IslandAppearance.stored(in: defaults), fallback, "An unknown material falls back")

        XCTAssertEqual(IslandAppearance.allCases.filter(\.isLight), [.liquidGlassLight], "Only light glass turns the island light")
        XCTAssertEqual(IslandAppearance.allCases.filter(\.isGlass), [.liquidGlass, .liquidGlassLight])
        for material in IslandAppearance.allCases {
            XCTAssertFalse(material.label.hasPrefix("settings."), "\(material) has a name")
            XCTAssertFalse(material.info.hasPrefix("appearance.material_info."), "\(material) explains itself")
        }
        XCTAssertEqual(try rgb(PacerPalette.face(.graphite)), [0x16, 0x17, 0x1B])
        XCTAssertEqual(try rgb(PacerPalette.face(.liquidGlassLight)), [236, 236, 240], "Light glass without the material keeps a light face")
        XCTAssertEqual(try rgb(PacerPalette.face(.classic)), [0, 0, 0])
        XCTAssertEqual(try rgb(PacerPalette.face(.liquidGlass)), [0, 0, 0])
    }

    func testRimFollowsTheMaterialAlongTheFreeSidesOnly() throws {
        XCTAssertEqual(IslandAppearance.graphite.rim(glassVisible: false).width, 1, "Graphite draws a solid 1-point edge")
        XCTAssertNil(IslandAppearance.graphite.rim(glassVisible: false).highlight)
        let light = IslandAppearance.liquidGlassLight.rim(glassVisible: true)
        XCTAssertNil(light.highlight, "Only the dark materials take a top highlight")
        XCTAssertEqual(try rgb(light.ink), [0, 0, 0]); XCTAssertEqual(try alpha(light.ink), 31.0 / 255, accuracy: 0.002)
        for material in [IslandAppearance.classic, .liquidGlass, .liquidGlassLight] {
            XCTAssertEqual(material.rim(glassVisible: true).width, 0.75)
        }
        XCTAssertNotNil(IslandAppearance.classic.rim(glassVisible: false).highlight)
        XCTAssertNotEqual(IslandAppearance.liquidGlass.rim(glassVisible: true), IslandAppearance.liquidGlass.rim(glassVisible: false),
            "Visible glass takes a brighter rim; without the material it draws as black")

        XCTAssertEqual(IslandFreeSides(attached: true, flatEdge: nil), [.bottom, .left, .right])
        XCTAssertEqual(IslandFreeSides(attached: false, flatEdge: .top), [.bottom, .left, .right])
        XCTAssertEqual(IslandFreeSides(attached: false, flatEdge: .bottom), [.top, .left, .right])
        XCTAssertEqual(IslandFreeSides(attached: false, flatEdge: .left), [.top, .bottom, .right])
        XCTAssertEqual(IslandFreeSides(attached: false, flatEdge: .right), [.top, .bottom, .left])
        XCTAssertEqual(IslandFreeSides(attached: false, flatEdge: nil), .all)

        let rect = CGRect(x: 0, y: 0, width: 200, height: 36), inset: CGFloat = 0.375
        func rim(_ sides: IslandFreeSides, attached: Bool) -> Path {
            let corners = IslandSurface.corners(collapsedRadius: 18, fraction: 0, attached: attached, flatEdge: nil)
            return IslandRimShape(corners: corners, sides: sides, inset: inset).path(in: rect).strokedPath(StrokeStyle(lineWidth: 0.75))
        }
        let free = rim(.all, attached: false), hanging = rim([.bottom, .left, .right], attached: true)
        XCTAssertTrue(free.contains(CGPoint(x: 100, y: inset)))
        XCTAssertFalse(hanging.contains(CGPoint(x: 100, y: inset)), "The edge against the screen draws no rim")
        XCTAssertTrue(hanging.contains(CGPoint(x: 100, y: 36 - inset)))
        XCTAssertTrue(hanging.contains(CGPoint(x: inset, y: 10)))
    }

    func testCornersGrowFromTheBarsRadiusAndStaySquareAgainstTheScreen() {
        XCTAssertEqual(IslandSurface.corners(collapsedRadius: 19, fraction: 0, attached: false, flatEdge: nil),
            IslandCorners(topLeft: 19, topRight: 19, bottomRight: 19, bottomLeft: 19))
        XCTAssertEqual(IslandSurface.corners(collapsedRadius: 15, fraction: 1, attached: true, flatEdge: nil),
            IslandCorners(topLeft: 0, topRight: 0, bottomRight: 27, bottomLeft: 27), "An open island always reaches 27")
        XCTAssertEqual(IslandSurface.corners(collapsedRadius: 16, fraction: 0.5, attached: false, flatEdge: .left),
            IslandCorners(topLeft: 0, topRight: 21.5, bottomRight: 21.5, bottomLeft: 0))
        XCTAssertEqual(IslandSurface.corners(collapsedRadius: 24, fraction: 0, attached: false, flatEdge: .bottom),
            IslandCorners(topLeft: 24, topRight: 24, bottomRight: 0, bottomLeft: 0))
    }

    func testLightGlassTurnsInksServicesAndOverlaysTogether() throws {
        PacerAccent.current = .multicolor
        PacerPalette.light = true
        XCTAssertEqual(try rgb(PacerPalette.primary), [29, 29, 31])
        XCTAssertEqual(try rgb(PacerPalette.secondary), [60, 60, 67]); XCTAssertEqual(try alpha(PacerPalette.secondary), 0.72, accuracy: 0.002)
        XCTAssertEqual(try alpha(PacerPalette.tertiary), 0.47, accuracy: 0.002)
        XCTAssertEqual(try rgb(PacerPalette.attention), [178, 106, 0])
        XCTAssertEqual(try rgb(PacerPalette.danger), [211, 58, 47])
        XCTAssertEqual(try rgb(PacerPalette.paused), [140, 109, 46])
        XCTAssertEqual(try rgb(AgentProvider.codex.tint), [14, 140, 120])
        XCTAssertEqual(try rgb(AgentProvider.claude.tint), [196, 88, 31])
        XCTAssertEqual(try rgb(AgentProvider.deepseek.tint), [62, 91, 219])
        XCTAssertEqual(try rgb(PacerPalette.overlay(0.08)), [0, 0, 0], "White washes turn black at the same strength")
        XCTAssertEqual(try alpha(PacerPalette.overlay(0.08)), 0.08, accuracy: 0.002)
        XCTAssertEqual(try rgb(PacerPalette.tick), [29, 29, 31], "Ticks and hands turn dark")
        XCTAssertEqual(try rgb(PacerPalette.surface), [236, 236, 240], "Previews of the light island sit on its light face")

        PacerPalette.light = false
        XCTAssertEqual(AgentProvider.codex.tint, AgentProvider.codex.brand)
        XCTAssertEqual(try rgb(PacerPalette.overlay(0.08)), [255, 255, 255])
        XCTAssertEqual(try rgb(PacerPalette.tick), [255, 255, 255])
        XCTAssertEqual(try rgb(AgentProvider.claude.shade(light: true)), [196, 88, 31], "A preview can draw the other tone")

        PacerAccent.current = .blue
        PacerPalette.light = false
        XCTAssertEqual(AgentProvider.codex.tint, PacerAccent.blue.color, "The dark island takes the accent at full strength")
    }

    /// WCAG relative luminance of an sRGB color.
    private func luminance(_ color: Color) throws -> Double {
        let value = try XCTUnwrap(NSColor(color).usingColorSpace(.sRGB))
        func linear(_ c: CGFloat) -> Double { let v = Double(c); return v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
        return 0.2126 * linear(value.redComponent) + 0.7152 * linear(value.greenComponent) + 0.0722 * linear(value.blueComponent)
    }

    func testEveryAccentKeepsReadableShadesOnLightGlass() throws {
        let face = try luminance(IslandAppearance.lightFace)
        for accent in PacerAccent.allCases where accent != .multicolor {
            PacerAccent.current = accent
            PacerPalette.light = true
            let shades = try AgentProvider.allCases.map { try luminance($0.tint) }
            for (provider, shade) in zip(AgentProvider.allCases, shades) {
                XCTAssertGreaterThanOrEqual((face + 0.05) / (shade + 0.05), 3.5, "\(accent) \(provider) reads on the light face")
                XCTAssertEqual(shade, PacerAccent.lightLuminance(for: provider), accuracy: 0.004)
            }
            XCTAssertEqual(shades, shades.sorted(), "\(accent): Codex, Claude, DeepSeek run strongest first, so the rings stay apart")
            XCTAssertEqual(AgentProvider.codex.shade(light: false), accent.color, "\(accent): the dark tone is unchanged")
        }
        PacerAccent.current = .yellow
        let yellow = try XCTUnwrap(NSColor(AgentProvider.deepseek.shade(light: true)).usingColorSpace(.sRGB))
        XCTAssertGreaterThan(yellow.redComponent, yellow.blueComponent * 4, "Scaling keeps the hue: yellow stays a warm olive")
    }

    func testAppliedSettingsSetTheIslandTone() async throws {
        let name = testDefaultsName("IslandMaterialTests.model")
        defer { removeTestDefaults(name) }
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defaults.set(false, forKey: "monitorSSH")
        let model = IslandModel(defaults: defaults,
            installation: .init(codexInstalled: true, claudeInstalled: false, deepseekInstalled: false))
        defaults.set(IslandAppearance.liquidGlassLight.rawValue, forKey: "islandAppearance")
        model.applySettings(sourceChanged: false)
        XCTAssertTrue(PacerPalette.light)
        XCTAssertTrue(model.lightTone)
        XCTAssertEqual(model.appearance, .liquidGlassLight)

        // The black notch bar draws the dark tone over light glass, and the
        // tone stays dark through a settings change while it is covered.
        model.coverTone(true)
        XCTAssertFalse(PacerPalette.light); XCTAssertFalse(model.lightTone)
        XCTAssertEqual(try rgb(PacerPalette.primary), [245, 245, 245], "Light ink on the black bar")
        XCTAssertNotEqual(try rgb(PacerPalette.surface), [236, 236, 240], "Previews leave the light face while the bar is black")
        model.applySettings(sourceChanged: false)
        XCTAssertFalse(PacerPalette.light)
        model.coverTone(false)
        XCTAssertTrue(PacerPalette.light, "The open island shows light glass again"); XCTAssertTrue(model.lightTone)

        defaults.set(IslandAppearance.graphite.rawValue, forKey: "islandAppearance")
        model.applySettings(sourceChanged: false)
        XCTAssertFalse(PacerPalette.light, "Graphite is a dark material")
        model.coverTone(true)
        XCTAssertFalse(PacerPalette.light)
        await model.shutdown()
    }

    func testRotationsShareOneClockAndANewReadingKeepsTheirFrame() throws {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 80, height: 24), styleMask: .borderless, backing: .buffered, defer: false)
        let view = AlternatingQuotaView(frame: NSRect(x: 0, y: 0, width: 60, height: 16))
        window.contentView?.addSubview(view)
        view.update(entries: [.init(text: "58%", color: .white), .init(text: "81%", color: .white)], animates: true)
        XCTAssertEqual(view.layer?.masksToBounds, true, "Values are clipped to their slot")
        let layers = try XCTUnwrap(view.layer?.sublayers)
        XCTAssertEqual(layers.count, 2)
        for layer in layers {
            XCTAssertEqual(try XCTUnwrap(layer.animation(forKey: "alternate")).beginTime, AlternatingQuotaText.epoch)
            let slide = try XCTUnwrap(layer.animation(forKey: "slide") as? CAKeyframeAnimation)
            XCTAssertEqual(slide.beginTime, AlternatingQuotaText.epoch, "Every rotation keeps one phase")
            let offsets = (slide.values ?? []).compactMap { ($0 as? NSNumber)?.doubleValue }
            XCTAssertEqual(offsets.map(abs).max(), 16, "A value moves a whole line, so two never overlap")
        }
        view.update(entries: [.init(text: "57%", color: .white), .init(text: "81%", color: .white)], animates: true)
        let after = try XCTUnwrap(view.layer?.sublayers)
        XCTAssertTrue(zip(layers, after).allSatisfy { $0 === $1 }, "A new reading changes the text in place")
        for layer in after {
            XCTAssertEqual(try XCTUnwrap(layer.animation(forKey: "alternate")).beginTime, AlternatingQuotaText.epoch,
                "and the rotation keeps its running frame")
        }
    }

    func testRotatingValuesShrinkToFitANarrowStripInsteadOfClipping() {
        let font = NSFont.monospacedDigitSystemFont(ofSize: 11.5, weight: .semibold)
        let entries: [AlternatingQuotaText.Entry] = [.init(text: "1000%", color: .white, splitsUnit: false), .init(text: "¥86", color: .white)]
        let narrow = AlternatingQuotaText(entries: entries, animates: false, font: font, centered: true, maxWidth: 30)
        XCTAssertGreaterThan(AlternatingQuotaText(entries: entries, animates: false, font: font).widest, 30)
        let fitted = narrow.fitted
        XCTAssertLessThanOrEqual(fitted.widest, 30.01, "The longest reading fits its cell")
        XCTAssertLessThan(fitted.font.pointSize, 11.5)
        XCTAssertGreaterThanOrEqual(fitted.font.pointSize, 11.5 * AlternatingQuotaText.minimumScale - 0.001)
        XCTAssertTrue(fitted.font.fontDescriptor.symbolicTraits.contains(.bold) || fitted.font.fontName == font.fontName,
            "It keeps the same face")
        let roomy = AlternatingQuotaText(entries: [.init(text: "58%", color: .white, splitsUnit: false)], animates: false, font: font, maxWidth: 30).fitted
        XCTAssertEqual(roomy.font.pointSize, 11.5, "A value that fits keeps its size")
        let tiny = AlternatingQuotaText(entries: [.init(text: "100000000%", color: .white)], animates: false, font: font, maxWidth: 10).fitted
        XCTAssertEqual(tiny.font.pointSize, 11.5 * AlternatingQuotaText.minimumScale, accuracy: 0.001, "It stops at 60%, as the other numbers do")
    }

    func testPercentKeepsItsDigitsTogetherWithAGapBeforeTheUnit() {
        let text = AlternatingQuotaText(entries: [], animates: false)
        let value = text.attributed(.init(text: "298%", color: .white))
        XCTAssertEqual(value.string, "298%")
        let kerns = (0..<value.length).map { (value.attribute(.kern, at: $0, effectiveRange: nil) as? CGFloat) ?? 0 }
        XCTAssertEqual(Array(kerns.prefix(2)), [0, 0], "Digits keep their natural spacing")
        XCTAssertEqual(kerns[2], 1.5, accuracy: 0.001, "Only the last digit opens the gap before %")
        XCTAssertEqual(kerns[3], 0)
        let plain = text.attributed(.init(text: "¥86", color: .white))
        XCTAssertNil(plain.attribute(.kern, at: 1, effectiveRange: nil), "A value without a unit is not spaced")
    }

    func testRingsDimInStepWithTheValueOnlyWhenAsked() throws {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 40, height: 24), styleMask: .borderless, backing: .buffered, defer: false)
        let view = QuotaRingsView(frame: NSRect(x: 0, y: 0, width: 20, height: 20))
        window.contentView?.addSubview(view)
        func ring(_ provider: AgentProvider) -> QuotaRingsView.Ring {
            .init(tint: .systemTeal, remaining: 60, stale: false, time: 0.5, low: false, exhausted: false, provider: provider)
        }
        func draw(_ link: QuotaRingsGlyph.Link?, _ arrangement: QuotaRingsView.Arrangement = .concentric) {
            view.update(.init(rings: [ring(.codex), ring(.claude)], arrangement: arrangement, vertical: false,
                size: CGSize(width: 20, height: 20), unit: 1, tick: .white, attention: .systemOrange, danger: .systemRed, link: link))
        }
        draw(.init(order: [.codex, .claude], animates: false))
        XCTAssertEqual(view.linkOpacities, [1, 0.42], "The ring the value is not naming dims")
        draw(nil)
        XCTAssertEqual(view.linkOpacities, [1, 1], "Without linked dimming both rings stay at full strength")
        draw(.init(order: [.codex, .claude], animates: true), .split)
        XCTAssertEqual(view.linkOpacities, [1, 1], "One service's two windows never dim")
        draw(.init(order: [.codex, .claude], animates: true))
        let groups = try XCTUnwrap(view.layer?.sublayers)
        for group in groups {
            XCTAssertEqual(try XCTUnwrap(group.animation(forKey: "link")).beginTime, AlternatingQuotaText.epoch,
                "The rings follow the same clock as the value")
        }
    }
}
