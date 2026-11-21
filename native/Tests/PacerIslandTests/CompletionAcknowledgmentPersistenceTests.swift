import PacerMacSupport
import XCTest
import PacerCore
@testable import PacerIsland
import PacerTestSupport

@MainActor
final class CompletionAcknowledgmentPersistenceTests: XCTestCase {
    private struct FamilyFixture {
        let model: IslandModel
        let defaults: UserDefaults
        let file: URL
        let host: String?
        @MainActor func rebuild() -> IslandModel {
            IslandModel(demo: true, demoArguments: nil, defaults: defaults,
                installation: ProviderInstallationDetection(codexInstalled: false, claudeInstalled: false),
                completionDismissalStore: CompletionDismissalStore(fileURL: file))
        }
    }
    private func familyFixture(remote: Bool = false) throws -> FamilyFixture {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("pacer-family-ack-" + UUID().uuidString)
        let domain = testDefaultsName("family-ack-tests")
        let defaults = try XCTUnwrap(UserDefaults(suiteName: domain))
        addTeardownBlock { removeTestDefaults(domain); try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defaults.set(directory.path, forKey: "codexHome")
        defaults.set(directory.appendingPathComponent("claude-home").path, forKey: "claudeHome")
        defaults.set("family-fixture", forKey: "claudeSSHHosts")
        defaults.set(0, forKey: "completedRetentionMinutes")
        ProviderModules(codexMode: .enabled, claudeMode: .enabled).save(to: defaults)
        let host = "remote-ssh-discovered:family-fixture"
        try JSONSerialization.data(withJSONObject: ["codex-managed-remote-connections": [["source": "discovered", "hostId": host, "alias": "family-fixture"]],
            "remote-connection-auto-connect-by-host-id": [host: true]]).write(to: directory.appendingPathComponent(".codex-global-state.json"))
        let file = directory.appendingPathComponent("dismissals.json")
        let model = IslandModel(demo: true, demoArguments: nil, defaults: defaults,
            installation: ProviderInstallationDetection(codexInstalled: false, claudeInstalled: false), completionDismissalStore: CompletionDismissalStore(fileURL: file))
        return FamilyFixture(model: model, defaults: defaults, file: file, host: remote ? host : nil)
    }
    private func familyActivity(_ provider: AgentProvider, _ number: Int, parent: String? = nil, host: String? = nil,
                                turn: String = "family-turn", completed: Bool = true, at: Date) -> SessionActivity {
        let session = String(format: "019a0000-0000-7000-8000-%012d", number)
        var value = SessionActivity(id: provider.activityID(sessionID: session, sourceHostID: host), sourceHostID: host, provider: provider)
        if let parent { value.applyRuntime(["method": "metadata", "threadId": session, "parentThreadId": parent, "at": at.timeIntervalSince1970]) }
        value.applyRuntime(["method": "turn/started", "threadId": session, "turnId": turn, "at": at.timeIntervalSince1970])
        if completed { value.applyRuntime(["method": "turn/completed", "threadId": session, "turnId": turn, "status": "completed", "at": at.timeIntervalSince1970 + 0.5]) }
        return value
    }
    private func publishFamily(_ values: [SessionActivity], to model: IslandModel) {
        model.receiveClaudeUpdate(values.filter { $0.provider == .claude }, statuses: [:], requests: [])
        model.receiveRemoteUpdate(values.filter { $0.provider == .codex }, statuses: [:], unavailable: [], requests: [], names: [])
    }

    func testMarkAllReadPersistsVisibleEndedFamiliesAcrossProvidersHostsAndPages() async throws {
        let fixture = try familyFixture(remote: true), model = fixture.model
        let at = Date().addingTimeInterval(-3)
        let parent = familyActivity(.codex, 970, at: at)
        let child = familyActivity(.codex, 971, parent: parent.threadID, at: at)
        let claude = familyActivity(.claude, 972, host: fixture.host, at: at)
        var interrupted = familyActivity(.codex, 973, completed: false, at: at)
        interrupted.applyRuntime(["method": "turn/completed", "threadId": interrupted.threadID!, "turnId": "family-turn",
            "status": "interrupted", "at": at.timeIntervalSince1970 + 1])
        var failed = familyActivity(.claude, 974, completed: false, at: at)
        failed.applyRuntime(["method": "turn/completed", "threadId": failed.threadID!, "turnId": "family-turn",
            "status": "failed", "at": at.timeIntervalSince1970 + 1])
        let activeParent = familyActivity(.claude, 975, at: at)
        let activeChild = familyActivity(.claude, 976, parent: activeParent.threadID, completed: false, at: at)
        let reply = familyActivity(.codex, 977, at: at)
        var hidden = familyActivity(.codex, 978, at: at)
        hidden.setCodexOrigin(.init(embedded: true, ignored: false))
        fixture.defaults.set(false, forKey: IslandModel.showsEmbeddedCodexSessionsKey)
        let values = [parent, child, claude, interrupted, failed, activeParent, activeChild, reply, hidden]
        let request = PendingAttentionRequest(id: "still-needs-reply", threadID: reply.threadID!, sourceHostID: nil,
            sourceName: nil, kind: .input, detectedAt: at)
        func publish(_ model: IslandModel) {
            model.receiveClaudeUpdate(values.filter { $0.provider == .claude }, statuses: [:], requests: [])
            model.receiveRemoteUpdate(values.filter { $0.provider == .codex }, statuses: [:], unavailable: [], requests: [request], names: [])
        }
        publish(model)
        XCTAssertTrue(model.canMarkAllRead)
        XCTAssertGreaterThan(model.visibleActivities.count, 3, "The action covers more than one task page")
        var opens = 0
        model.onOpenActivity = { _ in opens += 1; return .openedConversation }
        model.markAllRead()
        let removed = Set([parent, child, claude, interrupted, failed].map(\.id))
        XCTAssertTrue(removed.isDisjoint(with: Set(model.activities.map(\.id))))
        XCTAssertEqual(Set(model.activities.map(\.id)), Set([activeParent, activeChild, reply].map(\.id)))
        XCTAssertEqual(model.pendingInputRequests, [request])
        XCTAssertFalse(model.canMarkAllRead)
        XCTAssertEqual(opens, 0, "Explicit acknowledgment never opens conversations")
        model.markAllRead()
        publish(model)
        XCTAssertTrue(removed.isDisjoint(with: Set(model.activities.map(\.id))), "Reader replay cannot restore acknowledged endings")
        await model.shutdown()
        let rebuilt = fixture.rebuild()
        publish(rebuilt)
        XCTAssertTrue(removed.isDisjoint(with: Set(rebuilt.activities.map(\.id))), "The acknowledgment survives relaunch")
        fixture.defaults.set(true, forKey: IslandModel.showsEmbeddedCodexSessionsKey)
        rebuilt.refilterEmbeddedSessions()
        XCTAssertTrue(rebuilt.isUnreadCompletion(hidden), "Hidden tasks were not acknowledged")
        var next = parent
        next.applyRuntime(["method": "turn/started", "threadId": parent.threadID!, "turnId": "next-turn", "at": Date().timeIntervalSince1970])
        next.applyRuntime(["method": "turn/completed", "threadId": parent.threadID!, "turnId": "next-turn", "status": "completed", "at": Date().timeIntervalSince1970])
        rebuilt.receiveRemoteUpdate([next], statuses: [:], unavailable: [], requests: [], names: [])
        XCTAssertTrue(rebuilt.isUnreadCompletion(next), "A new ending remains unread")
        await rebuilt.shutdown()
    }

    func testOnlyActualConversationOpenPersistsAcrossModelReconstructionForBothProvidersAndHosts() async throws {
        for provider in HarnessRegistry.legacyIDs {
            for sourceHostID in [nil, "remote-ssh-discovered:synthetic-ack"] as [String?] where provider != .deepseek || sourceHostID == nil {
                for outcome in [ActivityOpenOutcome.openedConversation, .dispatchedTerminal, .failed("Synthetic failure")] {
                    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("pacer-model-ack-" + UUID().uuidString)
                    let domain = testDefaultsName("ack-tests")
                    let defaults = try XCTUnwrap(UserDefaults(suiteName: domain))
                    defer { removeTestDefaults(domain); try? FileManager.default.removeItem(at: directory) }
                    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                    defaults.set(directory.path, forKey: "codexHome")
                    defaults.set(directory.appendingPathComponent("claude-home").path, forKey: "claudeHome")
                    defaults.set("synthetic-ack", forKey: "claudeSSHHosts")
                    defaults.set(0, forKey: "completedRetentionMinutes")
                    ProviderModules(codexMode: .enabled, claudeMode: .enabled, deepseekMode: .enabled).save(to: defaults)
                    let host = "remote-ssh-discovered:synthetic-ack"
                    let configuration: [String: Any] = [
                        "codex-managed-remote-connections": [["source": "discovered", "hostId": host, "alias": "synthetic-ack"]],
                        "remote-connection-auto-connect-by-host-id": [host: true]]
                    try JSONSerialization.data(withJSONObject: configuration).write(to: directory.appendingPathComponent(".codex-global-state.json"))
                    let file = directory.appendingPathComponent("dismissals.json")
                    let started = Date().addingTimeInterval(-2), session = "019a0000-0000-7000-8000-000000000903"
                    var ended = SessionActivity(id: provider.activityID(sessionID: session, sourceHostID: sourceHostID),
                        sourceHostID: sourceHostID, provider: provider)
                    ended.applyRuntime(["method": "turn/started", "threadId": session, "turnId": "synthetic-turn", "at": started.timeIntervalSince1970])
                    ended.applyRuntime(["method": "turn/completed", "threadId": session, "turnId": "synthetic-turn", "status": "completed", "at": started.timeIntervalSince1970 + 1])
                    func makeModel() -> IslandModel {
                        IslandModel(demo: true, demoArguments: nil, defaults: defaults,
                            installation: ProviderInstallationDetection(codexInstalled: false, claudeInstalled: false),
                            completionDismissalStore: CompletionDismissalStore(fileURL: file))
                    }
                    func publish(_ activity: SessionActivity, to model: IslandModel) {
                        if provider == .claude { model.receiveClaudeUpdate([activity], statuses: [:], requests: []) }
                        else if provider == .deepseek { model.receiveDeepSeekUpdate([activity], statuses: [:], requests: []) }
                        else { model.receiveRemoteUpdate([activity], statuses: [:], unavailable: [], requests: [], names: []) }
                    }
                    let first = makeModel()
                    publish(ended, to: first)
                    XCTAssertTrue(first.activities.contains { $0.id == ended.id })
                    XCTAssertTrue(first.isUnreadCompletion(ended))
                    let processed = expectation(description: "Open result processed")
                    var reported = false
                    first.onOpenActivity = { _ in outcome }
                    first.onStatusChange = { if !reported { reported = true; processed.fulfill() } }
                    first.open(ended)
                    await fulfillment(of: [processed], timeout: TestWait.limit)
                    await first.shutdown()
                    let acknowledges = outcome == .openedConversation
                    XCTAssertEqual(FileManager.default.fileExists(atPath: file.path), acknowledges)
                    let relaunched = makeModel()
                    publish(ended, to: relaunched)
                    XCTAssertEqual(relaunched.activities.contains { $0.id == ended.id }, !acknowledges,
                        "Only successful conversation navigation survives model reconstruction")
                    XCTAssertEqual(relaunched.isUnreadCompletion(ended), !acknowledges)
                    await relaunched.shutdown()
                }
            }
        }
    }

    func testAwaitedOpenCannotAcknowledgeDynamicRemoteHomeReplacementWithoutGenerationChange() async throws {
        for persist in [false, true] {
            for replaceHome in [false, true] {
                for waiting in [false, true] {
                    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("pacer-open-scope-" + UUID().uuidString)
                    let domain = testDefaultsName("open-scope-tests")
                    let defaults = try XCTUnwrap(UserDefaults(suiteName: domain))
                    defer { removeTestDefaults(domain); try? FileManager.default.removeItem(at: directory) }
                    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                    defaults.set(directory.path, forKey: "codexHome")
                    defaults.set(0, forKey: "completedRetentionMinutes")
                    ProviderModules(codexMode: .enabled, claudeMode: .disabled).save(to: defaults)
                    let host = "remote-ssh-discovered:scope-fixture", session = "019a0000-0000-7000-8000-000000000904"
                    func configuration(_ remoteHome: String) throws {
                        let value: [String: Any] = [
                            "codex-managed-remote-connections": [["source": "discovered", "hostId": host, "alias": "scope-fixture"]],
                            "remote-connection-auto-connect-by-host-id": [host: true],
                            "app-server-migrated-pinned-thread-ids-by-host": [host + ":" + remoteHome: []]]
                        try JSONSerialization.data(withJSONObject: value).write(to: directory.appendingPathComponent(".codex-global-state.json"))
                    }
                    try configuration("/synthetic/first-home")
                    let file = directory.appendingPathComponent("dismissals.json")
                    let store = persist ? CompletionDismissalStore(fileURL: file) : nil
                    let model = IslandModel(demo: true, demoArguments: nil, defaults: defaults,
                        installation: ProviderInstallationDetection(codexInstalled: false, claudeInstalled: false), completionDismissalStore: store)
                    let started = Date().addingTimeInterval(-2)
                    var ended = SessionActivity(id: AgentProvider.codex.activityID(sessionID: session, sourceHostID: host), sourceHostID: host)
                    ended.applyRuntime(["method": "turn/started", "threadId": session, "turnId": "same-synthetic-turn", "at": started.timeIntervalSince1970])
                    if waiting {
                        ended.applyRuntime(["method": "thread/status/changed", "threadId": session, "status": "active", "flags": ["waitingOnUserInput"], "at": started.timeIntervalSince1970 + 1])
                        XCTAssertEqual(ended.phase, .waitingForInput)
                    } else {
                        ended.applyRuntime(["method": "turn/completed", "threadId": session, "turnId": "same-synthetic-turn", "status": "completed", "at": started.timeIntervalSince1970 + 1])
                    }
                    model.receiveRemoteUpdate([ended], statuses: [:], unavailable: [], requests: [], names: [])
                    let dispatched = expectation(description: "Navigation suspended"), returned = expectation(description: "Navigation returned")
                    var continuation: CheckedContinuation<ActivityOpenOutcome, Never>?
                    model.onOpenActivity = { _ in
                        let outcome = await withCheckedContinuation { pending in continuation = pending; dispatched.fulfill() }
                        returned.fulfill()
                        return outcome
                    }
                    model.open(ended)
                    await fulfillment(of: [dispatched], timeout: TestWait.limit)
                    if replaceHome { try configuration("/synthetic/replacement-home") }
                    // Reconcile the real target configuration without changing the provider generation.
                    model.refreshRemote()
                    model.receiveRemoteUpdate([ended], statuses: [:], unavailable: [], requests: [], names: [])
                    try XCTUnwrap(continuation).resume(returning: .openedConversation)
                    await fulfillment(of: [returned], timeout: TestWait.limit)
                    await Task.yield()
                    XCTAssertEqual(model.activities.contains { $0.id == ended.id }, replaceHome || waiting)
                    XCTAssertEqual(model.isUnreadCompletion(ended), replaceHome && !waiting)
                    XCTAssertEqual(FileManager.default.fileExists(atPath: file.path), persist && !replaceHome && !waiting)
                    await model.shutdown()
                    if persist && replaceHome && !waiting {
                        let rebuilt = IslandModel(demo: true, demoArguments: nil, defaults: defaults,
                            installation: ProviderInstallationDetection(codexInstalled: false, claudeInstalled: false), completionDismissalStore: store)
                        rebuilt.receiveRemoteUpdate([ended], statuses: [:], unavailable: [], requests: [], names: [])
                        XCTAssertTrue(rebuilt.activities.contains { $0.id == ended.id })
                        XCTAssertTrue(rebuilt.isUnreadCompletion(ended), "The replacement source remains unacknowledged after reconstruction")
                        await rebuilt.shutdown()
                    }
                }
            }
        }
    }

    func testVerifiedParentOpenAcknowledgesOnlyCapturedTerminalFamilyAcrossRelaunch() async throws {
        // DeepSeek Harness subagents are not grouped yet and it has no remote sources.
        for provider in [AgentProvider.codex, .claude] {
            for remote in [false, true] {
                for outcome in [ActivityOpenOutcome.openedConversation, .dispatchedTerminal, .failed("Synthetic failure")] {
                    let fixture = try familyFixture(remote: remote), model = fixture.model, at = Date().addingTimeInterval(-2)
                    let parent = familyActivity(provider, 910, host: fixture.host, at: at)
                    let child = familyActivity(provider, 911, parent: parent.threadID, host: fixture.host, at: at)
                    let grandchild = familyActivity(provider, 912, parent: child.threadID, host: fixture.host, at: at)
                    let otherProvider: AgentProvider = provider == .codex ? .claude : .codex
                    let unrelated = familyActivity(otherProvider, 911, parent: parent.threadID, host: fixture.host, at: at)
                    let otherHost = familyActivity(provider, 911, parent: parent.threadID, host: "remote-ssh-discovered:unrelated", at: at)
                    let values = [parent, child, grandchild, unrelated, otherHost]
                    publishFamily(values, to: model)
                    XCTAssertEqual(model.taskGroup(for: parent)?.members.count, 3)
                    let processed = expectation(description: "Family open processed")
                    model.onOpenActivity = { target in XCTAssertEqual(target.id, parent.id); return outcome }
                    model.onStatusChange = { processed.fulfill() }
                    model.open(parent)
                    await fulfillment(of: [processed], timeout: TestWait.limit)
                    let success = outcome == .openedConversation
                    for ending in [parent, child, grandchild] { XCTAssertEqual(model.activities.contains { $0.id == ending.id }, !success) }
                    for ending in [unrelated, otherHost] { XCTAssertTrue(model.activities.contains { $0.id == ending.id }) }
                    await model.shutdown()
                    let rebuilt = fixture.rebuild()
                    publishFamily(values, to: rebuilt)
                    for ending in [parent, child, grandchild] { XCTAssertEqual(rebuilt.activities.contains { $0.id == ending.id }, !success) }
                    for ending in [unrelated, otherHost] { XCTAssertTrue(rebuilt.activities.contains { $0.id == ending.id }) }
                    await rebuilt.shutdown()
                }
            }
        }
    }

    func testParentOpenBarrierPreservesRunningLateNewTurnAndReparentedChildren() async throws {
        for change in ["unchanged", "parent-turn", "child-turn", "child-parent"] {
            let fixture = try familyFixture(), model = fixture.model, at = Date().addingTimeInterval(-3)
            let parent = familyActivity(.claude, 920, at: at)
            let child = familyActivity(.claude, 921, parent: parent.threadID, at: at)
            let running = familyActivity(.claude, 922, parent: parent.threadID, completed: false, at: at)
            publishFamily([parent, child, running], to: model)
            let started = expectation(description: "Parent navigation suspended"), returned = expectation(description: "Parent navigation returned")
            var continuation: CheckedContinuation<ActivityOpenOutcome, Never>?
            model.onOpenActivity = { _ in
                let outcome = await withCheckedContinuation { continuation = $0; started.fulfill() }
                returned.fulfill(); return outcome
            }
            model.open(parent)
            await fulfillment(of: [started], timeout: TestWait.limit)
            let later = Date().addingTimeInterval(-1)
            let currentParent = change == "parent-turn" ? familyActivity(.claude, 920, turn: "new-parent-turn", at: later) : parent
            let currentChild = change == "child-turn" ? familyActivity(.claude, 921, parent: parent.threadID, turn: "new-child-turn", at: later) :
                change == "child-parent" ? familyActivity(.claude, 921, parent: "019a0000-0000-7000-8000-000000000999", at: at) : child
            let late = familyActivity(.claude, 922, parent: parent.threadID, at: at)
            let stillRunning = familyActivity(.claude, 923, parent: parent.threadID, completed: false, at: at)
            publishFamily([currentParent, currentChild, late, stillRunning], to: model)
            try XCTUnwrap(continuation).resume(returning: .openedConversation)
            await fulfillment(of: [returned], timeout: TestWait.limit); await Task.yield()
            XCTAssertTrue(model.activities.contains { $0.id == late.id }, "A child ending after the click is never swept into acknowledgment")
            XCTAssertTrue(model.activities.contains { $0.id == stillRunning.id && $0.phase == .running })
            XCTAssertEqual(model.activities.contains { $0.id == currentChild.id }, change != "unchanged")
            if change == "parent-turn" { XCTAssertTrue(model.activities.contains { $0.id == currentParent.id }) }
            XCTAssertTrue(model.canOpen(late), "A retained late direct child can route to its observed parent UUID")
            let childStarted = expectation(description: "Orphan navigation suspended"), childReturned = expectation(description: "Orphan navigation returned")
            var childContinuation: CheckedContinuation<ActivityOpenOutcome, Never>?
            model.onOpenActivity = { target in
                XCTAssertEqual(target.threadID, parent.threadID)
                let outcome = await withCheckedContinuation { childContinuation = $0; childStarted.fulfill() }
                childReturned.fulfill(); return outcome
            }
            model.open(late)
            await fulfillment(of: [childStarted], timeout: TestWait.limit)
            let replacement = change == "child-parent" ? familyActivity(.claude, 922, parent: "019a0000-0000-7000-8000-000000000998", at: at) :
                familyActivity(.claude, 922, parent: parent.threadID, turn: "late-child-next-turn", at: Date().addingTimeInterval(-1))
            publishFamily([currentParent, currentChild, replacement, stillRunning], to: model)
            try XCTUnwrap(childContinuation).resume(returning: .openedConversation)
            await fulfillment(of: [childReturned], timeout: TestWait.limit); await Task.yield()
            XCTAssertTrue(model.activities.contains { $0.id == replacement.id && $0.turnID == replacement.turnID },
                "An old parent-navigation outcome cannot acknowledge a new child turn or changed parent route")
            await model.shutdown()
        }
    }

    func testExistingOrphanChildRoutesObservedUuidParentAndAcknowledgesOnlyVerifiedOpen() async throws {
        for remote in [false, true] {
            for outcome in [ActivityOpenOutcome.openedConversation, .dispatchedTerminal, .failed("Synthetic failure")] {
                let fixture = try familyFixture(remote: remote), at = Date().addingTimeInterval(-2)
                let parent = familyActivity(.claude, 930, host: fixture.host, at: at)
                var child = familyActivity(.claude, 931, parent: parent.threadID, host: fixture.host, at: at)
                if !remote { child.setClaudeNavigation(directory: URL(fileURLWithPath: "/synthetic/child-directory"), desktopSessionID: nil) }
                // Reproduce a parent acknowledged by an earlier app: only the
                // parent digest exists, while a later child ending is unread.
                var inbox = CompletionInbox(dismissalStore: CompletionDismissalStore(fileURL: fixture.file))
                inbox.bindSourceHomes(provider: .claude, localHome: fixture.model.claudeHome,
                    remoteHomes: fixture.host.map { [$0: "~/.claude"] } ?? [:])
                inbox.observe([parent], at: Date(), retention: 0); inbox.dismiss(parent)
                await fixture.model.shutdown()
                let model = fixture.rebuild()
                let opaqueSession = "agent-opaque-observed"
                var opaqueAncestor = SessionActivity(id: AgentProvider.claude.activityID(sessionID: opaqueSession, sourceHostID: fixture.host),
                    sourceHostID: fixture.host, provider: .claude, sessionID: opaqueSession)
                opaqueAncestor.applyRuntime(["method": "metadata", "threadId": opaqueSession, "parentThreadId": parent.threadID!, "at": at.timeIntervalSince1970])
                opaqueAncestor.applyRuntime(["method": "turn/started", "threadId": opaqueSession, "turnId": "opaque-turn", "at": at.timeIntervalSince1970])
                opaqueAncestor.applyRuntime(["method": "turn/completed", "threadId": opaqueSession, "turnId": "opaque-turn", "status": "completed", "at": at.timeIntervalSince1970 + 0.5])
                let nested = familyActivity(.claude, 933, parent: opaqueSession, host: fixture.host, at: at)
                let values = [parent, child, opaqueAncestor, nested]
                publishFamily(values, to: model)
                XCTAssertFalse(model.activities.contains { $0.id == parent.id })
                XCTAssertTrue(model.activities.contains { $0.id == child.id }); XCTAssertTrue(model.canOpen(child))
                XCTAssertTrue(model.canOpen(nested), "An observed opaque ancestor may prove a bounded path to the UUID conversation")
                let opaqueParent = familyActivity(.claude, 932, parent: "opaque-parent-agent", host: fixture.host, at: at)
                XCTAssertFalse(model.canOpen(opaqueParent), "An opaque agent ID is not guessed into a navigable conversation")
                let processed = expectation(description: "Orphan navigation processed")
                model.onOpenActivity = { target in
                    XCTAssertEqual(target.provider, .claude); XCTAssertEqual(target.threadID, parent.threadID)
                    XCTAssertEqual(target.sourceHostID, child.sourceHostID); XCTAssertNil(target.navigationDirectory)
                    return outcome
                }
                model.onStatusChange = { processed.fulfill() }
                model.open(child)
                await fulfillment(of: [processed], timeout: TestWait.limit)
                XCTAssertEqual(model.activities.contains { $0.id == child.id }, outcome != .openedConversation)
                let nestedProcessed = expectation(description: "Nested orphan navigation processed")
                model.onStatusChange = { nestedProcessed.fulfill() }
                model.open(nested)
                await fulfillment(of: [nestedProcessed], timeout: TestWait.limit)
                XCTAssertEqual(model.activities.contains { $0.id == nested.id }, outcome != .openedConversation)
                XCTAssertTrue(model.activities.contains { $0.id == opaqueAncestor.id }, "Navigating a late child does not acknowledge a different ancestor ending")
                await model.shutdown()
                let rebuilt = fixture.rebuild()
                publishFamily(values, to: rebuilt)
                XCTAssertEqual(rebuilt.activities.contains { $0.id == child.id }, outcome != .openedConversation)
                XCTAssertEqual(rebuilt.activities.contains { $0.id == nested.id }, outcome != .openedConversation)
                await rebuilt.shutdown()
            }
        }
    }

}
