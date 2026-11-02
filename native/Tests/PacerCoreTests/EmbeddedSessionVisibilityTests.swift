import XCTest
@testable import PacerCore

final class EmbeddedSessionVisibilityTests: XCTestCase {
    private func activity(_ number: Int, provider: AgentProvider = .codex, host: String? = nil, embedded: Bool = false, parent: Int? = nil) -> SessionActivity {
        func uuid(_ value: Int) -> String { String(format: "019a0000-0000-7000-8000-%012d", value) }
        let session = uuid(number)
        var value = SessionActivity(id: provider.activityID(sessionID: session, sourceHostID: host), sourceHostID: host, provider: provider, sessionID: session)
        if provider == .codex { value.setCodexOrigin(.init(embedded: embedded, ignored: false)) }
        else if provider == .claude { value.setClaudeLaunch(embedded: embedded) }
        if let parent { value.updateParent(uuid(parent)) }
        return value
    }
    func testDescendantsAreHiddenInAnyOrderWithoutChangingTheReaderBaseline() {
        for provider in [AgentProvider.codex, .claude] {
            let root = activity(1, provider: provider, embedded: true)
            let child = activity(2, provider: provider, parent: 1), grandchild = activity(3, provider: provider, parent: 2)
            let values = [grandchild, child, root, activity(4, provider: provider)]
            XCTAssertEqual(EmbeddedSessionVisibility.embeddedActivityIDs(values), Set([root.id, child.id, grandchild.id]))
            XCTAssertFalse(child.launchedByEmbeddingApp); XCTAssertFalse(grandchild.launchedByEmbeddingApp)
        }
    }
    func testProviderAndHostQualifiedFamiliesCannotHideEachOther() {
        let root = activity(1, embedded: true), child = activity(2, parent: 1)
        let remote = activity(2, host: "remote-ssh-discovered:other", parent: 1)
        let claude = activity(2, provider: .claude, parent: 1)
        XCTAssertEqual(EmbeddedSessionVisibility.embeddedActivityIDs([remote, claude, child, root]), Set([root.id, child.id]))
    }
    func testOfficialResumeRemovesTheFamilyFromTheHiddenSet() {
        var root = activity(1, embedded: true)
        let child = activity(2, parent: 1)
        XCTAssertEqual(EmbeddedSessionVisibility.embeddedActivityIDs([root, child]).count, 2)
        root.setCodexOrigin(.init(embedded: false, ignored: false))
        XCTAssertTrue(EmbeddedSessionVisibility.embeddedActivityIDs([child, root]).isEmpty)
    }
}
