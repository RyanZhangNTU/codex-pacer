import XCTest
@testable import PacerCore

final class HarnessProgressGuideTests: XCTestCase {
    private let added = Date(timeIntervalSince1970: 1_800_000_000)
    private var loaded: HarnessProgressGuide.AppPresence { .running(since: added.addingTimeInterval(60)) }
    private func guide(_ setup: LocalHarnessProgressStatus?, _ connection: LocalHarnessProgressConnection? = nil,
                       reported: Bool = false, ringOn: Bool = true, app: HarnessProgressGuide.AppPresence? = nil,
                       view: HarnessProgressGuide.AppView? = nil, opened: Bool = false) -> HarnessProgressGuide? {
        HarnessProgressGuide(setup: setup, connection: connection, reported: reported, ringOn: ringOn, name: "WorkBuddy AI",
                             addedAt: added, app: app, view: view, openedConnectors: opened, language: .english)
    }

    func testAnAppRunningSinceBeforeTheToolMustBeReopenedFirst() throws {
        // The app reads its MCP file only at start, so it can't list a tool added after.
        let reopen = try XCTUnwrap(guide(.configured, .needsTrust, app: .running(since: added.addingTimeInterval(-600))))
        XCTAssertEqual(reopen.stage, .reopen)
        XCTAssertEqual(reopen.steps.map(\.state), [.done, .current, .pending, .pending, .pending])
        XCTAssertEqual(reopen.steps[1].title, "Quit WorkBuddy AI completely, then reopen it")
        XCTAssertEqual(reopen.chip, "4 steps left")
        XCTAssertEqual(reopen.action, .restartApp, "One click asks the app to quit and opens it again")
        XCTAssertEqual(reopen.actionTitle, "Restart WorkBuddy AI")
        XCTAssertEqual(reopen.waitingText, "Waiting for WorkBuddy AI to start again")
        XCTAssertNil(reopen.picture)

        let closed = try XCTUnwrap(guide(.configured, .needsTrust, app: .notRunning))
        XCTAssertEqual(closed.stage, .launch)
        XCTAssertEqual(closed.steps[1].title, "Open WorkBuddy AI")
        XCTAssertEqual(closed.action, .openConnectors, "Opening the connectors starts the app, which then lists the tool")
        XCTAssertEqual(HarnessProgressGuide.pendingFloat(stage: .reopen, name: "WorkBuddy AI", language: .english)?.title,
                       "Restarting WorkBuddy AI. Its connectors open by themselves in a few seconds…")
        XCTAssertEqual(HarnessProgressGuide.pendingFloat(stage: .launch, name: "WorkBuddy AI", language: .english)?.next,
                       "Then click Custom Connector at the top right")
        XCTAssertNil(HarnessProgressGuide.pendingFloat(stage: .trust, name: "WorkBuddy AI", language: .english))
    }

    func testAnyStateFromAnAppThatHasntReadTheEntryAsksForARestart() throws {
        // The user turned the tool off or removed it in the app, then the ring
        // off and on: the app's old approvals say nothing about the new entry.
        let before: HarnessProgressGuide.AppPresence = .running(since: added.addingTimeInterval(-600))
        for connection in [LocalHarnessProgressConnection.trusted, .disabled, .toolDisabled, .missing, .unknown, .needsTrust, .retrust] {
            XCTAssertEqual(guide(.configured, connection, app: before)?.stage, .reopen, "\(connection)")
        }
        XCTAssertEqual(guide(.configured, .trusted, reported: true, app: before)?.stage, .ready, "A tool that has reported works")
        XCTAssertEqual(guide(.configured, .trusted, app: loaded)?.stage, .firstTask)
        XCTAssertEqual(guide(.configured, .trusted, app: .notRunning)?.stage, .firstTask)
    }

