#if os(Windows)
import Foundation
import XCTest
@testable import PacerCore

final class WindowsDeepSeekApplicationTests: XCTestCase {
    private func fixture() throws -> URL {
        let path = try XCTUnwrap(ProcessInfo.processInfo.environment["PACER_HARNESS_DESKTOP_FIXTURE"])
        return URL(fileURLWithPath: path)
    }
    func testDesktopIdentityUsesProductMetadataAndDoesNotExecuteTheCandidate() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("harness-metadata-中文 " + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let candidate = root.appendingPathComponent(WindowsDeepSeekApplication.filename)
        let source = try fixture()
        for name in [WindowsDeepSeekApplication.filename, "DeepSeek Harness.dll", "DeepSeek Harness.runtimeconfig.json", "DeepSeek Harness.deps.json"] {
            try FileManager.default.copyItem(at: source.deletingLastPathComponent().appendingPathComponent(name), to: root.appendingPathComponent(name))
        }
        XCTAssertTrue(WindowsDeepSeekApplication.isApplication(candidate))
        XCTAssertEqual(WindowsDeepSeekApplication.find(applicationURLs: [root], registeredPaths: { XCTFail("Explicit roots cannot query the machine registry"); return [] }), candidate)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("fixture-was-launched").path))
        try FileManager.default.removeItem(at: candidate)
        let command = URL(fileURLWithPath: ProcessInfo.processInfo.environment["SystemRoot"]!).appendingPathComponent("System32/cmd.exe")
        try FileManager.default.copyItem(at: command, to: candidate)
        XCTAssertFalse(WindowsDeepSeekApplication.isApplication(candidate), "Renaming another executable cannot create a desktop identity")
        XCTAssertNil(WindowsDeepSeekApplication.find(applicationURLs: [root]))
    }
    func testAutomaticDetectionFindsAClosedDesktopWithoutCliOrSessionData() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("harness-default-" + UUID().uuidString)
        let local = root.appendingPathComponent("AppData/Local"), app = local.appendingPathComponent("Programs/DeepSeek Harness")
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.copyItem(at: fixture(), to: app.appendingPathComponent(WindowsDeepSeekApplication.filename))
        let environment = ["LOCALAPPDATA": WindowsCodexExecutableDiscovery.path(local)]
        XCTAssertNotNil(WindowsDeepSeekApplication.find(userHome: root, environment: environment, registeredPaths: { [] }))
        let detection = WindowsProviderInstallation.detect(userHome: root, environment: environment,
            applicationURLs: [.codex: [], .claude: [], .deepseek: [app]], systemBinDirectories: [], packageLocations: { _ in [] })
        XCTAssertTrue(detection.deepseekInstalled)
        XCTAssertNil(WindowsDeepSeekApplication.find(applicationURLs: [], userHome: root, environment: environment, registeredPaths: { XCTFail("An empty override must stay isolated"); return [] }))
        XCTAssertNil(WindowsDeepSeekApplication.find(applicationURLs: [URL(fileURLWithPath: #"\\untrusted.invalid\share\DeepSeek Harness.exe"#)]))
    }
    func testRegisteredCandidatesUseDesktopMetadataAndStayWithinTheirBudget() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("harness-registered-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let application = root.appendingPathComponent(WindowsDeepSeekApplication.filename)
        try FileManager.default.copyItem(at: fixture(), to: application)
        let path = WindowsCodexExecutableDiscovery.path(application), absent = WindowsCodexExecutableDiscovery.path(root.appendingPathComponent("absent"))
        let environment = ["LOCALAPPDATA": absent]
        XCTAssertEqual(WindowsDeepSeekApplication.find(userHome: root, environment: environment, registeredPaths: {
            [#"\\untrusted.invalid\share\DeepSeek Harness.exe"#, absent, path]
        }), application)
        XCTAssertNil(WindowsDeepSeekApplication.find(userHome: root, environment: environment, registeredPaths: {
            [absent, absent, absent, absent, path]
        }), "A valid entry beyond the fixed registry budget cannot extend discovery")
        let cli = root.appendingPathComponent("dsh.exe")
        try FileManager.default.copyItem(at: application, to: cli)
        XCTAssertFalse(WindowsDeepSeekApplication.isApplication(cli), "A CLI filename is not a desktop target, even with copied product metadata")
    }
}
#endif
