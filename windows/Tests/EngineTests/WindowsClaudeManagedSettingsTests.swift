import Foundation
import XCTest
@testable import PacerCore
@testable import PacerEngineSupport
@testable import WindowsInstallerSupport

final class WindowsClaudeManagedSettingsTests: XCTestCase {
    private func folder() throws -> URL {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("pacer-managed-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: base.appendingPathComponent("managed-settings.d"), withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: base) }
        return base
    }
    private func write(_ text: String, _ url: URL) throws { try Data(text.utf8).write(to: url) }

    func testFilesDropInsAndPoliciesAreUnitedWhileHiddenForeignBrokenAndLargeFilesAreSkipped() throws {
        let base = try folder(), dropIns = base.appendingPathComponent("managed-settings.d")
        try write(#"{"env":{"OTEL_EXPORTER_OTLP_ENDPOINT":"https://collector.invalid"}}"#, base.appendingPathComponent("managed-settings.json"))
        try write(#"{"env":{"OTEL_EXPORTER_OTLP_PROTOCOL":"grpc","OTEL_METRIC_EXPORT_INTERVAL":5000}}"#, dropIns.appendingPathComponent("10-protocol.json"))
        try write(#"{"settings":{"otelHeadersHelper":"C:/synthetic/headers.cmd"}}"#, dropIns.appendingPathComponent("20-headers.json"))
        try write(#"{"env":{"HIDDEN_DROP_IN":"1"}}"#, dropIns.appendingPathComponent(".30-hidden.json"))
        try write(#"{"env":{"TEXT_DROP_IN":"1"}}"#, dropIns.appendingPathComponent("40-notes.txt"))
        try write("{not json", dropIns.appendingPathComponent("50-broken.json"))
        let padding = String(repeating: "x", count: 2 * 1024 * 1024)
        try write(#"{"env":{"LARGE_DROP_IN":"1"},"padding":""# + padding + #""}"#, dropIns.appendingPathComponent("60-large.json"))
        try FileManager.default.createDirectory(at: dropIns.appendingPathComponent("70-folder.json"), withIntermediateDirectories: true)

        let result = WindowsClaudeManagedSettings.telemetry(folder: base,
            machine: #"{"env":{"CLAUDE_CODE_ENABLE_TELEMETRY":"0"}}"#, user: "not a settings document")
        XCTAssertEqual(result.environment, [
            "OTEL_EXPORTER_OTLP_ENDPOINT": "https://collector.invalid", "OTEL_EXPORTER_OTLP_PROTOCOL": "grpc",
            "OTEL_METRIC_EXPORT_INTERVAL": "5000", "CLAUDE_CODE_ENABLE_TELEMETRY": "0"
        ], "Policy values, the managed file and visible JSON drop-ins are read; hidden, non-JSON, broken, oversized and folder entries are not")
        XCTAssertTrue(result.headersHelper, "A headers helper inside a wrapped drop-in counts")
        XCTAssertEqual(ClaudeTelemetryRules.conflict(user: [:], headersHelper: false, managed: result, owned: [:]), .managed)
    }

    func testMissingFolderAndNoPoliciesClaimNothing() throws {
        let missing = FileManager.default.temporaryDirectory.appendingPathComponent("pacer-managed-missing-" + UUID().uuidString)
        let result = WindowsClaudeManagedSettings.telemetry(folder: missing, machine: nil, user: nil)
        XCTAssertEqual(result, ClaudeManagedTelemetry())
        XCTAssertEqual(ClaudeTelemetryRules.conflict(user: [:], headersHelper: false, managed: result, owned: [:]), .none)
    }

    func testManagedSettingsUnrelatedToTracesLeavePacerTelemetryOn() throws {
        let base = try folder()
        try write(#"{"env":{"CLAUDE_CODE_ENABLE_TELEMETRY":"1","OTEL_METRICS_EXPORTER":"otlp","OTEL_EXPORTER_OTLP_METRICS_ENDPOINT":"https://metrics.invalid"},"permissions":{"deny":["WebFetch"]}}"#,
            base.appendingPathComponent("managed-settings.json"))
        let result = WindowsClaudeManagedSettings.telemetry(folder: base, machine: nil, user: nil)
        XCTAssertFalse(result.environment.isEmpty)
        XCTAssertEqual(ClaudeTelemetryRules.conflict(user: [:], headersHelper: false, managed: result, owned: [:]), .none,
            "Managed metrics with telemetry already on do not claim the trace exporter")
        var dormant = result; dormant.environment.removeValue(forKey: "CLAUDE_CODE_ENABLE_TELEMETRY")
        XCTAssertEqual(ClaudeTelemetryRules.conflict(user: [:], headersHelper: false, managed: dormant, owned: [:]), .managed,
            "Pacer's switch must not start the organization's metrics export")
    }

    func testMachinePolicyOutranksFilesAndUserPolicyOnlyFillsAnEmptyAdminScope() throws {
        let base = try folder()
        try write(#"{"env":{"CLAUDE_CODE_ENABLE_TELEMETRY":"1","OTEL_LOGS_EXPORTER":"none"}}"#, base.appendingPathComponent("managed-settings.json"))
        try write(#"{"env":{"OTEL_LOGS_EXPORTER":"otlp"}}"#, base.appendingPathComponent("managed-settings.d").appendingPathComponent("10-logs.json"))
        let user = #"{"env":{"OTEL_EXPORTER_OTLP_PROTOCOL":"grpc"}}"#
        let ranked = WindowsClaudeManagedSettings.telemetry(folder: base, machine: #"{"env":{"CLAUDE_CODE_ENABLE_TELEMETRY":"0"}}"#, user: user)
        XCTAssertEqual(ranked.environment, ["CLAUDE_CODE_ENABLE_TELEMETRY": "0", "OTEL_LOGS_EXPORTER": "otlp"],
            "HKLM wins per variable, a later drop-in overrides the base file, and HKCU is ignored beside admin sources")
        XCTAssertEqual(ClaudeTelemetryRules.conflict(user: [:], headersHelper: false, managed: ranked, owned: [:]), .managed)
        let missing = FileManager.default.temporaryDirectory.appendingPathComponent("pacer-managed-missing-" + UUID().uuidString)
        XCTAssertEqual(WindowsClaudeManagedSettings.telemetry(folder: missing, machine: nil, user: user).environment,
            ["OTEL_EXPORTER_OTLP_PROTOCOL": "grpc"], "HKCU applies when no admin source holds a document")
    }

    func testRegistryReadsStringValuesFromTheMachineAndUserRootsOnly() {
        // Read-only: a value every Windows installation has under HKLM and not under HKCU.
        let key = #"SOFTWARE\Microsoft\Windows NT\CurrentVersion"#
        XCTAssertTrue(WindowsClaudeManagedSettings.policyDocument(.machine, key: key, value: "ProductName")?.hasPrefix("Windows") == true)
        XCTAssertNil(WindowsClaudeManagedSettings.policyDocument(.user, key: key, value: "ProductName"))
        XCTAssertNil(WindowsClaudeManagedSettings.policyDocument(.machine, key: key, value: "CurrentMajorVersionNumber"), "A DWORD is not a settings document")
        XCTAssertNil(WindowsClaudeManagedSettings.policyDocument(.machine, key: #"SOFTWARE\Policies\PacerSyntheticMissing"#, value: "Settings"))
    }

    func testHelperReportCarriesTheConflictReasonIntoTheEngineSnapshot() throws {
        for reason in [ClaudeTelemetryConflict.none, .existing, .managed] {
            let status = ClaudeHookInstaller.Status(hooksConfigured: true, telemetryConfigured: reason == .none, statusLineConfigured: true,
                                                    telemetryConflictReason: reason)
            let report = WindowsClaudeHookRuntime.Report("ready", status, launchMode: "direct")
            var setup = try JSONDecoder().decode(EngineClaudeHookSetup.self, from: JSONEncoder().encode(report))
            XCTAssertEqual(setup.state, .ready)
            XCTAssertEqual(setup.telemetryConflict, reason != .none)
            XCTAssertEqual(setup.telemetryConflictReason, reason.rawValue)
            XCTAssertNil(setup.exactRequestSpans, "Only the engine knows whether exact spans arrived")
            setup.exactRequestSpans = true
            let snapshot = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(setup)) as? [String: Any])
            XCTAssertEqual(snapshot["telemetryConflictReason"] as? String, reason.rawValue)
            XCTAssertEqual(snapshot["exactRequestSpans"] as? Bool, true)
        }
        let legacy = try JSONDecoder().decode(EngineClaudeHookSetup.self, from: Data(#"{"state":"ready","hooksConfigured":true,"telemetryConfigured":false,"statusLineConfigured":true,"telemetryConflict":true,"updateAvailable":false}"#.utf8))
        XCTAssertTrue(legacy.telemetryConflict); XCTAssertNil(legacy.telemetryConflictReason, "A helper from before the reason field still decodes")
    }
}
