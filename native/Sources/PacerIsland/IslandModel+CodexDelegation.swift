import AppKit
import Foundation
import PacerCore

/// Collaboration's self-check: Codex's version, its sign-in, its model
/// catalog and what its configuration picks, from the program Pacer found.
/// No model is called.
struct CodexDelegationCheck: Equatable {
    var checking = false
    /// `ok`, `missing` or `unknown`; nil before the first check.
    var login: String?
    var version: String?
    var models: [CodexModelChoice]?
    /// What Codex's configuration picks, which the runner follows by default.
    var defaultModel: String?
    var defaultEffort: String?
    var defaultFast: Bool?
}

struct CodexModelChoice: Equatable, Hashable, Identifiable {
    let slug: String
    let name: String
    var efforts: [String] = []
    var defaultEffort: String?
    var id: String { slug }
}

/// What Settings → Collaboration needs besides the self-check.
struct CodexDelegationWorkbench: Equatable {
    var enabled = false
    var skillInstalled = false
    /// The user-level skill from before Pacer managed it, while it is still there.
    var legacySkill: URL?
    var codexFound = false
}

extension IslandModel {
    func codexDelegationWorkbench() -> CodexDelegationWorkbench {
        let home = claudeHome
        var value = CodexDelegationWorkbench()
        value.enabled = ClaudeCodexDelegation.isOn(home: home)
        value.skillInstalled = FileManager.default.fileExists(atPath: ClaudeCodexDelegation.skillURL(home: home).path)
        value.legacySkill = ClaudeCodexDelegation.hasLegacySkill(home: home) ? ClaudeCodexDelegation.legacySkillURL(home: home) : nil
        value.codexFound = CodexClient.findExecutable(customPath: defaults.string(forKey: "codexExecutable") ?? "") != nil
        return value
    }

    /// Codex's version, sign-in, model list and configured defaults, from the program Pacer found.
    func checkCodexDelegation() {
        guard !codexDelegationCheck.checking else { return }
        guard let executable = CodexClient.findExecutable(customPath: defaults.string(forKey: "codexExecutable") ?? "") else {
            codexDelegationCheck = CodexDelegationCheck(login: "unknown"); return
        }
        codexDelegationCheck.checking = true
        let codexHome = home
        Task { [weak self] in
            let environment = ["CODEX_HOME": codexHome.path]
            let version = await BoundedCommand.output(executable, ["--version"], environment: environment, timeout: 20, limit: 4096)
                .flatMap { $0.status == 0 ? String(decoding: $0.data, as: UTF8.self).split(whereSeparator: \.isWhitespace).last.map(String.init) : nil }
            // `codex login status` exits non-zero when signed out.
            let login = await BoundedCommand.output(executable, ["login", "status"], environment: environment, timeout: 20, limit: 4096)
            let catalog = await BoundedCommand.output(executable, ["debug", "models"], environment: environment, timeout: 60, limit: 1 << 20)
            let models = catalog.flatMap { $0.status == 0 ? Self.codexModels($0.data) : nil }
            let model = Self.configuredValue("model", home: codexHome)
            let effort = Self.configuredValue("model_reasoning_effort", home: codexHome)
                ?? models?.first { $0.slug == model }?.defaultEffort ?? models?.first?.defaultEffort
            let tier = Self.configuredValue("service_tier", home: codexHome)
            guard let self else { return }
            self.codexDelegationCheck = CodexDelegationCheck(checking: false,
                login: version == nil ? "unknown" : login?.status == 0 ? "ok" : "missing",
                version: version, models: models, defaultModel: model ?? models?.first?.slug,
                defaultEffort: effort, defaultFast: tier.map { $0 == "priority" || $0 == "fast" } ?? false)
        }
    }

    /// Writes the plugin's skill and runner again.
    func reinstallCodexDelegationSkill() { retryClaudeLocalSetup() }

    static func codexModels(_ data: Data) -> [CodexModelChoice]? {
        guard let value = try? JSONSerialization.jsonObject(with: data) else { return nil }
        let list = (value as? [[String: Any]]) ?? ((value as? [String: Any])?["models"] as? [[String: Any]]) ?? []
        let models = list.prefix(64).compactMap { model -> CodexModelChoice? in
            guard let slug = model["slug"] as? String, slug.utf8.count <= 80, [nil, "list"].contains(model["visibility"] as? String) else { return nil }
            let efforts = ((model["supported_reasoning_levels"] as? [Any]) ?? []).prefix(12).compactMap { level -> String? in
                let effort = (level as? [String: Any])?["effort"] as? String ?? level as? String
                return effort.flatMap { CodexDelegationPreferences.efforts.contains($0) ? $0 : nil }
            }
            let fallback = (model["default_reasoning_level"] as? String).flatMap { CodexDelegationPreferences.efforts.contains($0) ? $0 : nil }
            return CodexModelChoice(slug: slug, name: ModelDisplay.name(slug, provider: .codex), efforts: efforts, defaultEffort: fallback)
        }
        return models.isEmpty ? nil : models
    }

    /// A top-level `key = "…"` of Codex's config.toml.
    static func configuredValue(_ key: String, home: URL) -> String? {
        guard let text = try? String(contentsOf: home.appendingPathComponent("config.toml"), encoding: .utf8) else { return nil }
        for line in text.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("[") { break }
            guard trimmed.hasPrefix(key), let equals = trimmed.firstIndex(of: "="),
                  trimmed[..<equals].trimmingCharacters(in: .whitespaces) == key else { continue }
            let raw = trimmed[trimmed.index(after: equals)...].trimmingCharacters(in: .whitespaces)
            guard raw.hasPrefix("\""), let end = raw.dropFirst().firstIndex(of: "\"") else { return nil }
            let value = String(raw[raw.index(after: raw.startIndex)..<end])
            return value.isEmpty || value.utf8.count > 80 ? nil : value
        }
        return nil
    }
}

/// Runs a short command and keeps at most `limit` bytes of its output; past
/// `timeout` it is terminated and the answer is nil.
enum BoundedCommand {
    struct Result: Sendable { let status: Int32; let data: Data }
    static func output(_ executable: URL, _ arguments: [String], environment: [String: String] = [:],
                       timeout: TimeInterval, limit: Int) async -> Result? {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                let process = Process(), pipe = Pipe()
                process.executableURL = executable; process.arguments = arguments
                process.environment = ProcessInfo.processInfo.environment.merging(environment) { _, new in new }
                process.standardOutput = pipe; process.standardError = FileHandle.nullDevice
                process.standardInput = FileHandle.nullDevice
                do { try process.run() } catch { continuation.resume(returning: nil); return }
                let deadline = DispatchWorkItem { if process.isRunning { process.terminate() } }
                DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout, execute: deadline)
                var data = Data()
                let handle = pipe.fileHandleForReading
                while true {
                    let chunk = handle.availableData
                    if chunk.isEmpty { break }
                    if data.count < limit { data.append(chunk.prefix(limit - data.count)) }
                }
                process.waitUntilExit()
                deadline.cancel()
                let timedOut = process.terminationReason == .uncaughtSignal
                continuation.resume(returning: timedOut ? nil : Result(status: process.terminationStatus, data: data))
            }
        }
    }
}
