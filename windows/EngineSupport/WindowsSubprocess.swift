#if os(Windows)
import Foundation
import PacerCore
import Subprocess
import CWindowsSupport

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

enum WindowsSubprocess {
    static func capture(executable: URL, arguments: [String], timeout: TimeInterval, limit: Int,
                        environment: [String: String] = ProcessInfo.processInfo.environment) async -> Data? {
        guard executable.isFileURL, limit > 0, limit <= 1024 * 1024, timeout > 0 else { return nil }
        return await withTaskGroup(of: Data?.self) { group in
            group.addTask {
                var options = PlatformOptions()
                options.consoleBehavior = .detach
                options.windowStyle = .hidden
                do {
                    let path = executable.withUnsafeFileSystemRepresentation { String(cString: $0!) }
                    let variables = environment.reduce(into: [Environment.Key: String]()) { $0[Environment.Key(stringLiteral: $1.key)] = $1.value }
                    let result = try await Subprocess.run(.path(.init(path)), arguments: Arguments(arguments),
                        environment: .custom(variables), platformOptions: options, output: .data(limit: limit), error: .discarded)
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
