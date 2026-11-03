#if os(Windows)
import Foundation
import XCTest
@testable import PacerCore
@testable import PacerEngineSupport

final class WindowsHostApplicationTests: XCTestCase {
    private let process = ProcessInstance(pid: 20, started: 100)
    private var binding: ActivityHostApplication.ApplicationIdentity {
        .init(executable: URL(fileURLWithPath: "C:/Synthetic Editor/editor.exe"), volume: 1, low: 2, high: 3,
              modified: 4, size: 5, packageApplicationID: "")
    }
    private var host: ActivityHostApplication {
        .init(identity: process, provider: nil, name: "Synthetic Editor", home: URL(fileURLWithPath: "C:/Synthetic/.codex"), application: binding)
    }
    func testLiveHostActivationNeverStartsAnotherInstanceEvenWhenForegroundFails() {
        var raised: [ProcessInstance] = [], launched = 0
        XCTAssertTrue(WindowsHostApplication.activate(host, inspect: { _ in self.process }, activateWindow: { raised.append($0); return true }, open: { _ in launched += 1; return false }))
        XCTAssertEqual(raised, [process]); XCTAssertEqual(launched, 0)
        XCTAssertFalse(WindowsHostApplication.activate(host, inspect: { _ in self.process }, activateWindow: { _ in false }, open: { _ in launched += 1; return true }))
        XCTAssertEqual(launched, 0, "A foreground failure cannot create duplicate editors")
    }
    func testExitedAndReusedPIDsCanOnlyRelaunchTheCapturedApplicationIdentity() {
        var raised = 0, launched: [ActivityHostApplication.ApplicationIdentity] = []
        for live in [nil, ProcessInstance(pid: process.pid, started: process.started + 1)] {
            XCTAssertTrue(WindowsHostApplication.activate(host, inspect: { _ in live }, activateWindow: { _ in raised += 1; return true }, open: { launched.append($0); return true }))
        }
        XCTAssertEqual(raised, 0); XCTAssertEqual(launched, [binding, binding])
        var unknown = host; unknown.application = nil
        XCTAssertFalse(WindowsHostApplication.activate(unknown, inspect: { _ in nil }, activateWindow: { _ in true }, open: { _ in XCTFail("Unknown hosts must never launch"); return true }))
        XCTAssertFalse(WindowsHostApplication.activate(host, inspect: { _ in nil }, activateWindow: { _ in true }, open: { _ in false }))
    }
    func testNativeCaptureRejectsReusedCreationTimeAndChangedExecutableIdentity() throws {
        try withObservedHelper { _, current, captured in
            let pid = current.pid
            XCTAssertTrue(captured.executable.isFileURL); XCTAssertGreaterThan(captured.size, 0)
            XCTAssertNil(WindowsHostApplication.capture(.init(pid: pid, started: current.started + 1)))
            let changed = ActivityHostApplication.ApplicationIdentity(executable: captured.executable, volume: captured.volume,
                low: captured.low ^ 1, high: captured.high, modified: captured.modified, size: captured.size, packageApplicationID: captured.packageApplicationID)
            XCTAssertFalse(WindowsHostApplication.open(changed), "Replacing the executable revokes the saved launch capability")
            let missing = ActivityHostApplication.ApplicationIdentity(executable: captured.executable.appendingPathExtension("missing.exe"), volume: captured.volume,
                low: captured.low, high: captured.high, modified: captured.modified, size: captured.size, packageApplicationID: captured.packageApplicationID)
            XCTAssertFalse(WindowsHostApplication.open(missing))
            let snapshot = try XCTUnwrap(WindowsProcessOwnership.snapshot())
            XCTAssertEqual(snapshot.inspect(pid, current.started)?.identity, current)
            XCTAssertNil(snapshot.inspect(pid, current.started + 1))
        }
    }
    func testNativeRelaunchAcceptsThePrivateObservedHelperAfterItExits() throws {
        try withObservedHelper { helper, identity, application in
            helper.terminate(); helper.waitUntilExit()
            XCTAssertFalse(WindowsProcessOwnership.alive(identity))
            // The fixture exits immediately without arguments. Its recorded
            // file/readiness arguments are absent from the launch capability.
            XCTAssertTrue(WindowsHostApplication.open(application))
        }
    }
    private func withObservedHelper(_ body: (Process, ProcessInstance, ActivityHostApplication.ApplicationIdentity) throws -> Void) throws {
        let executable = try XCTUnwrap(ProcessInfo.processInfo.environment["PACER_DESKTOP_PIPE_FIXTURE"])
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("pacer-host-launch-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("synthetic.jsonl"), ready = root.appendingPathComponent("ready")
        try Data().write(to: file)
        let helper = Process(); helper.executableURL = URL(fileURLWithPath: executable)
        helper.arguments = ["file-read", EngineCodexSourceReport.path(file), EngineCodexSourceReport.path(ready)]
        helper.standardOutput = FileHandle.nullDevice; helper.standardError = FileHandle.nullDevice
        try helper.run()
        defer { if helper.isRunning { helper.terminate(); helper.waitUntilExit() } }
        let identity = try XCTUnwrap(WindowsProcessOwnership.inspect(UInt32(helper.processIdentifier))?.identity)
        let application = try XCTUnwrap(WindowsHostApplication.capture(identity))
        try body(helper, identity, application)
    }
    func testCachedApplicationCannotCrossTheSelectedHomeOrAnAmbiguousCurrentWriter() throws {
        let session = "11111111-1111-4111-8111-111111111111"
        var activity = SessionActivity(id: AgentProvider.codex.activityID(sessionID: session), sessionID: session)
        activity.setCodexOrigin(.init(embedded: true, ignored: false))
        var input = ActivityNavigationServices.Input(context: UUID().uuidString, activity: activity, home: host.home,
            transcript: host.home.appendingPathComponent("sessions/synthetic.jsonl"), cachedHost: host)
        let plan = try WindowsActivityNavigation.resolve(input, writers: { _, _ in [] })
        XCTAssertEqual(plan.kind, "host"); XCTAssertEqual(plan.hostApplication, host); XCTAssertNil(plan.url)
        let json = String(decoding: try JSONEncoder().encode(plan), as: UTF8.self)
        XCTAssertFalse(json.contains("editor.exe")); XCTAssertFalse(json.contains("fileVolume")); XCTAssertFalse(json.contains("packageApplicationID"))
        input = .init(context: input.context, activity: activity, home: host.home.appendingPathComponent("different"), transcript: input.transcript, cachedHost: host)
        XCTAssertThrowsError(try WindowsActivityNavigation.resolve(input, writers: { _, _ in [] }))
        input = .init(context: input.context, activity: activity, home: host.home, transcript: input.transcript, cachedHost: host)
        XCTAssertThrowsError(try WindowsActivityNavigation.resolve(input, writers: { _, _ in nil }))
        XCTAssertThrowsError(try WindowsActivityNavigation.resolve(input, writers: { _, _ in [.init(pid: 1, started: 1), .init(pid: 2, started: 2)] }, host: { .init(identity: $0, provider: nil) }))
    }
}
#endif
