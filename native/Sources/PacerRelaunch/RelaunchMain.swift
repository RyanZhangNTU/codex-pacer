import AppKit
import Darwin
import Foundation

/// Wait for a normal shutdown before reopening the app with its new preferences.
@main enum RelaunchMain {
    @MainActor static func main() async {
        let arguments = CommandLine.arguments
        guard arguments.count >= 3, let pid = pid_t(arguments[1]), pid > 1,
              arguments[2].hasPrefix("/"), arguments[2].hasSuffix(".app") else { exit(1) }
        for _ in 0..<150 {
            if kill(pid, 0) != 0 && errno == ESRCH {
                let configuration = NSWorkspace.OpenConfiguration()
                configuration.activates = true
                configuration.createsNewApplicationInstance = true
                configuration.arguments = Array(arguments.dropFirst(3))
                do {
                    _ = try await NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: arguments[2]), configuration: configuration)
                    return
                } catch { exit(1) }
            }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        // Do not start a duplicate if the original app could not finish quitting.
        exit(1)
    }
}
