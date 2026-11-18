import AppKit
import Combine
import XCTest
import PacerTestSupport
@testable import PacerCore
@testable import PacerIsland

@MainActor
final class PinnedChatIslandTests: XCTestCase {
    private typealias Group = PinnedConversationGroups.Group
    private func fixture(demo: Bool, enabled: Bool = true) throws -> (IslandModel, UserDefaults, URL) {
        let domain = testDefaultsName("pinned-chats")
        let defaults = try XCTUnwrap(UserDefaults(suiteName: domain))
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        addTeardownBlock { removeTestDefaults(domain); try? FileManager.default.removeItem(at: home) }
        defaults.set(home.path, forKey: "codexHome")
        defaults.set(false, forKey: "monitorSSH")
        defaults.set(false, forKey: "monitorRemoteControl")
        defaults.set(enabled, forKey: IslandModel.pinnedChatsKey)
        ProviderModules(codexMode: .enabled, claudeMode: .disabled).save(to: defaults)
        return (IslandModel(demo: demo, defaults: defaults, installation: .init(codexInstalled: true, claudeInstalled: false),
            completionDismissalStore: .init(fileURL: home.appendingPathComponent("dismissals.json"))), defaults, home)
    }

    func testCatalogWatchesColdPinsAndKeepsFailuresScopedToOneProfile() async throws {
        let (model, defaults, home) = try fixture(demo: false, enabled: false)
        XCTAssertNil(model.pinProfile)
        XCTAssertFalse(model.showsPinnedChats)
        let file = home.appendingPathComponent(".codex-global-state.json")
        func write(_ pins: [String]) throws {
            try JSONSerialization.data(withJSONObject: ["pinned-thread-ids": pins]).write(to: file, options: .atomic)
        }
        let first = CodexPinnedThreads.demoEntries[0].id, next = CodexPinnedThreads.demoEntries[1].id
        try write([first])
        defaults.set(true, forKey: IslandModel.pinnedChatsKey); model.syncPinnedChats()
        model.refreshActivity()
        let initialRead = try await TestWait.until { model.pinnedChatRows.map(\.activity.threadID) == [first] }
        XCTAssertTrue(initialRead)
        XCTAssertTrue(model.activities.isEmpty)
        let original = try XCTUnwrap(model.pinProfile)
        model.saveChatGroups([.init(id: "g", name: "Fixture", members: ["local:" + first], collapsed: true)], profile: original)
        XCTAssertNotNil(defaults.string(forKey: "conversationGroups"))
        model.togglePinnedView(); XCTAssertFalse(model.showsPinnedChats)
        model.togglePinnedView(); XCTAssertTrue(model.showsPinnedChats)
        try write([next])
        let changed = try await TestWait.until { model.pinnedChatRows.map(\.activity.threadID) == [next] }
        XCTAssertTrue(changed)
        try Data("invalid".utf8).write(to: file, options: .atomic)
        let unavailable = try await TestWait.until { !model.pinCatalog.available }
        XCTAssertTrue(unavailable)
        XCTAssertEqual(model.pinnedChatRows.map(\.activity.threadID), [next])
        let other = home.appendingPathComponent("other", isDirectory: true)
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        defaults.set(other.path, forKey: "codexHome"); model.syncPinnedChats()
        XCTAssertNotEqual(model.pinProfile, original)
        XCTAssertTrue(model.pinnedChatRows.isEmpty); XCTAssertTrue(model.savedChatGroups.isEmpty)
        model.saveChatGroups([], profile: original)
        defaults.set(home.path, forKey: "codexHome"); model.syncPinnedChats()
        XCTAssertEqual(model.savedChatGroups.first?.name, "Fixture")
        XCTAssertEqual(model.savedChatGroups.first?.collapsed, true)
        defaults.set(false, forKey: IslandModel.pinnedChatsKey); model.syncPinnedChats()
        XCTAssertNil(model.pinWatcher); XCTAssertNil(model.pinProfile)
        await model.shutdown()
    }