    func testEachClickInTheAppIsItsOwnStep() throws {
        let open = try XCTUnwrap(guide(.configured, .needsTrust, app: loaded))
        XCTAssertEqual(open.stage, .openConnectors)
        XCTAssertEqual(open.steps.map(\.state), [.done, .done, .current, .pending, .pending])
        XCTAssertEqual(open.steps[1].title, "WorkBuddy AI has loaded the tool")
        XCTAssertEqual(open.chip, "3 steps left")
        XCTAssertEqual(open.action, .openConnectors)

        // Opened from the card, the app takes a few seconds to show its connectors.
        let opening = try XCTUnwrap(guide(.configured, .needsTrust, app: loaded, opened: true))
        XCTAssertEqual(opening.stage, .opening)
        XCTAssertEqual(opening.steps.map(\.state), [.done, .done, .current, .pending, .pending])
        XCTAssertNil(opening.action)
        XCTAssertEqual(opening.waitingText, "Waiting for WorkBuddy AI to show its connectors")
        XCTAssertEqual(opening.floatTitle, "Opening WorkBuddy AI’s connectors. This takes a few seconds…")
        XCTAssertEqual(opening.floatNext, "Then click Custom Connector at the top right")
        XCTAssertNil(opening.picture)

        // Pacer reaches the connector market; no link reaches the custom connectors.
        let custom = try XCTUnwrap(guide(.configured, .needsTrust, app: loaded, view: .connectors, opened: true))
        XCTAssertEqual(custom.stage, .customConnector)
        XCTAssertEqual(custom.steps[3].title, "Click Custom Connector at the top right")
        XCTAssertEqual(custom.steps.map(\.state), [.done, .done, .done, .current, .pending])
        XCTAssertNil(custom.action, "The click is in the app; there is nothing to click in Pacer")
        XCTAssertEqual(custom.picture, .customConnector)
        XCTAssertEqual(custom.floatTitle, "Click Custom Connector at the top right of WorkBuddy AI")
        XCTAssertEqual(custom.floatNext, "Next: click Trust on pacer_progress", "The floating guide names this click and the next")
        XCTAssertNil(open.floatTitle, "Until the card opens the app, there is no guide over it")
        XCTAssertEqual(guide(.configured, .needsTrust, app: loaded, view: .connectors)?.stage, .customConnector,
                       "A host that sees the connectors page skips the open step")

        let trust = try XCTUnwrap(guide(.configured, .needsTrust, app: loaded, view: .customConnectors))
        XCTAssertEqual(trust.stage, .trust)
        XCTAssertEqual(trust.steps[4].title, "Click Trust on pacer_progress")
        XCTAssertEqual(trust.chip, "1 step left")
        XCTAssertEqual(trust.picture, .trust)
        XCTAssertNil(trust.action)
        XCTAssertEqual(trust.floatTitle, "Click Trust on pacer_progress")
        XCTAssertNil(trust.floatNext, "Starting a new task is no step of its own")
        XCTAssertEqual(trust.steps.count, 5)
        XCTAssertTrue(trust.attention && trust.waiting)
        XCTAssertNil(trust.line, "Steps carry the state; the explanation stays behind ⓘ")
        XCTAssertTrue(trust.info.contains("Custom Connector") && !trust.info.contains("Refresh"))

        let again = try XCTUnwrap(guide(.configured, .retrust, app: loaded, view: .customConnectors))
        XCTAssertEqual(again.chip, "Trust again")
        XCTAssertEqual(again.steps[4].title, "Click Trust on pacer_progress again")
        XCTAssertEqual(again.summary, "Progress ring: trust again")
        XCTAssertEqual(again.floatTitle, "Click Trust on pacer_progress again")
        XCTAssertEqual(guide(.configured, .retrust, app: loaded, view: .connectors, opened: true)?.floatNext, "Next: click Trust on pacer_progress again")
    }

