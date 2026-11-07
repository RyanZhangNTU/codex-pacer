import Foundation

public enum DeepSeekProgressSetupStatus: String, Codable, Sendable {
    case settingUp, ready, conflict, failed
}

/// Manages one owned entry in the home-level Harness patch, which both Desktop
/// and the CLI load. The enable file also revokes a server already in memory.
public enum DeepSeekProgressSetup {
    private static let begin = "# BEGIN Codex Pacer DeepSeek progress"
    private static let end = "# END Codex Pacer DeepSeek progress"
    private static let emptySequence = "# Codex Pacer original empty sequence: "
    private static let on = Data("on\n".utf8)
    private static let maximumPatchBytes = 256 * 1024

    public static func apply(home: URL, enabled: Bool, storage: any ClaudeHookStorage) -> DeepSeekProgressSetupStatus? {
        let pacer = home.appendingPathComponent("pacer", isDirectory: true)
        let directory = pacer.appendingPathComponent("deepseek-progress", isDirectory: true)
        let flag = directory.appendingPathComponent("enabled")
        let script = directory.appendingPathComponent("report-progress.mjs")
        let patch = home.appendingPathComponent("cordis.patch.yml")
        guard enabled || storage.exists(flag) || storage.exists(script) else { return nil }
        do {
            for path in [home, pacer, directory, flag, script, patch] { try storage.validate(path) }
            guard storage.isDirectory(home), storage.isDirectory(home.appendingPathComponent("profiles")) else { return enabled ? .failed : nil }
            if storage.exists(flag) {
                guard try storage.read(flag) == on else { return .conflict }
                if !enabled { try storage.remove(flag) }
            }
            let original = try storage.exists(patch) ? storage.read(patch) : nil
            guard (original?.count ?? 0) <= maximumPatchBytes,
                  let text = String(data: original ?? Data(), encoding: .utf8) else {
                if storage.exists(flag) { try storage.remove(flag) }
                return .conflict
            }
            let block = try patchBlock(script: script)
            guard let updated = update(text, block: block, enabled: enabled) else {
                if storage.exists(flag) { try storage.remove(flag) }
                return .conflict
            }
            if enabled {
                guard let resource = Bundle.module.url(forResource: "deepseek-progress", withExtension: "mjs") else { return .failed }
                let program = try Data(contentsOf: resource)
                if !storage.isDirectory(directory) { try storage.createDirectory(directory, permissions: 0o700) }
                if storage.exists(script) {
                    guard try storage.read(script) == program else {
                        if storage.exists(flag) { try storage.remove(flag) }
                        return .conflict
                    }
                } else {
                    try storage.replace(script, with: program, permissions: 0o600)
                }
                if !storage.exists(flag) { try storage.replace(flag, with: on, permissions: 0o600) }
            }
            if updated != text {
                let current = try storage.exists(patch) ? storage.read(patch) : nil
                guard current == original else {
                    if storage.exists(flag) { try storage.remove(flag) }
                    return .conflict
                }
                if updated.isEmpty { try storage.remove(patch) }
                else { try storage.replace(patch, with: Data(updated.utf8), permissions: 0o600) }
            }
            return enabled ? .ready : nil
        } catch {
            if storage.exists(flag), (try? storage.read(flag)) == on { try? storage.remove(flag) }
            return .failed
        }
    }

    private static func patchBlock(script: URL) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .withoutEscapingSlashes
        let arguments = String(decoding: try encoder.encode([script.path]), as: UTF8.self)
        return "\n" + """
        \(begin)
        - insert:
            - id: pacer-deepseek-progress
              name: '@deepseek-ai/dsh-mcp-client'
              config:
                serverName: \(CodexProgressEvidence.server)
                transport: stdio
                command: !!js process.execPath
                args: \(arguments)
                env:
                  ELECTRON_RUN_AS_NODE: '1'
        \(end)
        """ + "\n"
    }

    private static func update(_ text: String, block: String, enabled: Bool) -> String? {
        if let range = text.range(of: block) {
            var rest = text
            rest.removeSubrange(range)
            guard !rest.contains(begin), !rest.contains(end) else { return nil }
            if enabled { return text }
            if rest.hasPrefix(emptySequence), let newline = rest.firstIndex(of: "\n") {
                let suffix = rest[rest.index(after: newline)...]
                let encoded = rest[rest.index(rest.startIndex, offsetBy: emptySequence.count)..<newline]
                if suffix.isEmpty, let data = Data(base64Encoded: String(encoded)),
                   let original = String(data: data, encoding: .utf8), original.trimmingCharacters(in: .whitespacesAndNewlines) == "[]" {
                    return original
                }
                return String(suffix)
            }
            return rest
        }
        guard !text.contains(begin), !text.contains(end) else { return nil }
        guard enabled else { return text }
        guard !text.contains("pacer-deepseek-progress"), !text.contains(CodexProgressEvidence.server) else { return nil }
        if text.trimmingCharacters(in: .whitespacesAndNewlines) == "[]" {
            return emptySequence + Data(text.utf8).base64EncodedString() + "\n" + block
        }
        // Appending a new item preserves a block-style sequence byte for byte.
        // Leave other YAML shapes to the profile owner.
        let items = text.split(whereSeparator: \.isNewline).filter {
            let line = $0.trimmingCharacters(in: .whitespaces)
            return !line.isEmpty && !line.hasPrefix("#")
        }
        guard !items.contains(where: { $0.hasPrefix("---") || $0.hasPrefix("...") || $0.hasPrefix("%") }),
              items.first.map({ $0 == "-" || $0.hasPrefix("- ") }) ?? true else { return nil }
        return text + block
    }
}
