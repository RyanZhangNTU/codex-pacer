import Foundation
import PacerCore
import PacerEngineSupport

/// Uninstall removes Pacer's Harness entry, its reporter and its enable file
/// from every home Pacer configured. An entry someone edited is left in place
/// and fails cleanup, so the installer can show manual instructions.
public enum WindowsDeepSeekProgressCleanup {
    struct Failure: Error {}

    public static func unregister(homes: [URL], checkOnly: Bool, storage: any ClaudeHookStorage = WindowsLocalProfileStorage()) throws {
        var failed = false
        for home in homes where DeepSeekProgressSetup.wasConfigured(in: home) {
            if DeepSeekProgressSetup.apply(home: home, enabled: false, storage: storage, checkOnly: checkOnly) != nil { failed = true }
        }
        if failed { throw Failure() }
    }
}
