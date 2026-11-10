import PacerMacSupport
import XCTest
@testable import PacerCore

/// One table of synthetic settings, decided by both the local installer and
/// the remote setup script, which must agree on every row.
final class ClaudeTelemetryConflictTests: XCTestCase {
    private struct Case {
        let name: String
        var env: [String: String] = [:]
        var settings: [String: Any] = [:]
        /// The server-managed settings cache inside the Claude home.
        var managed: [String: Any]? = nil
        let expected: ClaudeTelemetryConflict
    }
    private let cases: [Case] = [
        Case(name: "nothing configured", expected: .none),
        Case(name: "generic endpoint and protocol for metrics and logs", env: [
            "OTEL_EXPORTER_OTLP_ENDPOINT": "https://collector.invalid:4317", "OTEL_EXPORTER_OTLP_PROTOCOL": "grpc",
            "OTEL_METRICS_EXPORTER": "otlp", "OTEL_LOGS_EXPORTER": "otlp", "CLAUDE_CODE_ENABLE_TELEMETRY": "1"], expected: .none),
        Case(name: "truthy switch spelled differently", env: ["CLAUDE_CODE_ENABLE_TELEMETRY": "true"], expected: .none),
        Case(name: "slower export interval", env: ["OTEL_TRACES_EXPORT_INTERVAL": "5000"], expected: .none),
        Case(name: "generic headers would reach Pacer", env: ["OTEL_EXPORTER_OTLP_HEADERS": "authorization=synthetic"], expected: .existing),
        Case(name: "trace headers", env: ["OTEL_EXPORTER_OTLP_TRACES_HEADERS": "authorization=synthetic"], expected: .existing),
        Case(name: "headers helper", settings: ["otelHeadersHelper": "/synthetic/helper"], expected: .existing),
        Case(name: "another trace endpoint", env: ["OTEL_EXPORTER_OTLP_TRACES_ENDPOINT": "https://collector.invalid/v1/traces"], expected: .existing),
        Case(name: "console traces", env: ["OTEL_TRACES_EXPORTER": "console"], expected: .existing),
        Case(name: "traces already exported to the generic endpoint", env: [
            "OTEL_TRACES_EXPORTER": "otlp", "OTEL_EXPORTER_OTLP_ENDPOINT": "https://collector.invalid"], expected: .existing),
        Case(name: "telemetry turned off", env: ["CLAUDE_CODE_ENABLE_TELEMETRY": "0"], expected: .existing),
        Case(name: "managed generic endpoint", managed: ["env": ["OTEL_EXPORTER_OTLP_ENDPOINT": "https://collector.invalid"]], expected: .managed),
        Case(name: "managed generic protocol", managed: ["env": ["OTEL_EXPORTER_OTLP_PROTOCOL": "grpc"]], expected: .managed),
        Case(name: "managed trace client key", managed: ["env": ["OTEL_EXPORTER_OTLP_TRACES_CLIENT_KEY": "/synthetic/key"]], expected: .managed),
        Case(name: "managed headers helper", managed: ["otelHeadersHelper": "/synthetic/helper"], expected: .managed),
        Case(name: "managed telemetry off", managed: ["env": ["CLAUDE_CODE_ENABLE_TELEMETRY": "0"]], expected: .managed),
        Case(name: "wrapped managed cache", managed: ["settings": ["env": ["OTEL_EXPORTER_OTLP_HEADERS": "authorization=synthetic"]]], expected: .managed),
        Case(name: "managed metrics endpoint only", managed: ["env": ["OTEL_EXPORTER_OTLP_METRICS_ENDPOINT": "https://collector.invalid"]], expected: .none),
        Case(name: "managed copy of Pacer's own endpoint", managed: ["env": ["OTEL_EXPORTER_OTLP_TRACES_ENDPOINT": ClaudeTelemetryRules.endpoint]], expected: .none),
        Case(name: "metrics exporter waiting for the switch", env: [
            "OTEL_METRICS_EXPORTER": "otlp", "OTEL_EXPORTER_OTLP_METRICS_ENDPOINT": "https://collector.invalid"], expected: .existing),
        Case(name: "exporters turned off", env: ["OTEL_METRICS_EXPORTER": "none", "OTEL_LOGS_EXPORTER": " none "], expected: .none),
        Case(name: "managed logs exporter waiting for the switch", managed: ["env": ["OTEL_LOGS_EXPORTER": "otlp"]], expected: .managed),
        Case(name: "managed logs exporter already on", managed: ["env": ["CLAUDE_CODE_ENABLE_TELEMETRY": "1", "OTEL_LOGS_EXPORTER": "otlp"]], expected: .none)
    ]