    func testTheFirstReportCollapsesTheCard() throws {
        // Once trusted, the steps give way to one line: starting a task is no chore.
        let trusted = try XCTUnwrap(guide(.configured, .trusted))
        XCTAssertEqual(trusted.stage, .firstTask)
        XCTAssertTrue(trusted.steps.isEmpty)
        XCTAssertEqual(trusted.chip, "Ready")
        XCTAssertEqual(trusted.tone, .success)
        XCTAssertEqual(trusted.line, "Works in new WorkBuddy AI conversations.")
        XCTAssertFalse(trusted.attention || trusted.waiting)
        XCTAssertNil(trusted.action)
        XCTAssertEqual(trusted.floatTitle, "Done. New WorkBuddy AI conversations show their progress ring.")
        XCTAssertNil(trusted.floatNext)
        XCTAssertNil(trusted.picture)
        let ready = try XCTUnwrap(guide(.configured, .trusted, reported: true))
        XCTAssertEqual(ready.stage, .ready)
        XCTAssertEqual(ready.chip, "Ready")
        XCTAssertTrue(ready.steps.isEmpty)
        XCTAssertNil(ready.line, "After the first report, the line goes too")
        XCTAssertNil(ready.action)
        XCTAssertNil(ready.floatTitle, "The first report closes the floating guide")
        XCTAssertEqual(guide(.configured, .unknown, reported: true)?.stage, .ready, "Reports prove the tool works even when its status can't be read")
    }

    func testProblemsSayWhatToDoInOneLine() throws {
        let off = try XCTUnwrap(guide(.configured, .disabled))
        XCTAssertEqual(off.chip, "Off in WorkBuddy AI")
        XCTAssertEqual(off.line, "Turn pacer_progress back on in WorkBuddy AI.")
        XCTAssertEqual(off.action, .openConnectors)
        XCTAssertNil(off.floatTitle, "A problem closes the floating guide; the card says what to do")
        XCTAssertEqual(guide(.configured, .toolDisabled)?.line, "Turn the report_progress tool back on in WorkBuddy AI.")
        let open = try XCTUnwrap(guide(.missingHome))
        XCTAssertEqual(open.action, .openApp)
        XCTAssertTrue(open.waiting, "Setup continues by itself once the app has made its folder")
        for setup in [LocalHarnessProgressStatus.conflict, .failed] {
            let failed = try XCTUnwrap(guide(setup))
            XCTAssertEqual(failed.tone, .error)
            XCTAssertEqual(failed.action, .retry)
            XCTAssertTrue(failed.attention)
        }
        XCTAssertEqual(guide(.settingUp)?.steps.map(\.state), [.current, .pending, .pending, .pending, .pending])
    }

