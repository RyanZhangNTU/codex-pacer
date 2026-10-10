import XCTest
import Darwin
@testable import PacerCore

final class ClaudeSSHRouteResolverTests: XCTestCase {
    private func data(_ value: String) -> Data { Data(value.utf8) }
    private func fixture(_ body: String) throws -> (URL, URL) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("pacer-route-test-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        let executable = directory.appendingPathComponent("ssh-fixture")
        try ("#!/bin/sh\n" + body + "\n").write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        return (directory, executable)
    }

    func testOnlyValidatedCanonicalRoutingFieldsSurviveConfigurationProjection() {
        let route = ClaudeSSHRouteResolver.parse(data("hostname GPU.Example.\nuser fixture_user\nport 2200\nidentityfile PRIVATE\nproxycommand PRIVATE\n"))
        XCTAssertEqual(route, ClaudeSSHRoute(hostname: "gpu.example", user: "fixture_user", port: 2200))
        XCTAssertFalse(String(describing: route).contains("PRIVATE"))
        XCTAssertNotNil(ClaudeSSHRouteResolver.parse(data("hostname ::1\nuser fixture\nport 22\n")))
        XCTAssertEqual(ClaudeSSHRouteResolver.parse(data("hostname 0:0:0:0:0:0:0:1\nuser fixture\nport 22\n"))?.hostname, "::1")
        for invalid in ["hostname host\nuser fixture\n", "hostname host\nuser fixture\nport 0\n",
                        "hostname host\nuser fixture\nport 65536\n", "hostname host\nuser fixture\nport +22\n",
                        "hostname -option\nuser fixture\nport 22\n", "hostname host;command\nuser fixture\nport 22\n",
                        "hostname host\nuser user@host\nport 22\n", "hostname a\nhostname b\nuser fixture\nport 22\n"] {
            XCTAssertNil(ClaudeSSHRouteResolver.parse(data(invalid)))
        }
        XCTAssertNil(ClaudeSSHRouteResolver.parse(Data([255])))
        XCTAssertNil(ClaudeSSHRouteResolver.parse(Data(repeating: 120, count: 65537)))
    }

    func testEffectiveAliasAndExplicitMetadataPortUseReadOnlyArguments() async throws {
        let (directory, executable) = try fixture("printf '%s\\n' \"$@\" > \"$(dirname \"$0\")/arguments\"\nprintf 'hostname gpu.example\\nuser fixture\\nport 2200\\n'")
        defer { try? FileManager.default.removeItem(at: directory) }
        let route = await ClaudeSSHRouteResolver.resolve(host: "fixture@alias", port: 2200, executable: executable)
        XCTAssertEqual(route, ClaudeSSHRoute(hostname: "gpu.example", user: "fixture", port: 2200))
        let arguments = try String(contentsOf: directory.appendingPathComponent("arguments"), encoding: .utf8)
        XCTAssertTrue(arguments.hasPrefix("-G\n"))
        XCTAssertTrue(arguments.contains("CanonicalizeHostname=no\n"))
        XCTAssertTrue(arguments.hasSuffix("-p\n2200\n--\nfixture@alias\n"))
    }

    func testInjectedHostsAndPortsCannotLaunchAProcess() async throws {
        let (directory, executable) = try fixture("touch \"$(dirname \"$0\")/ran\"\nprintf 'hostname host\\nuser fixture\\nport 22\\n'")
        defer { try? FileManager.default.removeItem(at: directory) }
        for host in ["-option", "host;command", "host\ncommand", "host space", "user@@host", "user@-option", "@host", "host:", String(repeating: "x", count: 130)] {
            let route = await ClaudeSSHRouteResolver.resolve(host: host, executable: executable)
            XCTAssertNil(route)
        }
        for port in [0, 65536, -1] {
            let route = await ClaudeSSHRouteResolver.resolve(host: "alias", port: port, executable: executable)
            XCTAssertNil(route)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("ran").path))
    }

    func testBoundedOutputAndFailedExitCannotProduceAValidRoute() async throws {
        let cases = ["printf 'hostname host\\nuser fixture\\nport 22\\n'; exit 7",
                     "exec /usr/bin/python3 -c 'import sys;sys.stdout.write(\"hostname host\\nuser fixture\\nport 22\\n\" + \"x\" * 70000)'"]
        for body in cases {
            let (directory, executable) = try fixture(body)
            let route = await ClaudeSSHRouteResolver.resolve(host: "alias", executable: executable)
            XCTAssertNil(route)
            try FileManager.default.removeItem(at: directory)
        }
    }

    func testTimeoutAndCancellationStopOnlyTheOwnedProcess() async throws {
        for cancelled in [false, true] {
            // Built-in expansion announces this process before any external
            // command. A short timeout must not race a dirname subprocess.
            let (directory, executable) = try fixture("printf '%s' \"$$\" > \"${0%/*}/pid\"\nexec /bin/sleep 20")
            defer { try? FileManager.default.removeItem(at: directory) }
            let task = Task { await ClaudeSSHRouteResolver.resolve(host: "alias", executable: executable, timeout: cancelled ? 3 : 1) }
            defer { task.cancel() }
            let pidFile = directory.appendingPathComponent("pid"), started = Date()
            var readyPID: Int32?
            while readyPID == nil, Date().timeIntervalSince(started) < 2 {
                if let text = try? String(contentsOf: pidFile, encoding: .utf8) { readyPID = Int32(text) }
                if readyPID != nil { break }
                try await Task.sleep(nanoseconds: 10_000_000)
            }
            guard let pid = readyPID else {
                task.cancel(); _ = await task.value
                XCTFail("Owned route fixture did not announce its process ID before the readiness deadline")
                continue
            }
            if cancelled { task.cancel() }
            let result = await task.value
            XCTAssertNil(result)
            XCTAssertLessThan(Date().timeIntervalSince(started), 2.5)
            let ended = Date()
            while Darwin.kill(pid, 0) == 0, Date().timeIntervalSince(ended) < 1 {
                try await Task.sleep(nanoseconds: 10_000_000)
            }
            XCTAssertNotEqual(Darwin.kill(pid, 0), 0)
        }
    }
}
