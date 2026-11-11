import Darwin
import Foundation
import PacerCore
import Security

/// A local executor is a child of the Codex Desktop instance serving our IPC
/// socket. Neither a local-looking cwd nor an arbitrary codex CLI proves that.
struct MacDurableExecutor: Equatable, Sendable {
    let pid: pid_t
    let desktopPID: pid_t
    let startedAt: Date
    let environmentID: String
    let application: URL

    /// The bundle's `bin/codex` wrapper is an unsigned script, so start the
    /// signed binary itself, as the local Codex collector does.
    static func verifiedCLI(in application: URL) -> URL? {
        let root = application.resolvingSymlinksInPath()
        guard let cli = MacExecutablePlatform.appExecutables.lazy.map(root.appendingPathComponent)
                .first(where: { FileManager.default.isExecutableFile(atPath: $0.path) }),
              cli.resolvingSymlinksInPath().path.hasPrefix(root.path + "/"), isSignedCodex(cli) else { return nil }
        return cli
    }

    /// Only the signer is checked. Checking the whole bundle hashed about
    /// 1.6 GB per connection; macOS checks each page against this signature
    /// as the CLI runs and stops it if one does not match.
    static func isSignedCodex(_ executable: URL) -> Bool {
        var code: SecStaticCode?, requirement: SecRequirement?
        let expression = #"anchor apple generic and certificate leaf[subject.OU] = "2DC432GLL2""#
        guard SecStaticCodeCreateWithPath(executable as CFURL, [], &code) == errSecSuccess, let code,
              SecRequirementCreateWithString(expression as CFString, [], &requirement) == errSecSuccess, let requirement else { return false }
        return SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSBasicValidateOnly), requirement) == errSecSuccess
    }

    static func find(peer: pid_t) -> Self? {
        guard let desktop = executable(peer) else { return nil }
        let app = desktop.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        guard let bundle = Bundle(url: app), bundle.bundleIdentifier == "com.openai.codex",
              bundle.executableURL?.resolvingSymlinksInPath() == desktop else { return nil }
        let bundled = app.appendingPathComponent("Contents/Resources", isDirectory: true).path + "/"
        guard let children = children(of: peer) else { return nil }
        let matches = children.compactMap { pid -> Self? in
            guard let path = executable(pid), path.path.hasPrefix(bundled), path.lastPathComponent == "codex",
                  let argv = arguments(pid), let command = argv.firstIndex(of: "exec-server"),
                  argv.dropFirst(command + 1).contains("--remote"),
                  let index = argv[command...].firstIndex(of: "--environment-id"), index + 1 < argv.count,
                  let started = startDate(pid, parent: peer) else { return nil }
            let id = argv[index + 1]
            guard id.range(of: #"^[A-Za-z0-9_-]{1,128}\z"#, options: .regularExpression) != nil,
                  ProcessOwnership.parentProcess(pid) == peer else { return nil }
            return Self(pid: pid, desktopPID: peer, startedAt: started, environmentID: id, application: app)
        }
        return matches.count == 1 ? matches[0] : nil
    }

    static func children(of pid: pid_t) -> [pid_t]? {
        guard pid > 1 else { return nil }
        var pids = [pid_t](repeating: 0, count: 512)
        errno = 0
        let size = pids.withUnsafeMutableBytes {
            proc_listpids(UInt32(PROC_PPID_ONLY), UInt32(pid), $0.baseAddress, Int32($0.count))
        }
        guard size >= 0, size != 0 || errno == 0, Int(size) < pids.count * MemoryLayout<pid_t>.stride else { return nil }
        return pids.prefix(Int(size) / MemoryLayout<pid_t>.stride).filter { $0 > 1 }
    }

    private static func startDate(_ pid: pid_t, parent: pid_t) -> Date? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size,
              info.pbi_uid == getuid(), info.pbi_ppid == UInt32(parent) else { return nil }
        return Date(timeIntervalSince1970: Double(info.pbi_start_tvsec) + Double(info.pbi_start_tvusec) / 1_000_000)
    }

    private static func executable(_ pid: pid_t) -> URL? {
        guard pid > 1 else { return nil }
        var bytes = [CChar](repeating: 0, count: 4096)
        guard proc_pidpath(pid, &bytes, UInt32(bytes.count)) > 0 else { return nil }
        return URL(fileURLWithPath: String(cString: bytes)).resolvingSymlinksInPath()
    }

    private static func arguments(_ pid: pid_t) -> [String]? {
        var mib = [CTL_KERN, KERN_PROCARGS2, pid], size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 4, size <= 256 * 1024 else { return nil }
        var bytes = [UInt8](repeating: 0, count: size)
        let result = bytes.withUnsafeMutableBytes { sysctl(&mib, 3, $0.baseAddress, &size, nil, 0) }
        guard result == 0, size > 4, size <= bytes.count else { return nil }
        let count = Int(bytes.withUnsafeBytes { $0.loadUnaligned(as: Int32.self) })
        guard (1...128).contains(count), let end = bytes[4..<size].firstIndex(of: 0) else { return nil }
        var cursor = end + 1, argv: [String] = []
        while cursor < size && bytes[cursor] == 0 { cursor += 1 }
        for _ in 0..<count {
            guard cursor < size, let end = bytes[cursor..<size].firstIndex(of: 0),
                  end - cursor <= 4096, let arg = String(bytes: bytes[cursor..<end], encoding: .utf8) else { return nil }
            argv.append(arg); cursor = end + 1
        }
        return argv
    }
}