    func testTheAppLogShowsWhenItsCustomConnectorsOpen() {
        let lines = [
            #"{"timestamp":"2026-11-15T06:44:03.280Z","level":"info","message":["[MethodCh] begin #47 wb:mcp:list arg=undefined"]}"#,
            #"{"timestamp":"2026-11-15T06:44:03.708Z","level":"info","message":["[MethodCh] end #47 wb:mcp:list elapsedMs=428"]}"#,
            #"{"timestamp":"2026-11-15T07:31:57.487Z","level":"info","message":["[MethodCh] begin #244 wb:mcp:list arg=undefined"]}"#,
            #"{"timestamp":"2026-11-15T07:31:58.000Z","level":"info","message":["[MethodCh] begin #245 wb:mcp:describe arg=custom-mcp:other"]}"#
        ].joined(separator: "\n")
        let opened = ISO8601DateFormatter().date(from: "2026-11-15T07:30:00Z")!
        XCTAssertTrue(HarnessAppLog.listedConnectors(in: Data(lines.utf8), after: opened))
        XCTAssertFalse(HarnessAppLog.listedConnectors(in: Data(lines.utf8), after: opened.addingTimeInterval(180)),
                       "Only a listing after the user opened the connectors counts")
        // Restarted from the card: the app's own listing as it starts doesn't count, even half a minute in.
        let restarted = ISO8601DateFormatter().date(from: "2026-11-15T07:31:23Z")!
        XCTAssertFalse(HarnessAppLog.listedConnectors(in: Data(lines.utf8), after: restarted, appStarted: restarted),
                       "The first listing within a minute of the app's start is its own")
        let opening = lines + "\n" + #"{"timestamp":"2026-11-15T07:32:10.000Z","level":"info","message":["[MethodCh] begin #250 wb:mcp:list arg=undefined"]}"#
        XCTAssertTrue(HarnessAppLog.listedConnectors(in: Data(opening.utf8), after: restarted, appStarted: restarted),
                      "A later listing is the user opening the custom connectors")
        XCTAssertTrue(HarnessAppLog.listedConnectors(in: Data(lines.utf8), after: opened, appStarted: opened.addingTimeInterval(-7200)),
                      "Long after the app started, the next listing counts")
        // WorkBuddy on Windows ends its lines with CRLF.
        let windows = opening.replacingOccurrences(of: "\n", with: "\r\n")
        XCTAssertFalse(HarnessAppLog.listedConnectors(in: Data(lines.replacingOccurrences(of: "\n", with: "\r\n").utf8), after: restarted, appStarted: restarted),
                       "On Windows too, the app's own listing as it starts doesn't count")
        XCTAssertTrue(HarnessAppLog.listedConnectors(in: Data(windows.utf8), after: restarted, appStarted: restarted),
                      "On Windows too, a later listing is the user opening the custom connectors")
        XCTAssertEqual(WorkBuddyHarness.china.appLogFile, "logs/daemon.log")
    }

    func testTheLogShowsWhenTheConnectorsAppear() {
        let opened = ISO8601DateFormatter().date(from: "2026-11-15T10:43:10Z")!
        func line(_ time: String, _ method: String) -> String {
            "{\"timestamp\":\"" + time + "\",\"level\":\"info\",\"message\":[\"[MethodCh] begin #1 " + method + " arg=undefined\"]}"
        }
        let starting = Data([line("2026-11-15T10:43:01.000Z", "wb:connectors:listMarket"), line("2026-11-15T10:43:12.000Z", "wb:config:snapshot")].joined(separator: "\r\n").utf8)
        XCTAssertNil(HarnessAppLog.view(in: starting, opened: opened, appStarted: opened, now: opened.addingTimeInterval(10)),
                     "Until the app lists its connector market, it is still on its way")
        XCTAssertEqual(HarnessAppLog.view(in: starting, opened: opened, appStarted: opened, now: opened.addingTimeInterval(31)), .connectors,
                       "Without a word in the log, the guide moves on after half a minute")
        XCTAssertEqual(HarnessAppLog.view(in: nil, opened: opened, appStarted: opened, now: opened.addingTimeInterval(31)), .connectors)
        let shown = Data([line("2026-11-15T10:43:24.218Z", "wb:connectors:listMarket")].joined().utf8)
        XCTAssertEqual(HarnessAppLog.view(in: shown, opened: opened, appStarted: opened, now: opened.addingTimeInterval(15)), .connectors)
        let custom = Data([line("2026-11-15T10:43:24.110Z", "wb:mcp:list"), line("2026-11-15T10:43:24.218Z", "wb:connectors:listMarket"),
                           line("2026-11-15T10:43:31.759Z", "wb:mcp:list")].joined(separator: "\r\n").utf8)
        XCTAssertEqual(HarnessAppLog.view(in: custom, opened: opened, appStarted: opened, now: opened.addingTimeInterval(22)), .customConnectors)
    }

