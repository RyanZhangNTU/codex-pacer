import Foundation
import WindowsInstallerSupport

let arguments = Array(CommandLine.arguments.dropFirst())
// A synchronous filesystem/provider call cannot hold a shell hook or uninstall
// helper forever. Hosts also impose their own shorter async request deadlines.
DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 9) { exit(124) }
var result: Int32 = 2
do {
    if arguments.count == 2, ["--uninstall", "--check-uninstall"].contains(arguments[0]) {
        try WindowsClaudeHookCleanup.uninstall(home: URL(fileURLWithPath: arguments[1], isDirectory: true),
            checkOnly: arguments[0] == "--check-uninstall")
        result = 0
    } else if arguments.count >= 2, ["--uninstall-all", "--check-uninstall-all", "--uninstall-all-continue"].contains(arguments[0]) {
        guard arguments.count <= 18 else { exit(2) }
        let runtime = WindowsClaudeHookRuntime(root: URL(fileURLWithPath: arguments[1], isDirectory: true))
        try runtime.uninstall(homes: arguments.dropFirst(2).map { URL(fileURLWithPath: $0, isDirectory: true) },
            checkOnly: arguments[0] == "--check-uninstall-all", continueAfterFailure: arguments[0] == "--uninstall-all-continue")
        result = 0
    } else if arguments.count == 3, ["--ensure", "--inspect", "--uninstall-home"].contains(arguments[0]) {
        let home = URL(fileURLWithPath: arguments[1], isDirectory: true)
        let runtime = WindowsClaudeHookRuntime(root: URL(fileURLWithPath: arguments[2], isDirectory: true))
        if arguments[0] == "--uninstall-home" {
            try runtime.uninstallHome(home); result = 0
        } else {
            let report: WindowsClaudeHookRuntime.Report
            if arguments[0] == "--inspect" { report = runtime.inspect(home: home) }
            else {
                let source = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent().appendingPathComponent("Python", isDirectory: true)
                report = runtime.ensure(home: home, package: source)
            }
            try FileHandle.standardOutput.write(contentsOf: JSONEncoder().encode(report) + Data([10]))
            result = report.state == "failed" ? 1 : 0
        }
    }
} catch {
    // No paths, provider settings, account data or record contents in diagnostics.
    FileHandle.standardError.write(Data("Pacer could not safely update Claude configuration or its owned runtime.\n".utf8))
    result = 1
}
exit(result)
