import Foundation

public enum DeepSeekProgressSetupStatus: String, Codable, Sendable {
    case settingUp, ready, conflict, failed
}

/// Manages one owned entry in the home-level Harness patch, which every
/// profile, Desktop and the CLI load. The enable file also revokes a server
/// already in memory. The entry's begin line carries a checksum of its body and
/// the reporter starts with an ownership line, so a later Pacer replaces its own
/// older files but never takes over an entry or file someone else edited.
public enum DeepSeekProgressSetup {
    public struct Target: Equatable, Sendable {
        public let home: URL
        public let enabled: Bool
        public init(home: URL, enabled: Bool) { self.home = home; self.enabled = enabled }
    }

    private static let begin = "# BEGIN Codex Pacer DeepSeek progress"
    private static let end = "# END Codex Pacer DeepSeek progress"
    /// Saves an empty file or empty sequence the entry replaced, so disabling restores it.
    private static let original = "# Codex Pacer original patch: "
    private static let on = Data("on\n".utf8)
    private static let maximumPatchBytes = 256 * 1024
    private static let newline = UInt8(ascii: "\n")
    /// The first line of every reporter Pacer ships.
    static let reporterOwner = Data("// Codex Pacer DeepSeek progress reporter.".utf8)

    static func folder(_ home: URL) -> URL {
        home.appendingPathComponent("pacer", isDirectory: true).appendingPathComponent("deepseek-progress", isDirectory: true)
    }

    /// Setup keeps this folder, so later cleanup knows which homes to check.
    public static func wasConfigured(in home: URL) -> Bool { FileManager.default.fileExists(atPath: folder(home).path) }

    /// Revokes a home the switch moved away from, then applies the new target.
    public static func sync(from previous: Target?, to target: Target, storage: any ClaudeHookStorage) -> DeepSeekProgressSetupStatus? {
        if let previous, previous.home != target.home { _ = apply(home: previous.home, enabled: false, storage: storage) }
        return apply(home: target.home, enabled: target.enabled, storage: storage)
    }

    /// With `checkOnly`, reports whether the change would succeed without writing.
    public static func apply(home: URL, enabled: Bool, storage: any ClaudeHookStorage, checkOnly: Bool = false) -> DeepSeekProgressSetupStatus? {
        let pacer = home.appendingPathComponent("pacer", isDirectory: true), directory = folder(home)
        let flag = directory.appendingPathComponent("enabled")
        let script = directory.appendingPathComponent("report-progress.mjs")
        let patch = home.appendingPathComponent("cordis.patch.yml")
        guard enabled || storage.exists(directory) else { return nil }
        func refuse(_ status: DeepSeekProgressSetupStatus) throws -> DeepSeekProgressSetupStatus {
            if !checkOnly, storage.exists(flag) { try storage.remove(flag) }
            return status
        }
        do {
            for path in [home, pacer, directory, flag, script, patch] { try storage.validate(path) }
            guard storage.isDirectory(home) else { return enabled ? .failed : nil }
            if enabled, !storage.isDirectory(home.appendingPathComponent("profiles")) { return .failed }
            if storage.exists(flag) {
                guard try storage.read(flag) == on else { return .conflict }
                if !enabled, !checkOnly { try storage.remove(flag) }
            }
            let source = try storage.exists(patch) ? storage.read(patch) : nil
            guard (source?.count ?? 0) <= maximumPatchBytes else { return try refuse(.conflict) }
            let edit = update(source, entry: try entry(script: script), enabled: enabled)
            if edit == .conflict { return try refuse(.conflict) }
            let installed = try storage.exists(script) ? storage.read(script) : nil
            if checkOnly { return nil }
            if enabled {
                guard let resource = Bundle.module.url(forResource: "deepseek-progress", withExtension: "mjs") else { return try refuse(.failed) }
                let program = try Data(contentsOf: resource)
                if installed != program {
                    // A reporter from an earlier Pacer is replaced; any other file is left alone.
                    guard installed.map(ownsReporter) ?? true else { return try refuse(.conflict) }
                    if !storage.isDirectory(directory) { try storage.createDirectory(directory, permissions: 0o700) }
                    try storage.replace(script, with: program, permissions: 0o600)
                }
                if !storage.exists(flag) { try storage.replace(flag, with: on, permissions: 0o600) }
            }
            if edit != .keep {
                let current = try storage.exists(patch) ? storage.read(patch) : nil
                guard current == source else { return try refuse(.conflict) }
                if case .write(let data) = edit { try storage.replace(patch, with: data, permissions: 0o600) }
                else { try storage.remove(patch) }
            }
            // The entry is gone, so nothing launches the reporter any more.
            if !enabled, let installed, ownsReporter(installed) { try storage.remove(script) }
            return enabled ? .ready : nil
        } catch {
            if !checkOnly, storage.exists(flag), (try? storage.read(flag)) == on { try? storage.remove(flag) }
            return .failed
        }
    }

    static func ownsReporter(_ data: Data) -> Bool { data.starts(with: reporterOwner) }

