@testable import PacerEngineSupport
#if os(Windows)
import Foundation
import XCTest

/// Stops the real engine in the ways it can fail and reads the report it leaves.
final class WindowsCrashReportTests: XCTestCase {
    private struct Stop {
        let status: Int32, errors: String, folder: URL, reports: [URL]
        func text() throws -> String { String(decoding: try Data(contentsOf: try XCTUnwrap(reports.first)), as: UTF8.self) }
    }
    private func engine() throws -> URL {
        let folders = [Bundle.main.executableURL, URL(fileURLWithPath: CommandLine.arguments[0])].compactMap { $0?.deletingLastPathComponent() }
        return try XCTUnwrap(folders.map { $0.appendingPathComponent("PacerEngine.exe") }.first { FileManager.default.fileExists(atPath: $0.path) },
                             "The engine is built beside its tests")
    }
    private func stop(_ kind: String, reporting: Bool = true, version: String = "9.8.7.6", identifier: String? = nil,
                      existing: [String: String] = [:]) throws -> Stop {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("pacer-crash-中文 " + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        for (name, text) in existing { try Data(text.utf8).write(to: folder.appendingPathComponent(name)) }
        let process = Process(), errors = Pipe()
        process.executableURL = try engine()
        process.arguments = (reporting ? ["--crash-log-directory", WindowsCodexExecutableDiscovery.path(folder), "--app-version", version] : [])
            + (identifier.map { ["--crash-log-id", $0] } ?? []) + ["--diagnose-crash", kind]
        process.standardInput = FileHandle.nullDevice; process.standardOutput = FileHandle.nullDevice; process.standardError = errors
        try process.run()
        let text = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        return Stop(status: process.terminationStatus, errors: text, folder: folder,
                    reports: try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil))
    }
    private func matches(_ text: String, _ pattern: String) -> Bool { text.range(of: pattern, options: .regularExpression) != nil }

