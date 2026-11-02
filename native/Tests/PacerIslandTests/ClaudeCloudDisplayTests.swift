import PacerMacSupport
import XCTest
@testable import PacerCore
@testable import PacerIsland

@MainActor
final class ClaudeCloudDisplayTests: XCTestCase {
    private let project = ClaudeCloudProject(id: "chan_project1", name: "Launch plan", coordinatorSessionID: "cse_coordinator1")
    private let threadID = "cmsg_thread1"
    private let source = ClaudeCloudProjectState.sourceID

    private struct Fixture {
        let model: IslandModel
        let defaults: UserDefaults
        let store: URL
    }
    private func fixture() throws -> Fixture {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("pacer-cloud-display-" + UUID().uuidString)
        let domain = "com.codexpacer.cloud-display-tests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: domain))
        addTeardownBlock { defaults.removePersistentDomain(forName: domain); try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defaults.set(directory.path, forKey: "codexHome")
        defaults.set(directory.appendingPathComponent("claude-home").path, forKey: "claudeHome")
        defaults.set(false, forKey: "monitorSSH")
        ProviderModules(codexMode: .disabled, claudeMode: .enabled).save(to: defaults)
        let store = directory.appendingPathComponent("dismissals.json")
        return Fixture(model: model(defaults, store), defaults: defaults, store: store)
    }
    private func model(_ defaults: UserDefaults, _ store: URL) -> IslandModel {
        IslandModel(defaults: defaults, installation: ProviderInstallationDetection(codexInstalled: false, claudeInstalled: true),
            completionDismissalStore: CompletionDismissalStore(fileURL: store))
    }
    private func thread(_ status: ClaudeCloudThreadStatus, working: Bool = false, unread: Bool = false, reply: Date = Date(),
                        decisions: Int = 0) -> ClaudeCloudThread {
        ClaudeCloudThread(id: threadID, projectID: project.id, status: status, isWorking: working, hasUnread: unread, lastReplyAt: reply,
            title: "Draft the outline", sessionIDs: ["cse_worker1"], openDecisions: decisions)
    }
    private func publish(_ state: inout ClaudeCloudProjectState, to model: IslandModel, _ threads: [ClaudeCloudThread], at date: Date,
                         sessions: [ClaudeCloudSession] = []) {
        state.apply(ClaudeCloudSnapshot(projects: [project], threads: [project.id: threads],
            sessions: Dictionary(uniqueKeysWithValues: sessions.map { ($0.id, $0) })), at: date)
        model.receiveClaudeUpdate(state.activities, statuses: [:], requests: state.attention)
    }
    private func row(_ model: IslandModel) -> SessionActivity? {
        model.activities.first { $0.threadID == threadID }
    }

    func testARunningThreadReadsAsAProjectTaskAndOpens() throws {
        let fixture = try fixture(), model = fixture.model
        var state = ClaudeCloudProjectState()
        publish(&state, to: model, [thread(.working, working: true)], at: Date())
        let running = try XCTUnwrap(row(model))
        XCTAssertEqual(model.projectName(running), "Draft the outline")
        XCTAssertEqual(model.taskSourceName(running), "Launch plan")
        XCTAssertTrue(model.canOpen(running))
        XCTAssertEqual(StatusSymbols.symbol(for: running), StatusSymbols.cloudWork)
        XCTAssertEqual(model.running.map(\.id), [running.id])
        XCTAssertEqual(model.headerStatus, L10n.text("activity.working"))
        XCTAssertNil(model.rate, "a poll has no speed to report")
    }

    func testHidingProjectsAlsoHidesTheProjectNameShownAsSource() throws {
        let fixture = try fixture(), model = fixture.model
        fixture.defaults.set(true, forKey: "hideProjects")
        var state = ClaudeCloudProjectState()
        publish(&state, to: model, [thread(.working, working: true)], at: Date())
        let running = try XCTUnwrap(row(model))
        XCTAssertEqual(model.projectName(running), L10n.text("activity.hidden_name"))
        XCTAssertEqual(model.taskSourceName(running), L10n.text("connections.kind.claude_cloud"))
    }

    func testDecisionKeepsItsOwnWordingAndApprovalStillComesFirst() throws {
        let fixture = try fixture(), model = fixture.model
        var state = ClaudeCloudProjectState()
        publish(&state, to: model, [thread(.working, decisions: 1)], at: Date())
        let waiting = try XCTUnwrap(row(model))
        XCTAssertEqual(model.attentionKind(for: waiting), .decision)
        XCTAssertEqual(model.headerStatus, L10n.text("attention.decision"))
        XCTAssertEqual(model.headerActivity().attention, .decision)
        XCTAssertEqual(StatusSymbols.symbol(for: waiting, attention: .decision), StatusSymbols.input)

        let request = try XCTUnwrap(model.pendingInputRequests.first)
        XCTAssertTrue(model.canOpen(request.activity), "the request alone can open its thread")
        XCTAssertEqual(request.activity.threadURL?.absoluteString, "claude://code/project/chan_project1?thread=cmsg_thread1")

        let approval = PendingAttentionRequest(id: "approval", threadID: threadID, sourceHostID: source, sourceName: project.name,
            kind: .approval, detectedAt: Date(), provider: .claude)
        model.observeAttentionRequests([request, approval])
        XCTAssertEqual(model.attentionKind(for: waiting), .approval)
    }

    func testAnEndingReadInClaudeClearsItsCardAndStaysClearedAfterARelaunch() throws {
        let fixture = try fixture(), model = fixture.model
        let start = Date().addingTimeInterval(-300), ended = start.addingTimeInterval(20)
        var state = ClaudeCloudProjectState()
        publish(&state, to: model, [thread(.working, working: true, reply: start)], at: start)
        publish(&state, to: model, [thread(.resolved, unread: true, reply: ended)], at: ended)
        let card = try XCTUnwrap(row(model))
        XCTAssertEqual(card.phase, .completed)
        XCTAssertTrue(model.isUnreadCompletion(card))
        XCTAssertEqual(card.endingLabel, L10n.text("activity.resolved"))
        XCTAssertEqual(model.pendingCompletions.map(\.id), [card.id])

        publish(&state, to: model, [thread(.resolved, reply: ended)], at: ended.addingTimeInterval(40))
        XCTAssertNil(row(model), "reading it in Claude settles it here")
        XCTAssertTrue(model.pendingCompletions.isEmpty)

        let relaunched = self.model(fixture.defaults, fixture.store)
        relaunched.receiveClaudeUpdate([card], statuses: [:], requests: [])
        XCTAssertNil(row(relaunched), "the acknowledgment holds across a relaunch")
    }

    func testAnEndingStillUnreadInClaudeKeepsItsCardAndANewRunReplacesIt() throws {
        let fixture = try fixture(), model = fixture.model
        let start = Date().addingTimeInterval(-300), ended = start.addingTimeInterval(20)
        var state = ClaudeCloudProjectState()
        publish(&state, to: model, [thread(.working, working: true, reply: start)], at: start)
        publish(&state, to: model, [thread(.resolved, unread: true, reply: ended)], at: ended)
        publish(&state, to: model, [thread(.resolved, unread: true, reply: ended)], at: ended.addingTimeInterval(200))
        XCTAssertEqual(row(model)?.phase, .completed)
        publish(&state, to: model, [thread(.working, working: true, reply: ended)], at: ended.addingTimeInterval(220))
        XCTAssertEqual(row(model)?.phase, .running)
        XCTAssertTrue(model.pendingCompletions.isEmpty)
    }

    func testCloudSwitchHidesRetainedEndingsAndRequestsWithoutAcknowledgingThem() async throws {
        let fixture = try fixture(), model = fixture.model
        let start = Date().addingTimeInterval(-30), ended = start.addingTimeInterval(20)
        var state = ClaudeCloudProjectState()
        publish(&state, to: model, [thread(.working, working: true, reply: start)], at: start)
        publish(&state, to: model, [thread(.resolved, unread: true, reply: ended)], at: ended)
        let card = try XCTUnwrap(row(model))
        XCTAssertEqual(model.pendingCompletions.count, 1)

        fixture.defaults.set(false, forKey: IslandModel.showsClaudeCloudProjectsKey)
        model.applySettings(sourceChanged: false)
        model.receiveClaudeUpdate([], statuses: [:], requests: [])
        XCTAssertFalse(model.visibleActivities.contains { $0.claudeCloud != nil })
        XCTAssertTrue(model.pendingCompletions.isEmpty)
        XCTAssertTrue(model.completionInbox.isUnread(card), "hiding is not acknowledgment")

        // Even a final callback racing the switch cannot put a request back.
        let request = PendingAttentionRequest(id: "cloud-decision", threadID: "cmsg_decision1", sourceHostID: source,
            sourceName: project.name, kind: .decision, detectedAt: Date(), provider: .claude,
            claudeCloud: ClaudeCloudContext(projectID: project.id, projectName: project.name, role: .thread))
        model.receiveClaudeUpdate(state.activities, statuses: [:], requests: [request])
        XCTAssertTrue(model.pendingInputRequests.isEmpty)
        XCTAssertTrue(model.visibleActivities.isEmpty)

        fixture.defaults.set(true, forKey: IslandModel.showsClaudeCloudProjectsKey)
        model.applySettings(sourceChanged: false)
        var replay = ClaudeCloudProjectState()
        replay.apply(ClaudeCloudSnapshot(projects: [project], threads: [project.id: [thread(.resolved, unread: true, reply: ended)]]), at: Date())
        model.receiveClaudeUpdate(replay.activities, statuses: [:], requests: [])
        XCTAssertTrue(model.visibleActivities.contains { $0.id == card.id })
        XCTAssertTrue(model.isUnreadCompletion(card))
        XCTAssertEqual(row(model)?.turnStartedAt, card.turnStartedAt, "a baseline cannot replace the observed duration or extend retention")
        await model.shutdown()
    }

    func testDismissalSurvivesIdleSettlingIntoResolvedBeforeOrAfterARelaunch() throws {
        for dismissBeforeSettling in [false, true] {
            for relaunchBeforeSettling in [false, true] where dismissBeforeSettling || !relaunchBeforeSettling {
                let fixture = try fixture(), model = fixture.model
                let start = Date().addingTimeInterval(-120), ended = start.addingTimeInterval(20), resolved = ended.addingTimeInterval(24)
                var state = ClaudeCloudProjectState()
                publish(&state, to: model, [thread(.working, working: true, reply: start)], at: start)
                publish(&state, to: model, [thread(.idle, reply: ended)], at: ended,
                    sessions: [ClaudeCloudSession(id: "cse_worker1", worker: .idle, bucket: .reviewReady, turnCategory: .reviewReady)])
                let initialTurn = try XCTUnwrap(row(model)?.turnID)
                if dismissBeforeSettling { model.markAllRead(); XCTAssertNil(row(model)) }
                if !relaunchBeforeSettling {
                    publish(&state, to: model, [thread(.resolved, unread: true, reply: resolved)], at: resolved)
                    XCTAssertEqual(state.activities.first { $0.threadID == threadID }?.turnID, initialTurn, "settling cannot replay a notice")
                    if !dismissBeforeSettling { model.markAllRead() }
                    XCTAssertNil(row(model))
                }
                var replay = ClaudeCloudProjectState()
                replay.apply(ClaudeCloudSnapshot(projects: [project], threads: [project.id: [thread(.resolved, unread: true, reply: resolved)]]), at: Date())
                let relaunched = self.model(fixture.defaults, fixture.store)
                relaunched.receiveClaudeUpdate(replay.activities, statuses: [:], requests: replay.attention)
                XCTAssertNil(row(relaunched), "a dismissal holds even when resolved arrives while the app is closed")
                XCTAssertTrue(relaunched.pendingCompletions.isEmpty)
            }
        }
    }

    func testAnObservedNewRunRevokesAnIdleSettlementsAcknowledgment() throws {
        let fixture = try fixture(), model = fixture.model
        let start = Date().addingTimeInterval(-150), ended = start.addingTimeInterval(20), next = ended.addingTimeInterval(60)
        var state = ClaudeCloudProjectState()
        publish(&state, to: model, [thread(.working, working: true, reply: start)], at: start)
        publish(&state, to: model, [thread(.idle, reply: ended)], at: ended,
            sessions: [ClaudeCloudSession(id: "cse_worker1", worker: .idle, bucket: .reviewReady)])
        model.markAllRead()
        publish(&state, to: model, [thread(.working, working: true, reply: ended)], at: next)
        publish(&state, to: model, [thread(.resolved, unread: true, reply: next.addingTimeInterval(20))], at: next.addingTimeInterval(20))
        XCTAssertEqual(model.pendingCompletions.count, 1, "the earlier idle dismissal cannot acknowledge another run")

        var replay = ClaudeCloudProjectState()
        replay.apply(ClaudeCloudSnapshot(projects: [project], threads: [project.id: [thread(.resolved, unread: true, reply: next.addingTimeInterval(20))]]), at: Date())
        let relaunched = self.model(fixture.defaults, fixture.store)
        relaunched.receiveClaudeUpdate(replay.activities, statuses: [:], requests: [])
        XCTAssertNotNil(row(relaunched), "the revoked settlement stays revoked on disk")
    }

    func testAnEndedCardCarriesItsSpeedButTheHeaderTotalDoesNot() throws {
        let fixture = try fixture(), model = fixture.model
        let start = Date().addingTimeInterval(-300), ended = start.addingTimeInterval(60)
        var state = ClaudeCloudProjectState()
        publish(&state, to: model, [thread(.working, working: true, reply: start)], at: start)
        state.apply(ClaudeCloudSnapshot(projects: [project], threads: [project.id: [thread(.resolved, unread: true, reply: ended)]]), at: ended)
        state.applyTurnResult(ClaudeCloudTurnResult(id: "event1", completedAt: ended, outputTokens: 1200, streaming: 20, firstOutput: 2), thread: threadID, at: ended)
        model.receiveClaudeUpdate(state.activities, statuses: [:], requests: state.attention)
        let card = try XCTUnwrap(row(model))
        XCTAssertEqual(card.phase, .completed)
        XCTAssertEqual(card.displayedOutputEstimate(at: Date())?.value ?? 0, 60, accuracy: 0.01)
        XCTAssertEqual(card.firstTokenLatency ?? 0, 2, accuracy: 0.01)
        XCTAssertNil(model.rate)

        publish(&state, to: model, [thread(.working, working: true, reply: ended)], at: ended.addingTimeInterval(30))
        XCTAssertEqual(row(model)?.phase, .running)
        XCTAssertNil(model.rate, "the last turn's speed is not live")
    }

    func testAWritingThreadJoinsTheTotalAndItsEndingShowsTheRealSpeed() throws {
        let fixture = try fixture(), model = fixture.model
        let start = Date().addingTimeInterval(-5)
        var state = ClaudeCloudProjectState()
        publish(&state, to: model, [thread(.working, working: true, reply: start)], at: start)
        XCTAssertNil(model.rate)
        for step in 0...8 {
            let time = start.addingTimeInterval(Double(step) * 0.5)
            state.applyReplyProgress(thread: threadID, block: "toolu_1", tokens: Double(step) * 45, sentAt: time, at: time)
        }
        model.receiveClaudeUpdate(state.activities, statuses: [:], requests: state.attention)
        XCTAssertEqual(model.rate ?? 0, 90, accuracy: 1)
        XCTAssertTrue(model.rateIsFresh)
        let writing = try XCTUnwrap(row(model))
        XCTAssertEqual(writing.phase, .running)
        XCTAssertTrue(writing.displayedRateIsEstimated(at: Date()))
        XCTAssertNil(writing.firstTokenLatency, "first output is only known when the turn ends")

        let ended = Date()
        state.apply(ClaudeCloudSnapshot(projects: [project], threads: [project.id: [thread(.resolved, unread: true, reply: ended)]]), at: ended)
        state.applyTurnResult(ClaudeCloudTurnResult(id: "event1", completedAt: ended, outputTokens: 2000, streaming: 25, firstOutput: 2), thread: threadID, at: ended)
        model.receiveClaudeUpdate(state.activities, statuses: [:], requests: state.attention)
        XCTAssertEqual(row(model)?.displayedOutputEstimate(at: Date())?.value ?? 0, 80, accuracy: 0.01)
        XCTAssertNil(model.rate, "an ended card is not live")
    }

    func testConnectionsNameTheSourceAndASignedOutOneIsNotAProblem() {
        func status(_ connected: Bool, available: Bool? = nil) -> RuntimeStreamStatus {
            var value = RuntimeStreamStatus(); value.connected = connected; value.sourceAvailable = available
            return value
        }
        let local = status(true)
        func sources(_ cloud: RuntimeStreamStatus) -> [ConnectionSource] {
            ConnectionSource.sources(statuses: [.claude: ["local": local, source: cloud]], unavailableSSH: [], names: [source: "Launch plan"])
        }
        let connected = sources(status(true)).first { $0.key == source }
        XCTAssertEqual(connected?.name, L10n.text("connections.kind.claude_cloud"), "never a project's name")
        XCTAssertEqual(connected?.kind, "Claude")
        XCTAssertEqual(connected?.state, .connected)

        let signedOut = sources(status(false, available: false))
        XCTAssertEqual(signedOut.first { $0.key == source }?.state, .paused)
        XCTAssertEqual(ConnectionSummary(enabledProviders: [.claude], sources: signedOut, hosts: []).state, .connected,
                       "signing in to claude.ai is optional")
        XCTAssertEqual(ConnectionSummary(enabledProviders: [.claude], sources: sources(status(false)), hosts: []).state, .retrying(1))
    }

    func testTheSwitchStartsAndStopsTheMonitorAndADefaultModelNeverStartsOne() async throws {
        let fixture = try fixture(), model = fixture.model
        model.applySettings(sourceChanged: false)
        var made = 0
        model.makeClaudeCloudMonitor = {
            made += 1
            return ClaudeCloudProjectMonitor(cookieProvider: { nil })
        }
        model.applySettings(sourceChanged: false)
        XCTAssertEqual(made, 1)
        model.applySettings(sourceChanged: false)
        XCTAssertEqual(made, 1, "a running monitor is kept")
        fixture.defaults.set(false, forKey: IslandModel.showsClaudeCloudProjectsKey)
        model.applySettings(sourceChanged: false)
        fixture.defaults.set(true, forKey: IslandModel.showsClaudeCloudProjectsKey)
        model.applySettings(sourceChanged: false)
        XCTAssertEqual(made, 2, "turning it off forgets what it followed")
        await model.shutdown()
    }
}