    /// FNV-1a over the entry body: it detects an edit, not an adversary.
    static func checksum<Bytes: Sequence>(_ bytes: Bytes) -> String where Bytes.Element == UInt8 {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in bytes { hash = (hash ^ UInt64(byte)) &* 0x0000_0100_0000_01b3 }
        let digits = String(hash, radix: 16)
        return String(repeating: "0", count: 16 - digits.count) + digits
    }

    /// The entry without its framing newlines.
    static func core(script: URL) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .withoutEscapingSlashes
        let arguments = String(decoding: try encoder.encode([script.path]), as: UTF8.self)
        let body = """
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
        """ + "\n"
        return Data((begin + " " + checksum(body.utf8) + "\n" + body + end).utf8)
    }

    /// Framed by newlines, so appending never joins an existing line.
    private static func entry(script: URL) throws -> Data { Data([newline]) + (try core(script: script)) + Data([newline]) }

    private enum Edit: Equatable { case keep, write(Data), remove, conflict }
    private enum Found { case none, foreign, owned(core: Range<Int>, framed: Range<Int>) }

    /// An owned entry has one begin and one end line, in order, and its body
    /// still matches the begin line's checksum. Anything else is someone's edit.
    private static func find(_ data: Data) -> Found {
        let head = Data(begin.utf8), tail = Data(end.utf8)
        let heads = occurrences(head, in: data), tails = occurrences(tail, in: data)
        if heads == 0 && tails == 0 { return .none }
        guard heads == 1, tails == 1, let start = data.range(of: head), let stop = data.range(of: tail),
              start.lowerBound == data.startIndex || data[start.lowerBound - 1] == newline,
              let lineEnd = data[start.upperBound...].firstIndex(of: newline), lineEnd < stop.lowerBound,
              data[stop.lowerBound - 1] == newline,
              stop.upperBound == data.endIndex || data[stop.upperBound] == newline,
              data[start.upperBound..<lineEnd] == Data((" " + checksum(data[(lineEnd + 1)..<stop.lowerBound])).utf8) else { return .foreign }
        let lower = start.lowerBound > data.startIndex ? start.lowerBound - 1 : start.lowerBound
        let upper = stop.upperBound < data.endIndex ? stop.upperBound + 1 : stop.upperBound
        return .owned(core: start.lowerBound..<stop.upperBound, framed: lower..<upper)
    }

    private static func occurrences(_ needle: Data, in data: Data) -> Int {
        var count = 0, cursor = data.startIndex
        while let found = data.range(of: needle, in: cursor..<data.endIndex) { count += 1; cursor = found.upperBound }
        return count
    }

    private static func update(_ source: Data?, entry: Data, enabled: Bool) -> Edit {
        let data = source ?? Data()
        switch find(data) {
        case .foreign:
            return .conflict
        case let .owned(core, framed):
            if enabled {
                // An entry from an earlier Pacer is replaced in place.
                let current = entry.dropFirst().dropLast()
                return data[core] == current ? .keep : .write(data[data.startIndex..<core.lowerBound] + current + data[core.upperBound...])
            }
            var before = Data(data[data.startIndex..<framed.lowerBound])
            let after = Data(data[framed.upperBound...])
            if !before.isEmpty, !after.isEmpty, before.last != newline { before.append(newline) }
            let rest = before + after
            let marker = Data(original.utf8)
            if rest.starts(with: marker), let lineEnd = rest.firstIndex(of: newline),
               let saved = Data(base64Encoded: Data(rest[(rest.startIndex + marker.count)..<lineEnd])) {
                let suffix = rest[(lineEnd + 1)...]
                return .write(suffix.isEmpty ? saved : Data(suffix))
            }
            return rest.isEmpty ? .remove : .write(rest)
        case .none:
            guard enabled else { return .keep }
            guard data.range(of: Data("pacer-deepseek-progress".utf8)) == nil,
                  data.range(of: Data(CodexProgressEvidence.server.utf8)) == nil,
                  let text = String(data: data, encoding: .utf8) else { return .conflict }
            let bare = text.hasPrefix("\u{FEFF}") ? String(text.dropFirst()) : text
            let trimmed = bare.trimmingCharacters(in: .whitespacesAndNewlines)
            if source != nil, trimmed.isEmpty || trimmed == "[]" {
                return .write(Data((original + data.base64EncodedString() + "\n").utf8) + entry)
            }
            // Appending a new item preserves a block-style sequence byte for byte.
            // Leave other YAML shapes to the profile owner.
            let items = bare.split(whereSeparator: \.isNewline).filter {
                let line = $0.trimmingCharacters(in: .whitespaces)
                return !line.isEmpty && !line.hasPrefix("#")
            }
            guard !items.contains(where: { $0.hasPrefix("---") || $0.hasPrefix("...") || $0.hasPrefix("%") }),
                  items.first.map({ $0 == "-" || $0.hasPrefix("- ") }) ?? true else { return .conflict }
            return .write(data + entry)
        }
    }
}