    func testAnAccessViolationLeavesAReportThatLocatesTheFault() throws {
        let stopped = try stop("access-violation")
        XCTAssertEqual(stopped.status & 0xFF, 0x05, "Foundation keeps the low byte of exit code 0xC0000005")
        XCTAssertEqual(stopped.reports.count, 1)
        XCTAssertTrue(matches(try XCTUnwrap(stopped.reports.first).lastPathComponent, #"^engine-crash-[0-9]{8}-[0-9]{6}-[0-9a-f]{8}\.txt$"#),
                      "Run by hand, the engine names the report by its start time and process")
        let text = try stopped.text(), lines = text.split(separator: "\n").map(String.init)
        XCTAssertEqual(lines.first, "Codex Pacer engine crash report 1")
        XCTAssertTrue(matches(text, #"(?m)^time: [0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$"#))
        XCTAssertTrue(lines.contains("app: 9.8.7.6"))
        XCTAssertTrue(lines.contains("engine: x64") || lines.contains("engine: arm64"))
        XCTAssertTrue(matches(text, #"(?m)^windows: 10\.0\.[0-9]{5}\.[0-9]+$"#), "The update revision selects the system binaries")
        XCTAssertTrue(matches(text, #"(?m)^process: [0-9]+ thread: [0-9]+ running: [0-9]+ s$"#))
        XCTAssertTrue(lines.contains("reason: unhandled exception"))
        XCTAssertTrue(matches(text, #"(?m)^exception: 0xC0000005 flags: 0x0 parameters: 0x1 0x1000$"#))
        XCTAssertTrue(lines.contains("detail: access violation writing 0x1000"))
        let address = try XCTUnwrap(lines.first { $0.hasPrefix("address: ") }).dropFirst("address: ".count)
        XCTAssertTrue(matches(String(address), #"^PacerEngine\.exe\+0x[0-9A-F]+$"#))
        let frames = lines.filter { matches($0, #"^  [0-9]+ "#) }
        XCTAssertEqual(frames.first, "  0 " + address, "The stack starts where the fault happened")
        XCTAssertGreaterThanOrEqual(frames.filter { $0.contains("PacerEngine.exe+0x") }.count, 2, "The engine's own callers are listed")
        XCTAssertTrue(frames.last?.contains("ntdll.dll+0x") == true, "The walk reaches the thread's start")
        XCTAssertTrue(frames.allSatisfy { matches($0, #"^  [0-9]+ [A-Za-z0-9._-]+\+0x[0-9A-F]+$"#) }, "Every frame is a place in a module")
        // A module's link time and image size find its binary on a symbol server; the symbol identity finds its symbols.
        XCTAssertTrue(matches(text, #"(?m)^  PacerEngine\.exe time: [0-9A-F]{8} size: [0-9A-F]+"#))
        XCTAssertTrue(matches(text, #"(?m)^  ntdll\.dll time: [0-9A-F]{8} size: [0-9A-F]+ symbols: ntdll\.pdb [0-9A-F]{33,40}$"#))
    }
    func testAReportHoldsNoPathsNamesOrText() throws {
        let text = try stop("access-violation").text()
        XCTAssertFalse(text.contains("\\") || text.contains("/"), "Modules are named without their folders")
        XCTAssertFalse(text.contains("中文"), "Neither the report's own folder nor the arguments are recorded")
        XCTAssertFalse(text.contains("registers") || text.contains("rax=") || text.contains("x0="), "A register can hold the bytes the engine was handling")
        let fields = Set(text.split(separator: "\n").filter { !$0.hasPrefix(" ") }.map { String($0.prefix { $0 != ":" }) })
        XCTAssertEqual(fields, ["Codex Pacer engine crash report 1", "time", "app", "engine", "windows", "process", "reason", "exception", "detail", "address", "stack", "modules"],
                       "A report has these fields and no others")
        // A name made only of hexadecimal digits could match an address by chance.
        let user = NSUserName()
        if !user.isEmpty, !user.allSatisfy(\.isHexDigit) { XCTAssertFalse(text.localizedCaseInsensitiveContains(user)) }
        XCTAssertTrue(text.unicodeScalars.allSatisfy { $0 == "\n" || (32..<127).contains($0.value) })
        XCTAssertLessThan(text.utf8.count, 16 * 1024)
    }
    func testASwiftFatalErrorLeavesAReportAndItsMessageOnStandardError() throws {
        let stopped = try stop("fatal-error")
        XCTAssertEqual(stopped.status & 0xFF, 0x1D, "Foundation keeps the low byte of exit code 0xC000001D")
        XCTAssertTrue(matches(stopped.errors, #"(?m)^PacerEngineSupport/WindowsCrashReport\.swift:[0-9]+: Fatal error: Synthetic engine failure"#),
                      "The host reads the source line from this text and keeps none of the message")
        let text = try stopped.text()
        XCTAssertTrue(text.contains("exception: 0xC000001D"))
        XCTAssertTrue(matches(text, #"(?m)^address: swiftCore\.dll\+0x[0-9A-F]+$"#))
        XCTAssertTrue(matches(text, #"(?m)^  [0-9]+ PacerEngine\.exe\+0x[0-9A-F]+$"#))
    }
    func testAbortLeavesAReportAlthoughNoExceptionHandlerSeesIt() throws {
        let stopped = try stop("abort")
        XCTAssertNotEqual(stopped.status, 0)
        let text = try stopped.text()
        XCTAssertTrue(text.contains("\nreason: abort\n"))
        XCTAssertFalse(text.contains("\nexception: "))
        XCTAssertTrue(matches(text, #"(?m)^  [0-9]+ PacerEngine\.exe\+0x[0-9A-F]+$"#))
    }
    func testAnEngineThatDoesNotFailLeavesNoFile() throws {
        let quiet = try stop("none")
        XCTAssertEqual(quiet.status, 0)
        XCTAssertEqual(quiet.reports, [], "The open report disappears with a process that wrote nothing")
        XCTAssertEqual(try stop("access-violation", reporting: false).reports, [], "Without a folder from the host nothing is written")
    }
    func testOnlyANumericVersionIsRecorded() throws {
        let text = try stop("access-violation", version: "4.3.2 beta private").text()
        XCTAssertTrue(text.split(separator: "\n").contains("app: unknown"))
        XCTAssertFalse(text.contains("private"))
    }
    func testTheHostsIdentifierNamesTheReportAndNeverReplacesAnother() throws {
        let identifier = "20260102-030405-0a1b2c3d", name = "engine-crash-" + identifier + ".txt"
        let stopped = try stop("access-violation", identifier: identifier)
        XCTAssertEqual(stopped.reports.map(\.lastPathComponent), [name], "The host finds this start's report by the name it chose")
        XCTAssertTrue(try stopped.text().contains("reason: unhandled exception"))
        // A name that is already taken belongs to another start; its report stays as it was and survives this engine.
        let taken = try stop("access-violation", identifier: identifier, existing: [name: "an earlier report"])
        XCTAssertEqual(taken.reports.map(\.lastPathComponent), [name])
        XCTAssertEqual(try taken.text(), "an earlier report")
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("pacer-crash-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        // Anything but the host's own form could name a file elsewhere.
        for unusable in ["..\\20260102-030405-0a1b2c3d", "20260102-030405-0A1B2C3D", "20260102-030405-0a1b2c3d.txt", "report", ""] {
            XCTAssertNil(WindowsCrashReport.install(["PacerEngine.exe", "--crash-log-directory", WindowsCodexExecutableDiscovery.path(folder), "--crash-log-id", unusable]), unusable)
        }
        XCTAssertNil(WindowsCrashReport.install(["PacerEngine.exe", "--crash-log-directory", WindowsCodexExecutableDiscovery.path(folder), "--crash-log-id"]))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder.path), [])
    }
    func testOnlyAnExistingAbsoluteFolderIsAccepted() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("pacer-crash-" + UUID().uuidString)
        XCTAssertNil(WindowsCrashReport.install(["PacerEngine.exe", "--crash-log-directory", WindowsCodexExecutableDiscovery.path(folder)]), "A missing folder")
        XCTAssertNil(WindowsCrashReport.install(["PacerEngine.exe", "--crash-log-directory", "relative\\folder"]))
        XCTAssertNil(WindowsCrashReport.install(["PacerEngine.exe", "--crash-log-directory"]))
        XCTAssertNil(WindowsCrashReport.install(["PacerEngine.exe"]))
        XCTAssertFalse(WindowsCrashReport.diagnose(["PacerEngine.exe", "--demo"]))
    }
}
#endif
