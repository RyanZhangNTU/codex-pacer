import PacerMacSupport
import XCTest
@testable import PacerCore
@testable import PacerIsland
import PacerTestSupport

@MainActor
final class IslandMoveTests: XCTestCase {
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
        model.close()
        model.hover(true)
        XCTAssertTrue(model.expanded)
        model.setIslandMoving(true)
        model.hover(false)
        try await Task.sleep(nanoseconds: 600_000_000)
        XCTAssertTrue(model.expanded, "Leaving during a move must not start the collapse timer")
        model.setExpanded(false)
        model.hover(true)
        XCTAssertFalse(model.expanded, "Hover does not open the island while it moves")
        model.barClicked()
        XCTAssertFalse(model.pinned)
        model.setIslandMoving(false)
        model.barClicked()
        XCTAssertFalse(model.pinned, "The mouse-up that ends a drag is not a click")
        try await Task.sleep(nanoseconds: 400_000_000)
        model.barClicked()
        XCTAssertTrue(model.pinned)
        await model.shutdown()
    }

    func testClickModePinsUntilTheBarIsClickedAgain() async throws {
        let (model, _, name, directory) = try fixture()
        defer { removeTestDefaults(name); try? FileManager.default.removeItem(at: directory) }
        model.expandMode = .click
        let request = PendingAttentionRequest(id: "question", threadID: "019a0000-0000-7000-8000-000000000001",
            sourceHostID: nil, sourceName: nil, kind: .input, detectedAt: model.now)
        model.observeAttentionRequests([request])
        XCTAssertTrue(model.canOpen(request.activity))
        model.onOpenActivity = { _ in XCTFail("In click mode the activity badge opens the panel"); return .openedConversation }
        model.close()
        model.hover(true)
        XCTAssertFalse(model.expanded)
        var focused = false
        model.onFocusRequested = { focused = true }
        model.barClicked(.activity)
        XCTAssertTrue(model.expanded && model.pinned && focused)
        model.hover(false)
        try await Task.sleep(nanoseconds: 550_000_000)
        XCTAssertTrue(model.expanded && model.pinned)
        model.barClicked()
        XCTAssertFalse(model.expanded)
        XCTAssertFalse(model.pinned)

        model.setExpanded(true)
        model.hover(false)
        model.hover(true)
        try await Task.sleep(nanoseconds: 550_000_000)
        XCTAssertTrue(model.expanded, "Returning to an automatically opened panel cancels its pending close")
        XCTAssertFalse(model.pinned)
        model.hover(false)
        try await TestWait.until { !model.expanded }
        XCTAssertFalse(model.expanded)
        await model.shutdown()
    }

    func testHoverIsTheDefaultAndUnpinningStillWaitsForHoverExit() async throws {
        let (model, _, name, directory) = try fixture()
        defer { removeTestDefaults(name); try? FileManager.default.removeItem(at: directory) }
        XCTAssertEqual(model.expandMode, .hover)
        model.close()
        model.hover(true)
        XCTAssertTrue(model.expanded)
        XCTAssertFalse(model.pinned)
        model.barClicked()
        XCTAssertTrue(model.pinned)
        model.barClicked()
        XCTAssertFalse(model.pinned)
        XCTAssertTrue(model.expanded)
        model.hover(false)
        XCTAssertTrue(model.expanded)
        try await TestWait.until { !model.expanded }
        XCTAssertFalse(model.expanded)
        await model.shutdown()
    }

    func testOnlyAFloatingIslandMovesAndReturnToTopCenterForgetsThePlace() async throws {
        let (model, defaults, name, directory) = try fixture()
        defer { removeTestDefaults(name); try? FileManager.default.removeItem(at: directory) }
        model.isAttached = true
        XCTAssertFalse(model.canMoveIsland, "The notch island stays put")
        model.isAttached = false
        XCTAssertTrue(model.canMoveIsland)
        // Settings' button and the panel's share one rule: there must be a place to leave.
        XCTAssertFalse(model.canResetIslandPlacement, "Already at the top center")
        IslandPosition.topRight.save(to: defaults)
        XCTAssertTrue(model.canResetIslandPlacement, "A corner returns to the center")
        IslandPosition.center.save(to: defaults)

        IslandPlacement(edge: .right, x: 1, y: 0.4).save(to: defaults)
        XCTAssertTrue(model.canResetIslandPlacement, "A dragged place returns to the center")
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
        XCTAssertFalse(model.canResetIslandPlacement, "Nothing left to return from")
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