    private func home() throws -> (root: URL, home: URL) {
        let root = URL(fileURLWithPath: "/private/tmp/pacer-claude-telemetry-" + UUID().uuidString)
        let home = root.appendingPathComponent(".claude")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        return (root, home)
    }
    private func prepare(_ item: Case, in home: URL) throws {
        var settings = item.settings
        if !item.env.isEmpty { settings["env"] = item.env }
        try JSONSerialization.data(withJSONObject: settings).write(to: home.appendingPathComponent("settings.json"))
        if let managed = item.managed {
            try JSONSerialization.data(withJSONObject: managed).write(to: home.appendingPathComponent("remote-settings.json"))
        }
    }
    private func env(_ home: URL) throws -> [String: String] {
        let value = try JSONSerialization.jsonObject(with: Data(contentsOf: home.appendingPathComponent("settings.json"))) as? [String: Any]
        return value?["env"] as? [String: String] ?? [:]
    }
    private func runRemote(home: URL, automatic: Bool = false) throws -> ClaudeHookInstaller.Status {
        let resources = try ClaudeRemoteSetup.resources()
        var request: [String: Any] = ["home": home.path, "hook": resources.hook.base64EncodedString()]
        if automatic { request["automatic"] = true }
        let payload = try JSONSerialization.data(withJSONObject: request)
        let process = Process(), output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["python3", "-u", "-c", "import base64;exec(base64.b64decode('\(resources.installer.base64EncodedString())').decode())", payload.base64EncodedString()]
        process.standardInput = FileHandle.nullDevice; process.standardOutput = output; process.standardError = FileHandle.nullDevice
        process.environment = ProcessInfo.processInfo.environment.filter { !$0.key.hasPrefix("OTEL_") && !$0.key.hasPrefix("CLAUDE_CODE_") }
        try process.run()
        let bytes = output.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
        return try ClaudeRemoteSetup.status(data: bytes, exitStatus: process.terminationStatus)
    }
    private func check(_ item: Case, status: ClaudeHookInstaller.Status, home: URL, side: String) throws {
        XCTAssertEqual(status.telemetryConflictReason, item.expected, side + ": " + item.name)
        XCTAssertEqual(status.telemetryConfigured, item.expected == .none, side + ": " + item.name)
        let result = try env(home)
        for (key, value) in item.env { XCTAssertEqual(result[key], value, side + " keeps the user's " + key + ": " + item.name) }
        if item.expected == .none {
            XCTAssertTrue(ClaudeTelemetryRules.configured(result), side + " adds Pacer's keys: " + item.name)
        } else {
            XCTAssertEqual(result, item.env, side + " leaves the settings alone: " + item.name)
        }
    }

    func testLocalAndRemoteSetupAgreeOnEveryConflictRow() throws {
        for item in cases {
            let local = try home(); defer { try? FileManager.default.removeItem(at: local.root) }
            try prepare(item, in: local.home)
            try check(item, status: try ClaudeHookInstaller.install(home: local.home), home: local.home, side: "local")
            let remote = try home(); defer { try? FileManager.default.removeItem(at: remote.root) }
            try prepare(item, in: remote.home)
            try check(item, status: try runRemote(home: remote.home), home: remote.home, side: "remote")
        }
    }

    /// Keys Pacer added leave when a managed claim appears and return when it
    /// goes; the remote script follows the same states on its next run.
    func testRemoteSetupWithdrawsAndRestoresItsOwnKeys() throws {
        let fixture = try home(); defer { try? FileManager.default.removeItem(at: fixture.root) }
        let settings = fixture.home.appendingPathComponent("settings.json"), cache = fixture.home.appendingPathComponent("remote-settings.json")
        try JSONSerialization.data(withJSONObject: ["env": ["USER_SETTING": "retained"]]).write(to: settings)
        XCTAssertTrue(try runRemote(home: fixture.home).telemetryConfigured)
        try JSONSerialization.data(withJSONObject: ["env": ["OTEL_EXPORTER_OTLP_ENDPOINT": "https://collector.invalid"]]).write(to: cache)
        XCTAssertEqual(try runRemote(home: fixture.home).telemetryConflictReason, .managed)
        XCTAssertEqual(try env(fixture.home), ["USER_SETTING": "retained"])
        try FileManager.default.removeItem(at: cache)
        XCTAssertTrue(try runRemote(home: fixture.home).telemetryConfigured)
        XCTAssertEqual(try env(fixture.home)["USER_SETTING"], "retained")
    }

