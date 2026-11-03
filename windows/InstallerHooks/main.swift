import Foundation
import WindowsInstallerSupport

let arguments = Array(CommandLine.arguments.dropFirst())
var result: Int32 = 2
if arguments.count == 2, ["--uninstall", "--check-uninstall"].contains(arguments[0]) {
    do {
        try WindowsClaudeHookCleanup.uninstall(home: URL(fileURLWithPath: arguments[1], isDirectory: true),
            checkOnly: arguments[0] == "--check-uninstall")
        result = 0
    } catch {
        // No paths, provider settings, account data or record contents in diagnostics.
        FileHandle.standardError.write(Data("Pacer could not safely remove its Claude configuration.\n".utf8))
        result = 1
    }
}
exit(result)