    func testColdHiddenPinIsClassifiedBeforeItsFirstCatalogPublication() async throws {
        let (model, _, home) = try fixture(demo: false)
        let id = CodexPinnedThreads.demoEntries[0].id
        let localID = AgentProvider.codex.activityID(sessionID: id)
        let date = DateFormatter(); date.dateFormat = "yyyy/MM/dd"
        let directory = home.appendingPathComponent("sessions/" + date.string(from: Date()))
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let header: [String: Any] = ["type": "session_meta", "timestamp": ISO8601DateFormatter().string(from: Date()),
            "payload": ["id": id, "originator": "fixture-client", "cwd": "/fixture/zotero-chat/translate"]]
        var data = try JSONSerialization.data(withJSONObject: header); data.append(10)
        try data.write(to: directory.appendingPathComponent("rollout-" + id + ".jsonl"))
        try JSONSerialization.data(withJSONObject: ["pinned-thread-ids": [id]])
            .write(to: home.appendingPathComponent(".codex-global-state.json"))
        var published: [IslandPinnedCatalog] = []
        let observer = model.$pinCatalog.sink { catalog in
            if catalog.entries.contains(where: { $0.id == id }) { published.append(catalog) }
        }
        defer { observer.cancel() }
        model.refreshActivity()
        let found = try await TestWait.until { !published.isEmpty }
        XCTAssertTrue(found)
        XCTAssertTrue(published.allSatisfy { $0.hidden.contains(localID) })
        XCTAssertTrue(model.pinnedChatRows.isEmpty)
        await model.shutdown()
    }