    /// The remote script follows the local lifecycle: headers withdraw
    /// Pacer's endpoint even after an equivalent edit, and automatic runs
    /// keep a key the user removed removed until an explicit run.
    func testRemoteSetupWithdrawsItsEndpointAndKeepsRemovalsOnAutomaticRuns() throws {
        let fixture = try home(); defer { try? FileManager.default.removeItem(at: fixture.root) }
        let settings = fixture.home.appendingPathComponent("settings.json")
        XCTAssertTrue(try runRemote(home: fixture.home).telemetryConfigured)
        var env = try env(fixture.home)
        env["CLAUDE_CODE_ENABLE_TELEMETRY"] = "true"; env["OTEL_EXPORTER_OTLP_HEADERS"] = "authorization=synthetic"
        try JSONSerialization.data(withJSONObject: ["env": env]).write(to: settings)
        XCTAssertEqual(try runRemote(home: fixture.home, automatic: true).telemetryConflictReason, .existing)
        XCTAssertEqual(try self.env(fixture.home), ["CLAUDE_CODE_ENABLE_TELEMETRY": "true", "OTEL_EXPORTER_OTLP_HEADERS": "authorization=synthetic"])

        try JSONSerialization.data(withJSONObject: [String: Any]()).write(to: settings)
        XCTAssertTrue(try runRemote(home: fixture.home).telemetryConfigured)
        env = try self.env(fixture.home); env.removeValue(forKey: "OTEL_TRACES_EXPORT_INTERVAL")
        try JSONSerialization.data(withJSONObject: ["env": env]).write(to: settings)
        _ = try runRemote(home: fixture.home, automatic: true)
        XCTAssertNil(try self.env(fixture.home)["OTEL_TRACES_EXPORT_INTERVAL"], "An automatic run keeps the removal")
        _ = try runRemote(home: fixture.home)
        XCTAssertEqual(try self.env(fixture.home)["OTEL_TRACES_EXPORT_INTERVAL"], "1000", "An explicit run restores it")
    }

    /// The remote script remembers a removal through a conflict, withdraws
    /// the rest when Pacer's endpoint is removed, and groups managed OTLP keys.
    func testRemoteSetupKeepsRemovalsThroughConflictsAndGroupsManagedOTLP() throws {
        let fixture = try home(); defer { try? FileManager.default.removeItem(at: fixture.root) }
        let settings = fixture.home.appendingPathComponent("settings.json")
        func write(_ env: [String: String]) throws { try JSONSerialization.data(withJSONObject: env.isEmpty ? [:] : ["env": env]).write(to: settings) }
        XCTAssertTrue(try runRemote(home: fixture.home).telemetryConfigured)
        var current = try env(fixture.home); current.removeValue(forKey: "OTEL_TRACES_EXPORTER"); try write(current)
        _ = try runRemote(home: fixture.home, automatic: true)
        current["OTEL_EXPORTER_OTLP_HEADERS"] = "authorization=synthetic"; try write(current)
        _ = try runRemote(home: fixture.home, automatic: true)
        XCTAssertEqual(try env(fixture.home), ["OTEL_EXPORTER_OTLP_HEADERS": "authorization=synthetic"])
        try write([:])
        _ = try runRemote(home: fixture.home, automatic: true)
        XCTAssertEqual(try env(fixture.home), [:])
        XCTAssertTrue(try runRemote(home: fixture.home).telemetryConfigured)
        current = try env(fixture.home); current.removeValue(forKey: "OTEL_EXPORTER_OTLP_TRACES_ENDPOINT"); try write(current)
        _ = try runRemote(home: fixture.home, automatic: true)
        XCTAssertEqual(try env(fixture.home), [:])

        let source = try ClaudeRemoteSetup.resources().installer
        let probe = """
        import json, sys
        ns = {'__name__': 'pacer_probe'}
        exec(sys.stdin.read(), ns)
        managed = {'env': {}, 'helper': False}
        ns['fill_managed'](managed, {'env': {'OTEL_EXPORTER_OTLP_METRICS_ENDPOINT': 'https://metrics.invalid', 'BLANK': ''}, 'helper': False})
        ns['fill_managed'](managed, {'env': {'OTEL_EXPORTER_OTLP_ENDPOINT': 'https://old.invalid', 'OTEL_LOGS_EXPORTER': 'otlp', 'OTEL_METRICS_EXPORTER': 'none', 'BLANK': 'later'}, 'helper': False})
        print(json.dumps(managed, sort_keys=True))
        """
        let process = Process(), input = Pipe(), output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env"); process.arguments = ["python3", "-I", "-c", probe]
        process.standardInput = input; process.standardOutput = output; process.standardError = FileHandle.nullDevice
        try process.run(); input.fileHandleForWriting.write(source); try input.fileHandleForWriting.close()
        let printed = output.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
        let merged = try XCTUnwrap(JSONSerialization.jsonObject(with: printed) as? [String: Any])
        XCTAssertEqual(merged["env"] as? [String: String], ["OTEL_EXPORTER_OTLP_METRICS_ENDPOINT": "https://metrics.invalid", "BLANK": "", "OTEL_METRICS_EXPORTER": "none"],
            "Python takes the OTLP group whole from the first source, like Swift")
    }

