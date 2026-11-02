#if os(Windows)
import Foundation
import Subprocess
import CWindowsSupport

enum WindowsExecutables {
    static var ssh: URL {
        let system = ProcessInfo.processInfo.environment["SystemRoot"] ?? "C:\\Windows"
        return URL(fileURLWithPath: system).appendingPathComponent("System32/OpenSSH/ssh.exe")
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
    static func capture(executable: URL, arguments: [String], timeout: TimeInterval, limit: Int) async -> Data? {
        guard executable.isFileURL, limit > 0, limit <= 1024 * 1024, timeout > 0 else { return nil }
        return await withTaskGroup(of: Data?.self) { group in
            group.addTask {
                var options = PlatformOptions()
                options.consoleBehavior = .detach
                options.windowStyle = .hidden
                do {
                    let path = executable.withUnsafeFileSystemRepresentation { String(cString: $0!) }
                    let result = try await Subprocess.run(.path(.init(path)), arguments: Arguments(arguments),
                        platformOptions: options, output: .data(limit: limit), error: .discarded)
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
