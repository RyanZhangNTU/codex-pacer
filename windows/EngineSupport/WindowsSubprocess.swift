#if os(Windows)
import Foundation
import PacerCore
import Subprocess
import SystemPackage
import CWindowsSupport
import WinSDK

enum WindowsConsole {
    /// Console tools such as wsl.exe relaunch themselves. Under DETACHED_PROCESS
    /// that grandchild opened its own visible console, so children instead get a
    /// windowless console that their descendants inherit.
    static func hide(_ options: inout PlatformOptions) {
        options.consoleBehavior = .inherit
        options.windowStyle = .hidden
        options.preSpawnProcessConfigurator = { flags, _ in flags |= DWORD(CREATE_NO_WINDOW) }
    }
}

enum WindowsExecutables {
    // A local Python runtime is only used when the host enables helper features.
    // Windows local Desktop collection uses the native authenticated pipe.
    static var python: URL {
        let environment = ProcessInfo.processInfo.environment
        for directory in (environment["PATH"] ?? environment["Path"] ?? "").split(separator: ";") {
            let url = URL(fileURLWithPath: String(directory)).appendingPathComponent("python.exe")
            if FileManager.default.fileExists(atPath: url.path) { return url }
        }
        return URL(fileURLWithPath: "C:/Windows/System32/python.exe")
    }
    static var ssh: URL {
        findSSH(environment: ProcessInfo.processInfo.environment) ?? URL(fileURLWithPath: "C:/Windows/System32/OpenSSH/ssh.exe")
    }
    static func findSSH(environment: [String: String], exists: (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) }) -> URL? {
        let system = WindowsEnvironment.value("SystemRoot", in: environment) ?? "C:/Windows"
        let builtin = URL(fileURLWithPath: system).appendingPathComponent("System32/OpenSSH/ssh.exe")
        if exists(builtin) { return builtin }
        for entry in (WindowsEnvironment.value("PATH", in: environment) ?? "").split(separator: ";") {
            let path = String(entry).trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            guard WindowsCodexExecutableDiscovery.absolute(path) else { continue }
            let file = URL(fileURLWithPath: path).appendingPathComponent("ssh.exe")
            if exists(file) { return file }
        }
        return nil
    }
}

enum WindowsIP {
    static func normalizedIPv6(_ value: String) -> String? {
        var output = [CChar](repeating: 0, count: 128)
        guard value.withCString({ pacer_normalize_ipv6($0, &output, output.count) }) != 0 else { return nil }
        return String(cString: output)
    }
}

/// The null device that captured children read as standard input and write
/// standard error to.
///
/// For `.none` input and `.discarded` output, swift-subprocess opens `NUL`
/// through the C runtime on every run and later closes only the Win32 handle,
/// so the C runtime descriptor is never released. Captures used both, and the
/// WSL discovery that runs every 30 seconds used up the runtime's 8,192
/// descriptors in about 15 hours. The next run could not open `NUL`, and the
/// library stopped the engine while discarding the pipe it had already
/// created. These two descriptors are opened once and never closed by the
/// library; each child inherits a duplicate.
enum WindowsNullDevice {
    struct Descriptors: Sendable {
        let input: FileDescriptor
        let output: FileDescriptor
    }
    private final class State: @unchecked Sendable {
        let lock = NSLock()
        var descriptors: Descriptors?
    }
    private static let state = State()

    /// Opens the descriptors on first use and retries after a failed open.
    static var shared: Descriptors? {
        state.lock.lock(); defer { state.lock.unlock() }
        if let descriptors = state.descriptors { return descriptors }
        guard let input = try? FileDescriptor.open("NUL", .readOnly) else { return nil }
        guard let output = try? FileDescriptor.open("NUL", .writeOnly) else { try? input.close(); return nil }
        let descriptors = Descriptors(input: input, output: output)
        state.descriptors = descriptors
        return descriptors
    }
}

enum WindowsSubprocess {
    static func capture(executable: URL, arguments: [String], timeout: TimeInterval, limit: Int,
                        environment: [String: String] = ProcessInfo.processInfo.environment) async -> Data? {
        guard executable.isFileURL, limit > 0, limit <= 1024 * 1024, timeout > 0, let null = WindowsNullDevice.shared else { return nil }
        return await withTaskGroup(of: Data?.self) { group in
            group.addTask {
                var options = PlatformOptions()
                WindowsConsole.hide(&options)
                do {
                    let path = executable.withUnsafeFileSystemRepresentation { String(cString: $0!) }
                    let variables = environment.reduce(into: [Environment.Key: String]()) { $0[Environment.Key(stringLiteral: $1.key)] = $1.value }
                    let result = try await Subprocess.run(.path(.init(path)), arguments: Arguments(arguments),
                        environment: .custom(variables), platformOptions: options,
                        input: .fileDescriptor(null.input, closeAfterSpawningProcess: false), output: .data(limit: limit),
                        error: .fileDescriptor(null.output, closeAfterSpawningProcess: false))
                    guard result.terminationStatus.isSuccess else { return nil }
                    return result.standardOutput
                } catch { return nil }
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(min(timeout, 60) * 1_000_000_000))
                return nil
            }
            let result = await group.next() ?? nil
            group.cancelAll()
            return result
        }
    }
}
#endif
