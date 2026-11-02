#if os(Windows)
import Foundation
import CWindowsSupport

/// An observed writer may point to an editor or terminal. Only its existing
/// window is activated; transcript fields cannot name an executable to run.
struct WindowsProcessHost: Equatable, Sendable {
    let identity: WindowsProcessIdentity
    let provider: AgentProvider?

    static func nearest(to writer: WindowsProcessIdentity,
                        lookup: WindowsProcessOwnership.Lookup = { WindowsProcessOwnership.inspect($0, started: $1) },
                        available: (WindowsProcessIdentity) -> Bool = { WindowsHostWindow.available(pid: $0.pid, started: $0.started) },
                        packageRoots: [AgentProvider: [URL]]? = nil) -> Self? {
        let roots = packageRoots ?? [.claude: WindowsPackageLocations.find(family: "Claude_pzs8sxrjxfjjc"),
                                    .codex: WindowsPackageLocations.find(family: "OpenAI.Codex_2p2nqsd0c76g0")]
        var current = writer, seen = Set<WindowsProcessIdentity>(), desktop: Self?
        for _ in 0..<32 {
            guard seen.insert(current).inserted, let row = lookup(current.pid, current.started), row.identity == current else { return nil }
            let path = WindowsCodexExecutableDiscovery.path(row.executable.standardizedFileURL).lowercased()
            let name = path.split(whereSeparator: { $0 == "\\" || $0 == "/" }).last.map(String.init) ?? ""
            if ["explorer.exe", "shellexperiencehost.exe", "startmenuexperiencehost.exe", "searchhost.exe", "runtimebroker.exe", "applicationframehost.exe"].contains(name) {
                guard let desktop, lookup(writer.pid, writer.started)?.identity == writer,
                      lookup(desktop.identity.pid, desktop.identity.started)?.identity == desktop.identity else { return nil }
                return desktop
            }
            let provider = roots.first { _, paths in paths.contains { root in
                let base = WindowsCodexExecutableDiscovery.path(root.standardizedFileURL).lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "\\/"))
                return path.hasPrefix(base + "\\") || path.hasPrefix(base + "/")
            } }?.key
            let host = Self(identity: current, provider: provider)
            if available(current) {
                guard lookup(writer.pid, writer.started)?.identity == writer,
                      lookup(current.pid, current.started)?.identity == current else { return nil }
                return host
            }
            if provider != nil { desktop = host }
            guard row.parent != 0, let parent = lookup(row.parent, 0), parent.identity.started <= row.identity.started else {
                guard let desktop, lookup(writer.pid, writer.started)?.identity == writer,
                      lookup(desktop.identity.pid, desktop.identity.started)?.identity == desktop.identity else { return nil }
                return desktop
            }
            current = parent.identity
        }
        return nil
    }
}

public enum WindowsHostWindow {
    public static func available(pid: UInt32, started: UInt64) -> Bool { pacer_process_window(pid, started, 0) == 1 }
    public static func activate(pid: UInt32, started: UInt64) -> Bool { pacer_process_window(pid, started, 1) == 1 }
}
#endif
