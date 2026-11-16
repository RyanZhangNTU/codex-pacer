import XCTest
import PacerCore
@testable import PacerMacSupport

/// Which links and modules reach a module's own app. Only rejections are
/// checked here: an accepted link would look for the app installed on this Mac.
@MainActor
final class MacLocalHarnessApplicationTests: XCTestCase {
    private let session = "0f8fad5b-d9cb-469f-a165-70867728950e"

    func testOnlyTheModulesExactConversationLinkFindsItsApp() throws {
        let rejected = [
            "workbuddy-ai://chat/" + session,            // the other edition's scheme
            "workbuddy://open/" + session,                // not a conversation
            "workbuddy://chat/not-a-session",
            "workbuddy://chat/" + session.uppercased(),   // only the app's own lowercase spelling
            "workbuddy://chat/" + session + "?run=1",     // nothing added to the link
            "workbuddy://chat/" + session + "/extra",
            "https://chat/" + session,
        ]
        for link in rejected {
            let destination = try XCTUnwrap(URL(string: link))
            XCTAssertNil(MacLocalHarnessApplication.find(provider: .workbuddy, destination: destination), link)
        }
        // A provider without a local app of its own never opens one.
        let codex = try XCTUnwrap(URL(string: "workbuddy://chat/" + session))
        XCTAssertNil(MacLocalHarnessApplication.find(provider: .codex, destination: codex))
    }

    func testProvidersWithoutALocalAppHaveNoPresenceOrRunningCopy() async {
        for provider in [AgentProvider.codex, .claude, .deepseek] {
            XCTAssertNil(MacLocalHarnessApplication.presence(provider: provider), "\(provider)")
            XCTAssertNil(MacLocalHarnessApplication.running(provider: provider), "\(provider)")
            XCTAssertTrue(MacLocalHarnessApplication.runningAll(provider: provider).isEmpty, "\(provider)")
            let found = await MacLocalHarnessApplication.find(provider: provider)
            XCTAssertNil(found, "\(provider)")
            let opened = await MacLocalHarnessApplication.openProgressConnectors(provider: provider)
            XCTAssertFalse(opened, "\(provider)")
        }
    }

    func testEveryRunningCopyBelongsToTheModule() throws {
        let definition = try XCTUnwrap(HarnessRegistry.localHarnesses.first { $0.descriptor.id == .workbuddy })
        // Whatever runs on this Mac, each copy listed is one of the module's own bundles.
        for app in MacLocalHarnessApplication.runningAll(provider: .workbuddy) {
            XCTAssertTrue(app.bundleIdentifier.map(definition.macBundleIdentifiers.contains) == true)
            XCTAssertFalse(app.isTerminated)
        }
        switch MacLocalHarnessApplication.presence(provider: .workbuddy) {
        case .notRunning?: XCTAssertTrue(MacLocalHarnessApplication.runningAll(provider: .workbuddy).isEmpty)
        case .running?: XCTAssertFalse(MacLocalHarnessApplication.runningAll(provider: .workbuddy).isEmpty)
        case nil: XCTAssertTrue(definition.macBundleIdentifiers.isEmpty)
        }
    }
}
