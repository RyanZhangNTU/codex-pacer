import Foundation
import XCTest
@testable import PacerCore

private final class SourceSettingsFrames: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Data] = []
    func append(_ data: Data) { lock.lock(); defer { lock.unlock() }; values.append(data) }
    func all() -> [Data] { lock.lock(); defer { lock.unlock() }; return values }
    func report() throws -> EngineCodexSourceReport {
        struct Result: Decodable { let value: EngineCodexSourceReport }
        return try JSONDecoder().decode(Result.self, from: XCTUnwrap(all().last)).value
    }
    func lastError() throws -> String? {
        (try JSONSerialization.jsonObject(with: XCTUnwrap(all().last)) as? [String: Any])?["code"] as? String
    }
    var snapshots: Int { all().filter { (try? JSONDecoder().decode(EngineSnapshot.self, from: $0)) != nil }.count }
}

final class EngineCodexSourceSettingsTests: XCTestCase {
    private func command(_ method: String, _ params: [String: Any] = [:]) throws -> Data {
        try JSONSerialization.data(withJSONObject: ["protocolVersion": 1, "id": "source-query", "method": method, "params": params])
    }
    func testInspectionChecksExistingDirectoriesAndExecutableWithoutLaunchingIt() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("pacer-source-中文 space-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let executable = root.appendingPathComponent("codex.exe"), marker = root.appendingPathComponent("unexpected-launch")
        #if os(Windows)
        let system = WindowsEnvironment.value("SystemRoot", in: ProcessInfo.processInfo.environment) ?? "C:\\Windows"
        try FileManager.default.copyItem(at: URL(fileURLWithPath: system).appendingPathComponent("System32/cmd.exe"), to: executable)
        #else
        try Data("#!/bin/sh\ntouch '\(marker.path)'\nexit 1\n".utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        #endif
        let report = EngineCodexSourceReport.inspect(executable: " \"" + EngineCodexSourceReport.path(executable) + "\" ",
            home: " \"" + EngineCodexSourceReport.path(root) + "\" ", defaultHome: root.appendingPathComponent("default"))
        XCTAssertEqual(report.selectedExecutable, EngineCodexSourceReport.path(executable))
        XCTAssertEqual(report.home, EngineCodexSourceReport.path(root)); XCTAssertNil(report.homeIssue); XCTAssertNil(report.executableIssue)
        XCTAssertEqual(report.candidates.count, 1); XCTAssertTrue(report.candidates[0].label.contains(report.selectedExecutable!))
        XCTAssertFalse(report.historyTitle.contains("%@")); XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
        let fileAsHome = EngineCodexSourceReport.inspect(executable: EngineCodexSourceReport.path(executable),
            home: EngineCodexSourceReport.path(executable), defaultHome: root)
        XCTAssertNotNil(fileAsHome.homeIssue)
        let invalid = EngineCodexSourceReport.inspect(executable: "relative/codex.exe", home: "relative/home", defaultHome: root)
        XCTAssertNil(invalid.selectedExecutable); XCTAssertNotNil(invalid.executableIssue); XCTAssertNotNil(invalid.homeIssue)
    }

    func testExplicitQueriesDoNotPublishOrReconfigureAndClearingHomeRestoresDefault() async throws {
        let capture = SourceSettingsFrames()
        let services = CodexSourceSettingsServices(inspect: { executable, home, fallback in
            .demo(executable: executable, home: home, defaultHome: fallback)
        })
        let runtime = EngineRuntime(demo: false, dismissalStore: nil, sourceSettings: services, output: { capture.append($0) })
        _ = await runtime.receive(try command("initialize", ["enabledProviders": [String]()]))
        let before = capture.snapshots
        _ = await runtime.receive(try command("inspectCodexSource", ["codexHome": ""]))
        let fallback = try capture.report().effectiveHome
        let custom = EngineCodexSourceReport.path(FileManager.default.temporaryDirectory.appendingPathComponent("source-override"))
        _ = await runtime.receive(try command("inspectCodexSource", ["codexHome": custom]))
        XCTAssertEqual(try capture.report().effectiveHome, custom)
        XCTAssertEqual(capture.snapshots, before, "Inspecting a draft cannot restart collectors or change the activity sequence")
        _ = await runtime.receive(try command("inspectCodexSource"))
        XCTAssertEqual(try capture.report().effectiveHome, fallback, "A draft query cannot become the active source")
        _ = await runtime.receive(try command("configure", ["codexHome": custom]))
        _ = await runtime.receive(try command("configure", ["hideProjects": true]))
        _ = await runtime.receive(try command("inspectCodexSource"))
        XCTAssertEqual(try capture.report().effectiveHome, custom, "Omitting a home remains a protocol-1 partial update")
        _ = await runtime.receive(try command("configure", ["codexHome": "", "claudeHome": "", "deepseekHome": ""]))
        _ = await runtime.receive(try command("inspectCodexSource"))
        XCTAssertEqual(try capture.report().effectiveHome, fallback, "Empty source overrides must undo an earlier custom home")
        await runtime.stop()
    }

    func testDemoSourceQueriesDoNotInspectRealInstallationsOrExposeTheUserHome() async throws {
        let capture = SourceSettingsFrames()
        let services = CodexSourceSettingsServices(inspect: { executable, home, fallback in
            XCTFail("Demo settings cannot inspect the real machine")
            return .demo(executable: executable, home: home, defaultHome: fallback)
        })
        let runtime = EngineRuntime(demo: true, sourceSettings: services, output: { capture.append($0) })
        _ = await runtime.receive(try command("initialize"))
        _ = await runtime.receive(try command("inspectCodexSource", ["codexExecutable": "", "codexHome": ""]))
        let report = try capture.report()
        XCTAssertNotNil(report.selectedExecutable); XCTAssertNil(report.homeIssue)
        XCTAssertTrue(report.effectiveHome.lowercased().contains("demo"))
        XCTAssertNotEqual(report.effectiveHome, EngineCodexSourceReport.path(FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex")))
        await runtime.stop()
    }

    func testSourceQueryRequiresInitializationAndRejectsControlCharacters() async throws {
        let capture = SourceSettingsFrames(), runtime = EngineRuntime(demo: true, output: { capture.append($0) })
        _ = await runtime.receive(try command("inspectCodexSource"))
        XCTAssertEqual(try capture.lastError(), "initializeRequired")
        _ = await runtime.receive(try command("initialize"))
        for params in [["codexExecutable": "C:\\bad\n.exe"], ["codexHome": "C:\\bad\0home"]] {
            _ = await runtime.receive(try command("inspectCodexSource", params))
            XCTAssertEqual(try capture.lastError(), "invalidCommand")
        }
        await runtime.stop()
    }
}
