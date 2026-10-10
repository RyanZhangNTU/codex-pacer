import XCTest
@testable import PacerCore

final class ClaudeHookInstallerTests: XCTestCase {
    private let eventNames = ["SessionStart", "UserPromptSubmit", "MessageDisplay", "PreToolUse", "PostToolUse", "PostToolUseFailure",
                              "PermissionRequest", "PermissionDenied", "Stop", "StopFailure", "SessionEnd", "Notification", "SubagentStart",
                              "SubagentStop", "Elicitation", "ElicitationResult"]

    private func fixture() throws -> (root: URL, home: URL) {
        let root = URL(fileURLWithPath: "/private/tmp/pacer-claude-hooks-" + UUID().uuidString)
        let home = root.appendingPathComponent(".claude")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        return (root, home)
    }

    private func write(_ value: [String: Any], to url: URL) throws {
        try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]).write(to: url)
    }

    private func read(_ url: URL) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    }

    private func commandEntries(_ settings: [String: Any], event: String, command: String) -> [[String: Any]] {
        let groups = (settings["hooks"] as? [String: [[String: Any]]])?[event] ?? []
        return groups.flatMap { $0["hooks"] as? [[String: Any]] ?? [] }
            .filter { $0["type"] as? String == "command" && $0["command"] as? String == command }
    }

    private func installedCommand(_ settings: [String: Any], event: String = "SessionStart") throws -> String {
        let groups = try XCTUnwrap((settings["hooks"] as? [String: [[String: Any]]])?[event])
        let entries = groups.flatMap { $0["hooks"] as? [[String: Any]] ?? [] }
        return try XCTUnwrap(entries.first { ($0["command"] as? String)?.contains("/pacer/hook.py'") == true }?["command"] as? String)
    }

    func testInstallUninstallPreservesUnrelatedHooksEnvironmentAndStatusLineOptions() throws {
        let fixture = try fixture(); defer { try? FileManager.default.removeItem(at: fixture.root) }
        let file = fixture.home.appendingPathComponent("settings.json")
        let originalGroup: [String: Any] = ["matcher": "Bash", "customGroupOption": "retained",
            "hooks": [["type": "command", "command": "printf user-hook", "timeout": 20],
                      ["type": "prompt", "prompt": "User supplied rule"]]]
        let originalLine: [String: Any] = ["type": "command", "command": "printf user-status", "padding": 4, "customOption": "retained"]
        let original: [String: Any] = ["hooks": ["PreToolUse": [originalGroup], "FutureHook": [["hooks": [["type": "command", "command": "printf future-hook"]]]]],
            "env": ["USER_OPTION": "retained", "CLAUDE_CODE_ENABLE_TELEMETRY": "1"],
            "statusLine": originalLine, "permissions": ["allow": ["Read"]], "customSetting": ["enabled": true]]
        try write(original, to: file)
        let status = try ClaudeHookInstaller.install(home: fixture.home)
        XCTAssertTrue(status.hooksConfigured)
        XCTAssertTrue(status.telemetryConfigured)
        XCTAssertTrue(status.statusLineConfigured)
        XCTAssertFalse(status.telemetryConflict)
        let installed = try read(file), command = try installedCommand(installed)
        for event in eventNames { XCTAssertEqual(commandEntries(installed, event: event, command: command).count, 1, event) }
        let preTool = try XCTUnwrap((installed["hooks"] as? [String: [[String: Any]]])?["PreToolUse"]?.first)
        XCTAssertTrue(NSDictionary(dictionary: preTool).isEqual(to: originalGroup))
        let line = try XCTUnwrap(installed["statusLine"] as? [String: Any])
        XCTAssertEqual(line["padding"] as? Int, 4)
        XCTAssertEqual(line["customOption"] as? String, "retained")
        XCTAssertNotEqual(line["command"] as? String, originalLine["command"] as? String)
        XCTAssertEqual((installed["env"] as? [String: String])?["USER_OPTION"], "retained")
        XCTAssertTrue(NSDictionary(dictionary: installed["permissions"] as? [String: Any] ?? [:]).isEqual(to: original["permissions"] as? [String: Any] ?? [:]))
        try ClaudeHookInstaller.uninstall(home: fixture.home)
        XCTAssertTrue(NSDictionary(dictionary: try read(file)).isEqual(to: original))
        XCTAssertFalse(ClaudeHookInstaller.status(home: fixture.home))
    }

    func testRepeatedInstallHasOneExactOwnedHookAndRestoresOriginalRendererOnce() throws {
        let fixture = try fixture(); defer { try? FileManager.default.removeItem(at: fixture.root) }
        let file = fixture.home.appendingPathComponent("settings.json")
        let original: [String: Any] = ["statusLine": ["type": "command", "command": "printf original", "padding": 2],
                                       "env": ["OTEL_TRACES_EXPORT_INTERVAL": "1000", "USER_OPTION": "retained"]]
        try write(original, to: file)
        _ = try ClaudeHookInstaller.install(home: fixture.home)
        let first = try read(file), command = try installedCommand(first)
        _ = try ClaudeHookInstaller.install(home: fixture.home)
        let second = try read(file)
        XCTAssertTrue(NSDictionary(dictionary: first).isEqual(to: second))
        for event in eventNames { XCTAssertEqual(commandEntries(second, event: event, command: command).count, 1, event) }
        try ClaudeHookInstaller.uninstall(home: fixture.home)
        XCTAssertTrue(NSDictionary(dictionary: try read(file)).isEqual(to: original))
        try ClaudeHookInstaller.uninstall(home: fixture.home)
        XCTAssertTrue(NSDictionary(dictionary: try read(file)).isEqual(to: original))
    }

    func testPromptEntryWithMatchingCommandIsNeverTreatedAsOwnedCommandHook() throws {
        let fixture = try fixture(); defer { try? FileManager.default.removeItem(at: fixture.root) }
        let file = fixture.home.appendingPathComponent("settings.json")
        _ = try ClaudeHookInstaller.install(home: fixture.home)
        let command = try installedCommand(read(file))
        try ClaudeHookInstaller.uninstall(home: fixture.home)
        let original: [String: Any] = ["hooks": ["SessionStart": [["matcher": "fixture", "hooks": [["type": "prompt", "prompt": "User supplied rule", "command": command]]]]]]
        try write(original, to: file)
        let status = try ClaudeHookInstaller.install(home: fixture.home)
        XCTAssertTrue(status.hooksConfigured)
        XCTAssertEqual(commandEntries(try read(file), event: "SessionStart", command: command).count, 1)
        try ClaudeHookInstaller.uninstall(home: fixture.home)
        XCTAssertTrue(NSDictionary(dictionary: try read(file)).isEqual(to: original))
    }

    func testConflictingTelemetryRemainsUntouchedWhileLifecycleHooksAreInstalled() throws {
        for conflict in [
            ["OTEL_EXPORTER_OTLP_TRACES_ENDPOINT": "http://127.0.0.1:54321/v1/traces", "USER_OPTION": "retained"],
            ["OTEL_EXPORTER_OTLP_HEADERS": "Fixture header value", "USER_OPTION": "retained"],
            ["OTEL_TRACES_EXPORTER": "console", "USER_OPTION": "retained"]
        ] {
            let fixture = try fixture(); defer { try? FileManager.default.removeItem(at: fixture.root) }
            let file = fixture.home.appendingPathComponent("settings.json")
            try write(["env": conflict], to: file)
            let status = try ClaudeHookInstaller.install(home: fixture.home)
            XCTAssertTrue(status.hooksConfigured)
            XCTAssertFalse(status.telemetryConfigured)
            XCTAssertTrue(status.telemetryConflict)
            XCTAssertEqual(try read(file)["env"] as? [String: String], conflict)
            try ClaudeHookInstaller.uninstall(home: fixture.home)
            XCTAssertEqual(try read(file)["env"] as? [String: String], conflict)
        }
    }

    func testUninstallKeepsSettingsChangedAfterInstallation() throws {
        let fixture = try fixture(); defer { try? FileManager.default.removeItem(at: fixture.root) }
        let file = fixture.home.appendingPathComponent("settings.json")
        _ = try ClaudeHookInstaller.install(home: fixture.home)
        var changed = try read(file), env = try XCTUnwrap(changed["env"] as? [String: String])
        env["OTEL_TRACES_EXPORT_INTERVAL"] = "2500"; env["USER_OPTION"] = "new value"; changed["env"] = env
        let newerLine: [String: Any] = ["type": "command", "command": "printf newer-renderer", "padding": 8]
        changed["statusLine"] = newerLine
        try write(changed, to: file)
        try ClaudeHookInstaller.uninstall(home: fixture.home)
        let removed = try read(file)
        XCTAssertEqual(removed["env"] as? [String: String], ["OTEL_TRACES_EXPORT_INTERVAL": "2500", "USER_OPTION": "new value"])
        XCTAssertTrue(NSDictionary(dictionary: removed["statusLine"] as? [String: Any] ?? [:]).isEqual(to: newerLine))
    }

    func testMalformedSettingsAreNeverMutated() throws {
        for malformed in [#"{"env": "wrong-type"}"#, #"{"hooks":{"Stop":"wrong-type"}}"#,
                          #"{"statusLine":"wrong-type"}"#, #"["wrong-root"]"#, #"{"broken": }"#] {
            let fixture = try fixture(); defer { try? FileManager.default.removeItem(at: fixture.root) }
            let file = fixture.home.appendingPathComponent("settings.json"), bytes = Data(malformed.utf8)
            try bytes.write(to: file)
            XCTAssertThrowsError(try ClaudeHookInstaller.install(home: fixture.home))
            XCTAssertEqual(try Data(contentsOf: file), bytes)
            XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.home.appendingPathComponent("pacer").path))
            XCTAssertFalse(ClaudeHookInstaller.status(home: fixture.home))
        }
    }

    func testSymlinkSettingsAndHookDirectoryAreRejectedWithoutChangingTargets() throws {
        for settingsLink in [true, false] {
            let fixture = try fixture(); defer { try? FileManager.default.removeItem(at: fixture.root) }
            let target = fixture.root.appendingPathComponent(settingsLink ? "target-settings.json" : "target-hooks")
            let link = fixture.home.appendingPathComponent(settingsLink ? "settings.json" : "pacer")
            let original = Data(#"{"custom":"retained"}"#.utf8)
            if settingsLink { try original.write(to: target) }
            else {
                try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
                try original.write(to: fixture.home.appendingPathComponent("settings.json"))
            }
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
            XCTAssertThrowsError(try ClaudeHookInstaller.install(home: fixture.home)) { error in
                guard let failure = error as? ClaudeHookInstaller.Failure, case .unsafePath = failure else { return XCTFail("expected unsafePath") }
            }
            XCTAssertEqual(try Data(contentsOf: settingsLink ? target : fixture.home.appendingPathComponent("settings.json")), original)
            XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: link.path), target.path)
            if !settingsLink { XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: target.path).isEmpty) }
        }
    }

    func testMissingInstalledScriptMakesHookStatusUnavailable() throws {
        let fixture = try fixture(); defer { try? FileManager.default.removeItem(at: fixture.root) }
        XCTAssertTrue(try ClaudeHookInstaller.install(home: fixture.home).hooksConfigured)
        try FileManager.default.removeItem(at: fixture.home.appendingPathComponent("pacer/hook.py"))
        XCTAssertFalse(ClaudeHookInstaller.status(home: fixture.home))
        XCTAssertFalse(ClaudeHookInstaller.details(home: fixture.home).hooksConfigured)
    }

    private func runScript(home: URL, mode: String, input: [String: Any]) throws -> (stdout: Data, stderr: Data) {
        let child = Process(), stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
        child.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        child.arguments = [home.appendingPathComponent("pacer/hook.py").path, mode, home.path]
        var environment = ProcessInfo.processInfo.environment
        environment.removeValue(forKey: "CLAUDE_CODE_OAUTH_TOKEN")
        child.environment = environment
        child.standardInput = stdin; child.standardOutput = stdout; child.standardError = stderr
        try child.run()
        try stdin.fileHandleForWriting.write(contentsOf: JSONSerialization.data(withJSONObject: input))
        try stdin.fileHandleForWriting.close()
        child.waitUntilExit()
        let result = (stdout.fileHandleForReading.readDataToEndOfFile(), stderr.fileHandleForReading.readDataToEndOfFile())
        XCTAssertEqual(child.terminationStatus, 0)
        return result
    }

    func testHookAdapterPreservesLifecycleAndAgentRoutingWithoutStdoutOrPrivateContent() throws {
        let fixture = try fixture(); defer { try? FileManager.default.removeItem(at: fixture.root) }
        _ = try ClaudeHookInstaller.install(home: fixture.home)
        let inputs: [[String: Any]] = [
            ["hook_event_name": "UserPromptSubmit", "prompt_id": "prompt-1", "prompt": "PRIVATE prompt"],
            ["hook_event_name": "PreToolUse", "tool_use_id": "tool-1", "tool_name": "AskUserQuestion", "tool_input": ["question": "PRIVATE question"]],
            ["hook_event_name": "PermissionRequest", "tool_use_id": "tool-1", "tool_input": ["command": "PRIVATE command"]],
            ["hook_event_name": "PostToolUse", "tool_use_id": "tool-1", "tool_response": "PRIVATE output"],
            ["hook_event_name": "Notification", "notification_type": "permission_prompt", "message": "PRIVATE notification"],
            ["hook_event_name": "SubagentStart", "agent_id": "agent-1", "agent_type": "PRIVATE agent nickname"],
            ["hook_event_name": "SubagentStop", "agent_id": "agent-1", "last_assistant_message": "PRIVATE agent response"],
            ["hook_event_name": "Stop", "last_assistant_message": "PRIVATE response"]
        ]
        for input in inputs {
            let common: [String: Any] = ["session_id": "session-1", "cwd": "/PRIVATE/fixture-project", "transcript_path": "/PRIVATE/transcript.jsonl"]
            let result = try runScript(home: fixture.home, mode: "hook", input: common.merging(input) { _, supplied in supplied })
            XCTAssertTrue(result.stdout.isEmpty)
            XCTAssertTrue(result.stderr.isEmpty)
        }
        let bytes = try Data(contentsOf: fixture.home.appendingPathComponent("pacer/events.jsonl"))
        XCTAssertFalse(String(decoding: bytes, as: UTF8.self).contains("PRIVATE"))
        let rows = try bytes.split(separator: 10).map { try XCTUnwrap(JSONSerialization.jsonObject(with: Data($0)) as? [String: Any]) }
        let events = rows.filter { $0["kind"] as? String != "metadata" }
        XCTAssertEqual(events.compactMap { $0["kind"] as? String }, ["prompt", "toolStart", "approval", "toolEnd", "approval", "subagentStart", "stopRequested", "stopRequested"])
        XCTAssertEqual(events.first { $0["kind"] as? String == "toolStart" }?["attention"] as? String, "input")
        let child = try XCTUnwrap(events.first { $0["kind"] as? String == "subagentStart" })
        XCTAssertEqual(child["sessionId"] as? String, "agent-1")
        XCTAssertEqual(child["parentId"] as? String, "session-1")
        XCTAssertEqual(child["promptId"] as? String, "prompt-1")
        XCTAssertTrue(rows.allSatisfy { $0["project"] as? String == "fixture-project" })
        let state = try Data(contentsOf: fixture.home.appendingPathComponent("pacer/hook-state.json"))
        XCTAssertFalse(String(decoding: state, as: UTF8.self).contains("PRIVATE"))
    }

    func testStatusLineAdapterCachesOnlyQuotaAndPassesOriginalInputToExistingRenderer() throws {
        let fixture = try fixture(); defer { try? FileManager.default.removeItem(at: fixture.root) }
        let renderer = fixture.root.appendingPathComponent("renderer.py")
        let script = "import json,sys\nvalue=json.loads(sys.stdin.read())\nprint('existing renderer: '+value['fixture_marker'],end='')\n"
        try Data(script.utf8).write(to: renderer)
        let originalLine: [String: Any] = ["type": "command", "command": "python3 '" + renderer.path + "'", "padding": 3]
        try write(["statusLine": originalLine], to: fixture.home.appendingPathComponent("settings.json"))
        try write(["oauthAccount": ["accountUuid": "fixture-account", "organizationUuid": "fixture-organization", "emailAddress": "PRIVATE email"]],
                  to: fixture.home.appendingPathComponent(".claude.json"))
        _ = try ClaudeHookInstaller.install(home: fixture.home)
        let input: [String: Any] = ["fixture_marker": "retained", "workspace": ["cwd": "/PRIVATE/workspace"],
            "model": ["display_name": "PRIVATE model display"], "cost": ["total_cost_usd": 9.0],
            "rate_limits": ["five_hour": ["used_percentage": 22.5, "resets_at": 1_791_532_800, "private": "PRIVATE limit data"],
                            "seven_day": ["used_percentage": 44, "resets_at": "2026-10-10T00:00:00Z"], "private": "PRIVATE quota data"]]
        let result = try runScript(home: fixture.home, mode: "statusline", input: input)
        XCTAssertEqual(String(decoding: result.stdout, as: UTF8.self), "existing renderer: retained")
        XCTAssertTrue(result.stderr.isEmpty)
        let cacheURL = fixture.home.appendingPathComponent("pacer/claude-statusline.json"), bytes = try Data(contentsOf: cacheURL)
        XCTAssertFalse(String(decoding: bytes, as: UTF8.self).contains("PRIVATE"))
        let envelope = try read(cacheURL)
        XCTAssertEqual(Set(envelope.keys), ["captured_at", "account_scope", "payload"])
        XCTAssertEqual((envelope["account_scope"] as? String)?.count, 64)
        XCTAssertNotEqual(envelope["account_scope"] as? String, "fixture-account")
        let payload = try XCTUnwrap(envelope["payload"] as? [String: Any]), limits = try XCTUnwrap(payload["rate_limits"] as? [String: [String: Any]])
        XCTAssertEqual(Set(payload.keys), ["rate_limits"])
        XCTAssertEqual(Set(limits.keys), ["five_hour", "seven_day"])
        XCTAssertEqual(Set(try XCTUnwrap(limits["five_hour"]).keys), ["used_percentage", "resets_at"])
        XCTAssertEqual(limits["five_hour"]?["used_percentage"] as? Double, 22.5)
        XCTAssertEqual(limits["seven_day"]?["used_percentage"] as? Int, 44)
    }
    func testMessageDisplayEmitsOnlyProvenPartialPresenceAndTypedMarkerBoolean() throws {
        let fixture = try fixture(); defer { try? FileManager.default.removeItem(at: fixture.root) }
        _ = try ClaudeHookInstaller.install(home: fixture.home)
        let common: [String: Any] = ["session_id": "session-1", "prompt_id": "prompt-1", "cwd": "/PRIVATE/fixture-project"]
        let prompt = common.merging(["hook_event_name": "UserPromptSubmit", "prompt": "[Request interrupted by user]"]) { _, new in new }
        _ = try runScript(home: fixture.home, mode: "hook", input: prompt)
        let initialEvents = try Data(contentsOf: fixture.home.appendingPathComponent("pacer/events.jsonl"))
        let initialState = try Data(contentsOf: fixture.home.appendingPathComponent("pacer/hook-state.json"))
        for (final, index) in [(true, 0), (false, 1), (false, 0)] {
            let event = common.merging(["hook_event_name": "MessageDisplay", "message_id": "message-1", "turn_id": "display-turn-1", "index": index, "final": final, "delta": "PRIVATE generated content"]) { _, new in new }
            let result = try runScript(home: fixture.home, mode: "hook", input: event)
            XCTAssertTrue(result.stdout.isEmpty); XCTAssertTrue(result.stderr.isEmpty)
            if final || index != 0 {
                XCTAssertEqual(try Data(contentsOf: fixture.home.appendingPathComponent("pacer/events.jsonl")), initialEvents)
                XCTAssertEqual(try Data(contentsOf: fixture.home.appendingPathComponent("pacer/hook-state.json")), initialState)
            }
        }
        let bytes = try Data(contentsOf: fixture.home.appendingPathComponent("pacer/events.jsonl"))
        XCTAssertFalse(String(decoding: bytes, as: UTF8.self).contains("PRIVATE")); XCTAssertFalse(String(decoding: bytes, as: UTF8.self).contains("Request interrupted"))
        let rows = try bytes.split(separator: 10).map { try XCTUnwrap(JSONSerialization.jsonObject(with: Data($0)) as? [String: Any]) }
        XCTAssertEqual(rows.first { $0["kind"] as? String == "prompt" }?["typedInterruptMarker"] as? Bool, true)
        let partials = rows.filter { $0["kind"] as? String == "responseDelta" }; XCTAssertEqual(partials.count, 1)
        XCTAssertEqual(partials.first?["hasText"] as? Bool, true); XCTAssertEqual(partials.first?["index"] as? Int, 0)
    }
    func testIneligibleDisplayBatchesExitBeforeFilesystemLockAndCannotAlterOwnership() throws {
        let fixture = try fixture(); defer { try? FileManager.default.removeItem(at: fixture.root) }
        _ = try ClaudeHookInstaller.install(home: fixture.home)
        let valid: [String: Any] = ["hook_event_name": "MessageDisplay", "session_id": "fixture-session", "prompt_id": "old-prompt",
            "agent_id": "unobserved-agent", "message_id": "message-1", "turn_id": "display-turn-1", "index": 0, "final": false, "delta": "PRIVATE text"]
        let changes: [[String: Any]] = [["final": true], ["index": 1], ["index": 999], ["index": false], ["index": 0.5],
                                       ["delta": ""], ["delta": ["text": "PRIVATE"]], ["message_id": ""],
                                       ["turn_id": "invalid turn"], ["turn_id": "turn\n"], ["message_id": "message\n"], ["session_id": "session\n"]]
        let inputs = changes.map { valid.merging($0) { _, new in new } }
        let file = fixture.root.appendingPathComponent("callbacks.json"); try JSONSerialization.data(withJSONObject: inputs).write(to: file)
        let program = """
        import json,pathlib,sys
        namespace={'__name__':'pacer_fixture'}
        source=pathlib.Path(sys.argv[1]);exec(compile(source.read_text(),str(source),'exec'),namespace)
        def forbidden(*args,**kwargs):raise AssertionError('ineligible callback touched persistence')
        for name in ('private_open','read_object','write_object'):namespace[name]=forbidden
        namespace['fcntl'].flock=forbidden
        invalid=['session\\n','prompt\\n','tool\\n','agent\\n','message\\n']
        for value in invalid:assert namespace['ident'](value) is None
        values=json.loads(pathlib.Path(sys.argv[2]).read_text())
        for value in values:namespace['hook'](pathlib.Path(sys.argv[3]),value)
        print(json.dumps({'callbacks':len(values),'persistenceCalls':0,'rejectedIDs':len(invalid)}))
        """
        let process = Process(), output = Pipe(), errors = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = ["-c", program, fixture.home.appendingPathComponent("pacer/hook.py").path, file.path, fixture.home.path]
        process.standardInput = FileHandle.nullDevice; process.standardOutput = output; process.standardError = errors
        try process.run(); let bytes = output.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0); XCTAssertTrue(errors.fileHandleForReading.readDataToEndOfFile().isEmpty)
        let observed = try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: Int])
        XCTAssertEqual(observed["callbacks"], inputs.count); XCTAssertEqual(observed["persistenceCalls"], 0)
        XCTAssertEqual(observed["rejectedIDs"], 5)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.home.appendingPathComponent("pacer/events.jsonl").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.home.appendingPathComponent("pacer/hook-state.json").path))
    }
    func testEligibleFirstDisplayKeepsStoredPromptAndChildParentAttribution() throws {
        let fixture = try fixture(); defer { try? FileManager.default.removeItem(at: fixture.root) }
        _ = try ClaudeHookInstaller.install(home: fixture.home)
        let common: [String: Any] = ["session_id": "fixture-session", "cwd": "/PRIVATE/fixture-project"]
        _ = try runScript(home: fixture.home, mode: "hook", input: common.merging(["hook_event_name": "UserPromptSubmit", "prompt_id": "owned-prompt"]) { _, new in new })
        _ = try runScript(home: fixture.home, mode: "hook", input: common.merging(["hook_event_name": "SubagentStart", "agent_id": "fixture-child"]) { _, new in new })
        for agent in [String?.none, "fixture-child"] {
            var display = common.merging(["hook_event_name": "MessageDisplay", "message_id": "message-1", "turn_id": "display-turn-1", "index": 0, "final": false, "delta": "PRIVATE displayed text"]) { _, new in new }
            if let agent { display["agent_id"] = agent }
            let result = try runScript(home: fixture.home, mode: "hook", input: display)
            XCTAssertTrue(result.stdout.isEmpty); XCTAssertTrue(result.stderr.isEmpty)
        }
        let bytes = try Data(contentsOf: fixture.home.appendingPathComponent("pacer/events.jsonl"))
        let rows = try bytes.split(separator: 10).map { try XCTUnwrap(JSONSerialization.jsonObject(with: Data($0)) as? [String: Any]) }
        let displays = rows.filter { $0["kind"] as? String == "responseDelta" }; XCTAssertEqual(displays.count, 2)
        XCTAssertTrue(displays.allSatisfy { $0["promptId"] as? String == "owned-prompt" && $0["hasText"] as? Bool == true })
        XCTAssertEqual(displays.first { $0["sessionId"] as? String == "fixture-child" }?["parentId"] as? String, "fixture-session")
        XCTAssertFalse(String(decoding: bytes, as: UTF8.self).contains("PRIVATE"))
    }
    func testAgentResultsKeepOnlyTypedOwnershipAndUnstartedInternalHooksDoNotWrite() throws {
        let fixture = try fixture(); defer { try? FileManager.default.removeItem(at: fixture.root) }
        _ = try ClaudeHookInstaller.install(home: fixture.home)
        let common: [String: Any] = ["session_id": "fixture-session", "prompt_id": "owned-prompt", "cwd": "/PRIVATE/fixture-project"]
        _ = try runScript(home: fixture.home, mode: "hook", input: common.merging(["hook_event_name": "UserPromptSubmit"]) { _, new in new })
        let spool = fixture.home.appendingPathComponent("pacer/events.jsonl"), state = fixture.home.appendingPathComponent("pacer/hook-state.json")
        let originalSpool = try Data(contentsOf: spool), originalState = try Data(contentsOf: state)
        for input: [String: Any] in [["hook_event_name": "PreToolUse", "agent_id": "internal-agent", "tool_use_id": "internal-tool"],
                                    ["hook_event_name": "SubagentStop", "agent_id": "internal-agent"],
                                    ["hook_event_name": "SubagentStart", "agent_id": "child\n"],
                                    ["hook_event_name": "PreToolUse", "prompt_id": "prompt\n", "tool_use_id": "tool"],
                                    ["hook_event_name": "PreToolUse", "tool_use_id": "tool\n"]] {
            _ = try runScript(home: fixture.home, mode: "hook", input: common.merging(input) { _, new in new })
        }
        XCTAssertEqual(try Data(contentsOf: spool), originalSpool); XCTAssertEqual(try Data(contentsOf: state), originalState)
        for input: [String: Any] in [["hook_event_name": "SubagentStart", "agent_id": "internal-agent"],
                                    ["hook_event_name": "PreToolUse", "tool_name": "Agent", "tool_use_id": "agent-tool"],
                                    ["hook_event_name": "PostToolUse", "tool_name": "Agent", "tool_use_id": "agent-tool", "tool_response": ["status": "async_launched", "agentId": "internal-agent", "outputFile": "/PRIVATE/output"]],
                                    ["hook_event_name": "PostToolUse", "tool_name": "Agent", "tool_use_id": "agent-tool", "tool_response": ["status": "completed", "agentId": "internal-agent", "content": "PRIVATE response", "prompt": "PRIVATE prompt"]]] {
            let result = try runScript(home: fixture.home, mode: "hook", input: common.merging(input) { _, new in new })
            XCTAssertTrue(result.stdout.isEmpty); XCTAssertTrue(result.stderr.isEmpty)
        }
        let bytes = try Data(contentsOf: spool)
        let rows = try bytes.split(separator: 10).map { try XCTUnwrap(JSONSerialization.jsonObject(with: Data($0)) as? [String: Any]) }
        let results = rows.filter { $0["kind"] as? String == "agentResult" }
        XCTAssertEqual(results.compactMap { $0["agentStatus"] as? String }, ["async_launched", "completed"])
        XCTAssertTrue(results.allSatisfy { $0["agentId"] as? String == "internal-agent" && $0["itemId"] as? String == "agent-tool" && $0["promptId"] as? String == "owned-prompt" })
        XCTAssertTrue(rows.contains { $0["kind"] as? String == "toolStart" && $0["agentTool"] as? Bool == true })
        XCTAssertFalse(String(decoding: bytes, as: UTF8.self).contains("PRIVATE"))
    }
}
