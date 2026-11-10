#if os(Windows)
import Foundation
import CWindowsSupport
import WinSDK

/// Opens the engine's crash report before anything else runs.
///
/// The host names the folder, this start's identifier and its own version.
/// `CrashReport.c` writes the report if the engine later stops on an unhandled
/// exception, a damaged heap or `abort()`; the host then adds the exit code to
/// the file with the same identifier, so one start's exit never lands in another's report.
enum WindowsCrashReport {
    static let directoryFlag = "--crash-log-directory", identifierFlag = "--crash-log-id", versionFlag = "--app-version", diagnoseFlag = "--diagnose-crash"

    /// The report's file, or nil when the host named no usable folder or identifier.
    @discardableResult
    static func install(_ arguments: [String] = CommandLine.arguments) -> URL? {
        guard let path = value(directoryFlag, in: arguments), path.utf16.count < 1000, WindowsCodexExecutableDiscovery.absolute(path) else { return nil }
        let directory = URL(fileURLWithPath: path, isDirectory: true)
        guard WindowsFileSystem().metadata(directory, followingSymbolicLinks: false)?.isDirectory == true else { return nil }
        var version = "unknown"
        if let text = value(versionFlag, in: arguments), text.range(of: #"^[0-9]{1,5}(\.[0-9]{1,5}){1,3}$"#, options: .regularExpression) != nil { version = text }
        func padded(_ text: String, _ width: Int) -> String { String(repeating: "0", count: max(0, width - text.count)) + text }
        let identifier: String
        if arguments.contains(identifierFlag) {
            // The identifier becomes a file name, so only the host's own form is taken.
            guard let named = value(identifierFlag, in: arguments),
                  named.range(of: #"^[0-9]{8}-[0-9]{6}-[0-9a-f]{8}$"#, options: .regularExpression) != nil else { return nil }
            identifier = named
        } else {
            // Run by hand, without a host: the start time and the process are unique enough.
            var time = SYSTEMTIME(); GetSystemTime(&time)
            identifier = padded(String(time.wYear), 4) + padded(String(time.wMonth), 2) + padded(String(time.wDay), 2) + "-"
                + padded(String(time.wHour), 2) + padded(String(time.wMinute), 2) + padded(String(time.wSecond), 2) + "-"
                + padded(String(GetCurrentProcessId(), radix: 16), 8)
        }
        let file = directory.appendingPathComponent("engine-crash-" + identifier + ".txt")
        #if arch(arm64)
        let architecture = "arm64"
        #else
        let architecture = "x64"
        #endif
        guard pacer_crash_report_install(WindowsFiles.wide(file), "app: " + version + "\nengine: " + architecture + "\n") != 0 else { return nil }
        return file
    }

    /// Stops the engine the way a real fault would, so the report can be checked
    /// on any machine: `PacerEngine.exe --crash-log-directory <folder> --diagnose-crash <kind>`.
    static func diagnose(_ arguments: [String] = CommandLine.arguments) -> Bool {
        guard let kind = value(diagnoseFlag, in: arguments) else { return false }
        // The failure is deliberate; keep Windows from offering to debug it.
        _ = SetErrorMode(UINT(SEM_NOGPFAULTERRORBOX) | UINT(SEM_FAILCRITICALERRORS))
        switch kind {
        case "access-violation": fault(at: 0x1000)
        case "fatal-error": fatalError("Synthetic engine failure")
        case "abort": abort()
        default: break
        }
        return true
    }

    @inline(never)
    private static func fault(at address: UInt) {
        UnsafeMutablePointer<UInt8>(bitPattern: address)?.pointee = 1
    }

    private static func value(_ flag: String, in arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: flag), arguments.indices.contains(index + 1) else { return nil }
        return arguments[index + 1]
    }
}
#endif