    func testMacManagedSettingsReadFilesDropInsAndPreferences() throws {
        let fixture = try home(); defer { try? FileManager.default.removeItem(at: fixture.root) }
        let folder = fixture.root.appendingPathComponent("ClaudeCode"), dropIns = folder.appendingPathComponent("managed-settings.d")
        try FileManager.default.createDirectory(at: dropIns, withIntermediateDirectories: true)
        try Data(#"{"env":{"OTEL_EXPORTER_OTLP_METRICS_ENDPOINT":"https://collector.invalid"}}"#.utf8).write(to: folder.appendingPathComponent("managed-settings.json"))
        try Data(#"{"otelHeadersHelper":"/synthetic/helper"}"#.utf8).write(to: dropIns.appendingPathComponent("20-helper.json"))
        try Data(#"{"env":{"IGNORED":"hidden"}}"#.utf8).write(to: dropIns.appendingPathComponent(".hidden.json"))
        let plist = fixture.root.appendingPathComponent("com.anthropic.claudecode.plist")
        try Data(#"{"env":{"CLAUDE_CODE_ENABLE_TELEMETRY":"1","OTEL_LOGS_EXPORTER":"otlp"}}"#.utf8).write(to: dropIns.appendingPathComponent("10-switch.json"))
        try PropertyListSerialization.data(fromPropertyList: ["env": ["OTEL_EXPORTER_OTLP_PROTOCOL": "grpc", "CLAUDE_CODE_ENABLE_TELEMETRY": "0"]], format: .xml, options: 0).write(to: plist)
        let managed = MacClaudeManagedSettings.telemetry(folder: folder, preferences: [plist, fixture.root.appendingPathComponent("missing.plist")])
        XCTAssertTrue(managed.headersHelper)
        XCTAssertEqual(managed.environment, ["OTEL_EXPORTER_OTLP_PROTOCOL": "grpc", "CLAUDE_CODE_ENABLE_TELEMETRY": "0"],
            "MDM preferences outrank the files variable by variable, and their OTLP group hides the files' OTLP keys")
        let filesOnly = MacClaudeManagedSettings.telemetry(folder: folder, preferences: [])
        XCTAssertEqual(filesOnly.environment, ["OTEL_EXPORTER_OTLP_METRICS_ENDPOINT": "https://collector.invalid", "CLAUDE_CODE_ENABLE_TELEMETRY": "1",
            "OTEL_LOGS_EXPORTER": "otlp"], "Without MDM the files supply the group")
        XCTAssertEqual(MacClaudeManagedSettings.telemetry(folder: fixture.root.appendingPathComponent("absent"), preferences: []), ClaudeManagedTelemetry())
    }
}