    func testNativeOutlineDropTargetsMoveReorderMergeAndUngroup() async throws {
        let (model, _, _) = try fixture(demo: true)
        let ids = CodexPinnedThreads.demoEntries.map { "local:" + $0.id }
        let owner = PinnedChatOutline.Coordinator(model), scroll = owner.makeScrollView()
        let table = owner.outline
        let window = NSWindow(contentRect: NSRect(x: 60, y: 60, width: 400, height: 360), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = scroll
        defer { owner.finish(); window.close() }
        func redraw() {
            let rows = model.pinnedChatRows
            owner.update(.init(model: model, rows: rows, sections: PinnedConversationGroups.sections(
                model.savedChatGroups, ids: rows.map(\.activity.id), running: [])))
            scroll.layoutSubtreeIfNeeded()
        }
        func index(_ key: PinnedChatOutline.Key) throws -> Int {
            try XCTUnwrap((0..<table.numberOfRows).first { (table.item(atRow: $0) as? PinnedChatOutline.Node)?.key == key })
        }
        func drag(_ source: PinnedChatOutline.Key, to target: PinnedChatOutline.Key, after: Bool = false, merge: Bool = false) throws {
            let item = try XCTUnwrap(table.item(atRow: try index(source)))
            let writer = try XCTUnwrap(owner.outlineView(table, pasteboardWriterForItem: item) as? NSPasteboardItem)
            let token = try XCTUnwrap(writer.string(forType: try XCTUnwrap(writer.types.first)))
            let rect = table.rect(ofRow: try index(target))
            let point = table.convert(NSPoint(x: rect.midX, y: rect.midY + (after ? 3 : -3)), to: nil)
            owner.beginLocalDrag()
            XCTAssertTrue(model.pinInteraction)
            XCTAssertEqual(owner.drop(from: nil, token: token, at: point, merge: merge, commit: true), [])
            XCTAssertEqual(owner.drop(from: table, token: "foreign", at: point, merge: merge, commit: true), [])
            XCTAssertEqual(owner.drop(from: table, token: token, at: point, merge: merge, commit: false), .move)
            XCTAssertEqual(owner.drop(from: table, token: token, at: point, merge: merge, commit: true), .move)
            owner.endLocalDrag(); redraw()
        }
        redraw()
        try drag(.chat(ids[0]), to: .chat(ids[1]))
        let first = try XCTUnwrap(model.savedChatGroups.first?.id)
        XCTAssertEqual(model.savedChatGroups.first?.members, [ids[0], ids[1]])
        try drag(.chat(ids[1]), to: .chat(ids[2]))
        let second = try XCTUnwrap(model.savedChatGroups.last?.id)
        XCTAssertNotEqual(first, second)
        try drag(.group(first), to: .group(second), after: true)
        XCTAssertEqual(model.savedChatGroups.map(\.id), [second, first])
        try drag(.group(first), to: .group(second), merge: true)
        XCTAssertEqual(model.savedChatGroups.map(\.members), [[ids[1], ids[2], ids[0]]])
        try drag(.chat(ids[2]), to: .group(nil))
        XCTAssertEqual(model.savedChatGroups.first?.members, [ids[1], ids[0]])
        XCTAssertFalse(model.pinInteraction)
        await model.shutdown()
    }

    func testNativeOutlineDisclosureRenameAndFrozenOrder() async throws {
        let (model, defaults, _) = try fixture(demo: true)
        let pins = CodexPinnedThreads.demoEntries.map { "local:" + $0.id }
        let profile = try XCTUnwrap(model.pinProfile)
        let groups = [Group(id: "first", name: "First fixture", members: [pins[0], pins[1]]),
                      Group(id: "second", name: "Second fixture", members: [pins[2]])]
        model.saveChatGroups(groups, profile: profile)
        let coordinator = PinnedChatOutline.Coordinator(model)
        let scroll = coordinator.makeScrollView()
        let window = NSWindow(contentRect: NSRect(x: 60, y: 60, width: 400, height: 360), styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = scroll
        defer { coordinator.finish(); window.orderOut(nil); window.close() }
        func update(running: Set<String> = []) {
            let rows = model.pinnedChatRows
            coordinator.update(.init(model: model, rows: rows,
                sections: PinnedConversationGroups.sections(model.savedChatGroups, ids: rows.map(\.activity.id), running: running)))
            scroll.layoutSubtreeIfNeeded()
        }
        update()
        let outline = coordinator.outline
        let first = try XCTUnwrap(outline.item(atRow: 0))
        XCTAssertEqual(outline.numberOfRows, 6)
        outline.collapseItem(first)
        XCTAssertEqual(model.savedChatGroups[0].collapsed, true)
        outline.expandItem(first)
        XCTAssertEqual(model.savedChatGroups[0].collapsed, false)
        let cell = try XCTUnwrap(outline.view(atColumn: 0, row: 0, makeIfNecessary: true) as? PinnedChatOutline.Cell)
        XCTAssertTrue(cell.accessibilityPerformPress())
        let field = try XCTUnwrap(cell.textField)
        XCTAssertTrue(field.isEditable); XCTAssertTrue(model.pinInteraction)
        update(running: [pins[2]])
        XCTAssertTrue((outline.item(atRow: 0) as AnyObject) === (first as AnyObject))
        let limit = String(repeating: "a", count: 62) + "🌱"
        field.stringValue = limit + "x"
        coordinator.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: field))
        XCTAssertEqual(field.stringValue, limit)
        field.stringValue = "Renamed fixture"
        coordinator.controlTextDidEndEditing(Notification(name: NSControl.textDidEndEditingNotification, object: field))
        XCTAssertEqual(model.savedChatGroups[0].name, "Renamed fixture")
        XCTAssertFalse(model.pinInteraction)
        update(running: [pins[2]])
        XCTAssertEqual((outline.item(atRow: 0) as? PinnedChatOutline.Node)?.key, .group("second"))
        update()
        XCTAssertEqual((outline.item(atRow: 0) as? PinnedChatOutline.Node)?.key, .group("first"))
        defaults.set(true, forKey: "hideProjects"); update()
        let hidden = try XCTUnwrap(outline.view(atColumn: 0, row: 0, makeIfNecessary: true) as? PinnedChatOutline.Cell)
        XCTAssertFalse(hidden.accessibilityPerformPress())
        XCTAssertFalse(hidden.textField?.stringValue.contains("Renamed fixture") == true)
        XCTAssertTrue(model.pinnedChatRows.allSatisfy { $0.title == L10n.text("activity.hidden_name") })
        XCTAssertNil(defaults.string(forKey: "conversationGroups"), "Demo edits are in memory")
        await model.shutdown()
    }
}