    func testTheLogReadsWhileTheAppKeepsItOpenForWriting() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("pacer-daemon-\(UUID().uuidString).log")
        let line = #"{"timestamp":"2026-11-15T07:31:57.487Z","level":"info","message":["[MethodCh] begin #244 wb:mcp:list arg=undefined"]}"#
        try Data((String(repeating: "x", count: 300 * 1024) + "\r\n" + line + "\r\n").utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let writer = try FileHandle(forWritingTo: file)
        defer { try? writer.close() }
        _ = try writer.seekToEnd()
        let data = try XCTUnwrap(HarnessAppLog.read(file), "WorkBuddy keeps its log open; Pacer still reads it")
        XCTAssertEqual(data.count, HarnessAppLog.tail, "Only the log's end is read")
        XCTAssertTrue(HarnessAppLog.listedConnectors(in: data, after: ISO8601DateFormatter().date(from: "2026-11-15T07:30:00Z")!))
    }

    func testTheLogReachesBackPastTheAppsStartupChatter() throws {
        // Seen on Windows 11/15: WorkBuddy wrote 276 KB between its own listing
        // as it started and the user's click 7 seconds later.
        let started = ISO8601DateFormatter().date(from: "2026-11-15T10:43:10Z")!
        let opened = ISO8601DateFormatter().date(from: "2026-11-15T10:43:11Z")!
        func line(_ time: String, _ text: String) -> String {
            "{\"timestamp\":\"" + time + "\",\"level\":\"info\",\"message\":[\"" + text + "\"]}"
        }
        var log = [line("2026-11-15T10:20:00.000Z", "[MethodCh] begin #900 wb:mcp:list arg=undefined"),
                   line("2026-11-15T10:43:24.110Z", "[MethodCh] begin #62 wb:mcp:list arg=undefined")]
        for index in 0..<3000 { log.append(line("2026-11-15T10:43:2\(5 + index / 1000).000Z", "[Startup] " + String(repeating: "x", count: 100))) }
        log.append(line("2026-11-15T10:43:31.759Z", "[MethodCh] begin #158 wb:mcp:list arg=undefined"))
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("pacer-daemon-\(UUID().uuidString).log")
        try Data(log.joined(separator: "\r\n").utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let end = try XCTUnwrap(HarnessAppLog.read(file))
        XCTAssertFalse(HarnessAppLog.listedConnectors(in: end, after: opened, appStarted: started),
                       "The last 256 KB alone lose the app's own listing, and the user's click passes for it")
        let back = try XCTUnwrap(HarnessAppLog.read(file, since: started))
        XCTAssertGreaterThan(back.count, end.count)
        XCTAssertTrue(HarnessAppLog.listedConnectors(in: back, after: opened, appStarted: started),
                      "Read back to the app's start, its own listing is set apart and the user's click counts")
        XCTAssertFalse(HarnessAppLog.listedConnectors(in: try XCTUnwrap(HarnessAppLog.read(file, since: started)), after: opened.addingTimeInterval(30), appStarted: started),
                       "A listing before the user opened the connectors still doesn't count")
    }

    func testARingThatIsOffShowsNothingUnlessCleanupFailed() {
        XCTAssertNil(guide(.configured, .needsTrust, ringOn: false))
        XCTAssertNil(guide(nil))
        XCTAssertEqual(guide(.failed, ringOn: false)?.stage, .cleanupFailed)
        XCTAssertEqual(guide(.failed, ringOn: false)?.attention, false)
    }

    func testOnboardingNamesEveryAppThatStillNeedsAStep() {
        XCTAssertNil(HarnessProgressGuide.onboardingNote(names: [], language: .english))
        XCTAssertEqual(HarnessProgressGuide.onboardingNote(names: ["WorkBuddy"], language: .english),
                       "WorkBuddy needs a few steps before its ring shows.")
        XCTAssertEqual(HarnessProgressGuide.onboardingNote(names: ["WorkBuddy", "WorkBuddy AI"], language: .simplifiedChinese),
                       "WorkBuddy 和 WorkBuddy AI 还要各自完成几步，圆环才会出现。")
    }
}
