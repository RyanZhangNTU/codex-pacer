import PacerMacSupport
import XCTest
@testable import PacerCore
@testable import PacerIsland

@MainActor
final class IslandMoveTests: XCTestCase {
    private func fixture() throws -> (IslandModel, UserDefaults, String, URL) {
        let name = "com.codexpacer.island-move-tests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defaults.set(directory.path, forKey: "codexHome")
        defaults.set(directory.path, forKey: "claudeHome")
        let model = IslandModel(demo: true, demoArguments: nil, defaults: defaults,
            installation: .init(codexInstalled: false, claudeInstalled: false),
            completionDismissalStore: CompletionDismissalStore(fileURL: directory.appendingPathComponent("dismissals.json")))
        return (model, defaults, name, directory)
    }

    func testAMoveHoldsHoverAndTheClickThatEndsItDoesNotPin() async throws {
        let (model, defaults, name, directory) = try fixture()
        defer { defaults.removePersistentDomain(forName: name); try? FileManager.default.removeItem(at: directory) }
        model.hover(true)
        XCTAssertTrue(model.expanded)
        model.setIslandMoving(true)
        model.hover(false)
        try await Task.sleep(nanoseconds: 600_000_000)
        XCTAssertTrue(model.expanded, "Leaving during a move must not start the collapse timer")
        model.setExpanded(false)
        model.hover(true)
        XCTAssertFalse(model.expanded, "Hover does not open the island while it moves")
        var clicks = 0
        model.barClicked { clicks += 1 }
        model.setIslandMoving(false)
        model.barClicked { clicks += 1 }
        XCTAssertEqual(clicks, 0, "The mouse-up that ends a drag is not a click")
        try await Task.sleep(nanoseconds: 400_000_000)
        model.barClicked { clicks += 1 }
        XCTAssertEqual(clicks, 1)
        await model.shutdown()
    }

    func testOnlyAFloatingIslandMovesAndReturnToTopCenterForgetsThePlace() async throws {
        let (model, defaults, name, directory) = try fixture()
        defer { defaults.removePersistentDomain(forName: name); try? FileManager.default.removeItem(at: directory) }
        var started: [CGPoint?] = []
        model.onBeginMove = { started.append($0) }
        model.isAttached = true
        XCTAssertFalse(model.canMoveIsland, "The notch island stays put")
        model.beginKeyboardMove()
        XCTAssertTrue(started.isEmpty)
        model.isAttached = false
        model.beginKeyboardMove()
        XCTAssertEqual(started.count, 1); XCTAssertNil(started[0], "The keyboard move has no grab point")

        IslandPlacement(edge: .right, x: 1, y: 0.4).save(to: defaults)
        IslandPosition.bottomLeft.save(to: defaults)
        IslandDisplayMode.automatic.save(to: defaults)
        var layouts = 0
        model.onLayoutChange = { layouts += 1 }
        let revision = model.placementRevision
        model.resetIslandPlacement()
        XCTAssertNil(IslandPlacement.load(from: defaults))
        XCTAssertEqual(IslandPosition.saved(in: defaults), .center)
        XCTAssertEqual(IslandDisplayMode.load(from: defaults), .floating)
        XCTAssertEqual(model.placementRevision, revision + 1, "An open Settings window rereads the place")
        XCTAssertEqual(layouts, 1)
        await model.shutdown()
    }
}
