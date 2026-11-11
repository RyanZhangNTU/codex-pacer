import PacerMacSupport
import XCTest
@testable import PacerCore
@testable import PacerIsland
import PacerTestSupport

@MainActor
final class IslandMoveTests: XCTestCase {
    func testSelectingOneOfTwoDisplaysWithTheSameUUID() {
        let first = DisplayIdentity.Display(number: 6, uuid: "shared")
        let second = DisplayIdentity.Display(number: 9, uuid: "shared")
        let displays = [first, second]
        XCTAssertEqual(DisplayIdentity.select(number: 9, uuid: "shared", twinIndex: nil, among: displays), 1)
        XCTAssertEqual(DisplayIdentity.select(number: 9, uuid: "shared", twinIndex: 1, among: [second, first]), 0)
        XCTAssertEqual(DisplayIdentity.select(number: 9, uuid: "shared", twinIndex: 1,
            among: [first, .init(number: 11, uuid: "shared")]), 1, "A new number still finds the saved display")
        XCTAssertNil(DisplayIdentity.select(number: 9, uuid: "shared", twinIndex: 1, among: [first]),
            "Unplugging the selected twin must leave its choice in place")
        XCTAssertEqual(DisplayIdentity.select(number: 9, uuid: "shared", twinIndex: nil,
            among: [.init(number: 9, uuid: "different"), first]), 1, "A reused number must match the saved UUID")
    }

    private func fixture() throws -> (IslandModel, UserDefaults, String, URL) {
        let name = testDefaultsName("island-move-tests")
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("pacer-island-move-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defaults.set(directory.path, forKey: "codexHome")
        defaults.set(directory.path, forKey: "claudeHome")
        let model = IslandModel(demo: true, demoArguments: nil, defaults: defaults,
            installation: .init(codexInstalled: false, claudeInstalled: false),
            completionDismissalStore: CompletionDismissalStore(fileURL: directory.appendingPathComponent("dismissals.json")))
        return (model, defaults, name, directory)
    }

    /// The panel reads the display mode from the standard defaults; float it
    /// for one test without writing a preference.
    private func floatTheStandardIsland() -> () -> Void {
        let registered = UserDefaults.standard.volatileDomain(forName: UserDefaults.registrationDomain)
        UserDefaults.standard.setVolatileDomain(registered.merging(["islandDisplayMode": "floating"]) { $1 },
                                                forName: UserDefaults.registrationDomain)
        return { UserDefaults.standard.setVolatileDomain(registered, forName: UserDefaults.registrationDomain) }
    }

    func testAMoveHoldsHoverAndTheClickThatEndsItDoesNotPin() async throws {
        let (model, _, name, directory) = try fixture()
        defer { removeTestDefaults(name); try? FileManager.default.removeItem(at: directory) }
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
        defer { removeTestDefaults(name); try? FileManager.default.removeItem(at: directory) }
        model.isAttached = true
        XCTAssertFalse(model.canMoveIsland, "The notch island stays put")
        model.isAttached = false
        XCTAssertTrue(model.canMoveIsland)

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

    func testADragIsCancelledOnlyWhenItsMouseUpStaysLost() async throws {
        let (model, defaults, name, directory) = try fixture()
        defer { removeTestDefaults(name); try? FileManager.default.removeItem(at: directory) }
        let restore = floatTheStandardIsland()
        defer { restore() }
        let controller = PanelController(model: model)
        defer { controller.stop() }
        // No button is held here, as just after a release whose mouse-up is still queued.
        model.onBeginMove?(CGPoint(x: 0.5, y: 0.5))
        XCTAssertTrue(model.islandMoving)
        model.onLayoutChange?()
        XCTAssertTrue(model.islandMoving, "A layout before the queued mouse-up must not drop the drop")
        try await TestWait.until { !model.islandMoving }
        XCTAssertFalse(model.islandMoving, "A mouse-up that never arrives ends the move")
        XCTAssertNil(IslandPlacement.load(from: defaults), "and nothing is saved")
        await model.shutdown()
    }
}
