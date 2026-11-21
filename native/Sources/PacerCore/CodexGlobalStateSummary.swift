import Foundation

/// Codex rewrites its global state (often over a megabyte) several times a
/// minute. SSH discovery scans its fields once per change.
enum CodexGlobalStateSummary {
    struct Value: Sendable {
        let sshTargets: [RemoteActivityTarget]?
    }
    private static let cache = FileSignatureCache<Value>()

    static func read(home: URL) -> Value {
        let file = home.appendingPathComponent(".codex-global-state.json")
        return cache.value(for: file) { parse(file) }
    }
    private static func parse(_ file: URL) -> Value {
        guard let data = try? Data(contentsOf: file), data.count < 8 * 1024 * 1024,
              let fields = try? JSONFieldView.document(data).fields(
                RemoteActivityTarget.globalStateFields, allowedPrefixes: RemoteActivityTarget.scopedFieldPrefixes) else {
            return Value(sshTargets: nil)
        }
        return Value(sshTargets: RemoteActivityTarget.configuration(fields))
    }
}
