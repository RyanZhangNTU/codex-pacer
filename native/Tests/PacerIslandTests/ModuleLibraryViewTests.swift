import AppKit
import SwiftUI
import XCTest
import PacerCore
@testable import PacerIsland

@MainActor
final class ModuleLibraryViewTests: XCTestCase {
    private func library(installed: Set<AgentProvider>, supported: [AgentProvider] = AgentProvider.allCases) -> ModuleLibrary {
        var modules = ProviderModules()
        modules.setMode(.disabled, for: .claude)
        modules.setMode(.enabled, for: .deepseek)
        return ModuleLibrary(modules: modules, detection: .init(installed: installed), supported: supported)
    }

    func testBothGroupsShowTheirTilesAndEachControlPerformsOnlyItsOwnAction() async throws {
        let library = library(installed: [.codex, .claude, .antigravity])
        XCTAssertEqual(library.notFound.map(\.provider), [.deepseek, .workbuddy, .workbuddyAI])
        for dark in [false, true] {
            var opened: [AgentProvider] = [], toggled: [AgentProvider] = [], sites: [URL] = []
            let window = try await host(library, dark: dark, open: { opened.append($0) }, toggle: { toggled.append($0) },
                                        get: { sites.append($0) })
            defer { window.close() }
            let root = try XCTUnwrap(window.contentView)
            for entry in library.entries {
                let name = entry.provider.settingsTitle
                let body = try XCTUnwrap(element(name, role: .button, in: root))
                XCTAssertEqual(value(of: body), L10n.text(entry.state.labelKey))
                XCTAssertNotNil(element(L10n.text("main.info", name), role: .button, in: root))
                XCTAssertNotNil(element(L10n.text(entry.enabled ? "modules.turn_off" : "modules.turn_on", name), role: .button, in: root))
                XCTAssertNil(element(L10n.text(entry.summaryKey), in: root))
                // The Get link lives behind the ⓘ with the summary.
                XCTAssertNil(element(L10n.text("modules.get", name), in: root))
            }
            XCTAssertNil(element(L10n.text("main.info", L10n.text("modules.on_this_computer")), in: root))
            let missingHeader = try XCTUnwrap(element(L10n.text("modules.not_found"), in: root))
            let last = try XCTUnwrap(element(AgentProvider.workbuddyAI.settingsTitle, role: .button, in: root))
            let more = try XCTUnwrap(element(L10n.text("modules.more_coming"), role: .staticText, in: root))
            // AppKit screen coordinates increase upwards. With three missing modules,
            // the placeholder follows the third on the second row.
            XCTAssertGreaterThan(missingHeader.accessibilityFrame().minY, last.accessibilityFrame().maxY)
            XCTAssertGreaterThan(more.accessibilityFrame().minX, last.accessibilityFrame().maxX)
            XCTAssertTrue(last.accessibilityFrame().minY...last.accessibilityFrame().maxY ~= more.accessibilityFrame().midY)
            try save(root, dark: dark, expanded: false)

            let entry = try XCTUnwrap(library.notFound.first)
            let name = entry.provider.settingsTitle
            let info = L10n.text("main.info", name)
            try await press(info, in: root)
            XCTAssertNotNil(element(L10n.text(entry.summaryKey), role: .staticText, in: root))
            XCTAssertNotNil(element(L10n.text("modules.get", name), in: root))
            try save(root, dark: dark, expanded: true)
            try await press(L10n.text("modules.get", name), in: root)
            XCTAssertEqual(sites, [try XCTUnwrap(entry.website)])
            try await press(info, in: root)
            XCTAssertNil(element(L10n.text(entry.summaryKey), in: root))
            XCTAssertNil(element(L10n.text("modules.get", name), in: root))
            try await press(L10n.text("modules.turn_off", name), in: root)
            try await press(L10n.text("modules.turn_on", AgentProvider.claude.settingsTitle), in: root)
            XCTAssertEqual(toggled, [entry.provider, .claude])
            XCTAssertEqual(opened, [])
            try await press(name, in: root)
            XCTAssertEqual(opened, [entry.provider])
        }
    }

    func testPointerTargetsInsideTheTileAndThePlaceholder() async throws {
        let library = library(installed: [], supported: [.codex])
        let name = AgentProvider.codex.settingsTitle
        var opened: [AgentProvider] = [], toggled: [AgentProvider] = [], sites: [URL] = []
        let window = try await host(library, dark: false, open: { opened.append($0) }, toggle: { toggled.append($0) },
                                    get: { sites.append($0) })
        defer { window.close() }
        let root = try XCTUnwrap(window.contentView)
        func click(_ title: String) async throws {
            let frame = try XCTUnwrap(element(title, in: root), title).accessibilityFrame()
            let point = window.convertPoint(fromScreen: NSPoint(x: frame.midX, y: frame.midY))
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                let event = try XCTUnwrap(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                    timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                    context: nil, eventNumber: 1, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0))
                window.sendEvent(event)
            }
            try await Task.sleep(for: .milliseconds(180))
            root.layoutSubtreeIfNeeded()
        }

        try await click(L10n.text("main.info", name))
        let entry = try XCTUnwrap(library.entries.first)
        XCTAssertNotNil(element(L10n.text(entry.summaryKey), in: root))
        try await click(L10n.text("modules.get", name))
        try await click(L10n.text("modules.turn_on", name))
        try await click(L10n.text("modules.more_coming"))
        XCTAssertEqual(sites, [try XCTUnwrap(entry.website)])
        XCTAssertEqual(toggled, [.codex])
        XCTAssertEqual(opened, [])
        try await click(name)
        XCTAssertEqual(opened, [.codex])
    }

    func testLastVisibleGroupOwnsOnePlainTextPlaceholderEvenForAnEmptyCatalog() async throws {
        for (supported, installed) in [([AgentProvider.codex], [AgentProvider.codex]), ([.codex], []), ([], [])] {
            let library = library(installed: Set(installed), supported: supported)
            let window = try await host(library, dark: false)
            defer { window.close() }
            let root = try XCTUnwrap(window.contentView)
            XCTAssertEqual(element(L10n.text("modules.empty"), in: root) != nil, library.found.isEmpty)
            XCTAssertEqual(element(L10n.text("modules.not_found"), in: root) != nil, !library.notFound.isEmpty)
            let title = L10n.text("modules.more_coming")
            XCTAssertEqual(elements(in: root).filter { matches(title, $0) }.count, 1)
            let more = try XCTUnwrap(element(title, role: .staticText, in: root))
            if let entry = library.entries.first {
                let tile = try XCTUnwrap(element(entry.provider.settingsTitle, role: .button, in: root))
                XCTAssertGreaterThan(more.accessibilityFrame().minX, tile.accessibilityFrame().maxX)
                XCTAssertTrue(tile.accessibilityFrame().minY...tile.accessibilityFrame().maxY ~= more.accessibilityFrame().midY)
            }
        }
    }

    private func host(_ library: ModuleLibrary, dark: Bool, open: @escaping (AgentProvider) -> Void = { _ in },
                      toggle: @escaping (AgentProvider) -> Void = { _ in }, get: @escaping (URL) -> Void = { _ in }) async throws -> NSWindow {
        let page = VStack(alignment: .leading, spacing: 22) {
            PageHeader(title: SettingsPane.modules.title)
            SettingsModuleLibraryPane(library: library, open: open, toggle: toggle)
        }
        .padding(.horizontal, 32).padding(.top, 22)
        .frame(width: 704, height: 450, alignment: .topLeading)
        .background(MainPalette.page)
        .pacerAccent(.blue)
        .environment(\.openURL, OpenURLAction { get($0); return .handled })
        .environment(\.accessibilityEnabled, true)
        .environment(\.controlActiveState, .key)
        .environment(\.colorScheme, dark ? .dark : .light)

        let frame = NSRect(x: -20_000, y: -20_000, width: 704, height: 450)
        let window = NSWindow(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.contentView = NSHostingView(rootView: page)
        window.setFrame(frame, display: true)
        window.orderBack(nil)
        try await Task.sleep(for: .milliseconds(100))
        window.contentView?.layoutSubtreeIfNeeded()
        return window
    }

    private func elements(in root: AnyObject) -> [AnyObject] {
        [root] + (root.accessibilityChildren?() ?? []).flatMap { elements(in: $0 as AnyObject) }
    }

    private func value(of element: AnyObject) -> String? {
        element.accessibilityValue?()
    }

    private func matches(_ text: String, _ element: AnyObject) -> Bool {
        element.accessibilityLabel?() == text || value(of: element) == text
    }

    private func element(_ text: String, role: NSAccessibility.Role? = nil, in root: AnyObject) -> AnyObject? {
        elements(in: root).first { matches(text, $0) && (role == nil || $0.accessibilityRole?() == role) }
    }

    private func press(_ title: String, in root: NSView) async throws {
        let control = try XCTUnwrap(element(title, in: root), title)
        XCTAssertEqual(control.accessibilityPerformPress?(), true, title)
        try await Task.sleep(for: .milliseconds(180))
        root.layoutSubtreeIfNeeded()
    }

    private func save(_ view: NSView, dark: Bool, expanded: Bool) throws {
        guard let path = ProcessInfo.processInfo.environment["PACER_MODULE_LIBRARY_QA_OUTPUT"] else { return }
        let directory = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        let name = L10n.language.rawValue + (dark ? "-dark" : "-light") + (expanded ? "-info.png" : ".png")
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: directory.appendingPathComponent(name))
    }
}
