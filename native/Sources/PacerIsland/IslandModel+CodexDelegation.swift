import AppKit
import Foundation
import PacerCore

/// Collaboration's self-check: Codex's version, its sign-in and its model
/// catalog, from the program Pacer found. No model is called.
struct CodexDelegationCheck: Equatable {
    var checking = false
    /// `ok`, `missing` or `unknown`; nil before the first check.
    var login: String?
    var version: String?
    var models: [CodexModelChoice]?
    /// The model Codex's configuration names, which the runner follows by default.
    var defaultModel: String?
}

struct CodexModelChoice: Equatable, Hashable, Identifiable {
    let slug: String
    let name: String
    var id: String { slug }
}

struct RunningDelegationKey: Equatable { let at: Date; let activities: Int; let links: Int }

/// One run going now, for Collaboration's Running card.
struct RunningDelegation: Identifiable {
    let parentTitle: String
    let parent: SessionActivity
    let row: ActivityTaskRowPresentation
    var id: String { row.activity.id }
}

/// What Settings → Collaboration shows besides the self-check and the runs
/// going now, as on Windows (`EngineCodexDelegationStatus`). No task content
/// beyond the labels and projects the runner keeps.
struct CodexDelegationWorkbench: Equatable {
    var enabled = false
    var skillInstalled = false
    /// The user-level skill from before Pacer managed it, while it is still there.
    var legacySkill: URL?
    var codexFound = false
    /// Any run was ever filed; the get-started steps and try-it card follow this.
    var firstRunSeen = false
    var runsTotal = 0
    var stats7: CodexDelegationStatistics?
    var stats30: CodexDelegationStatistics?
    /// Codex threads another Codex process kept from being deleted, still queued.
    var pending = 0
    var runsFolder: URL?
    /// Codex's quota windows now, such as "5h 63% · 7d 71%".
    var quotaText: String?
    var limit = 3
}

extension IslandModel {
    /// The runner's stats file, read at most every five seconds.
    func codexDelegationStatisticsRows(at date: Date) -> [CodexDelegationStatistics.Row] {
        if let cached = codexDelegationStatsCache, abs(date.timeIntervalSince(cached.at)) < 5 { return cached.rows }
        let rows = CodexDelegationStatistics.rows(home: claudeHome)
        codexDelegationStatsCache = (date, rows); return rows
    }

    func codexDelegationWorkbench(at date: Date = Date()) -> CodexDelegationWorkbench {
        let home = claudeHome, rows = codexDelegationStatisticsRows(at: date)
        let ran = rows.filter { $0.status != "refused" }
        var value = CodexDelegationWorkbench()
        value.enabled = ClaudeCodexDelegation.isOn(home: home)
        value.skillInstalled = FileManager.default.fileExists(atPath: ClaudeCodexDelegation.skillURL(home: home).path)
        value.legacySkill = ClaudeCodexDelegation.hasLegacySkill(home: home) ? ClaudeCodexDelegation.legacySkillURL(home: home) : nil
        value.codexFound = CodexClient.findExecutable(customPath: defaults.string(forKey: "codexExecutable") ?? "") != nil
        value.firstRunSeen = !rows.isEmpty || !codexDelegationRuns.isEmpty
        value.runsTotal = ran.count
        value.stats7 = CodexDelegationStatistics(rows: rows, days: 7, hideProjects: hideProjects, at: date)
        value.stats30 = CodexDelegationStatistics(rows: rows, days: 30, hideProjects: hideProjects, at: date)
        value.pending = (try? String(contentsOf: ClaudeCodexDelegation.root(home: home).appendingPathComponent("pending-deletes.txt"), encoding: .utf8))
            .map { Set($0.split(whereSeparator: \.isWhitespace)).count } ?? 0
        value.runsFolder = ClaudeCodexDelegation.root(home: home)
        let windows = (providerQuota(.codex)?.windows ?? []).filter { $0.remainingPercent != nil }
            .sorted { ($0.durationMinutes ?? 0) < ($1.durationMinutes ?? 0) }
        value.quotaText = windows.isEmpty ? nil
            : windows.map { $0.label + " " + String(Int(($0.remainingPercent ?? 0).rounded())) + "%" }.joined(separator: " · ")
        value.limit = CodexDelegationPreferences(defaults: defaults).maxConcurrent
        return value
    }

    /// Runs going now, across Claude tasks, whatever the island's display
    /// choice. They change every second, so the Running card reads them apart
    /// from the statistics; one pass serves every reader of the same tick.
    var runningDelegations: [RunningDelegation] {
        let key = RunningDelegationKey(at: now, activities: activities.count, links: activityState.codexDelegations.count)
        if let cached = runningDelegationsCache, cached.key == key { return cached.value }
        var options = taskPresentationOptions(for: activities); options.showsDelegationRows = true
        let value = activityState.presentation(at: now, options: options).rows.flatMap { row in
            row.delegations.filter { $0.phase == .running }.map { RunningDelegation(parentTitle: row.title, parent: row.activity, row: $0) }
        }
        runningDelegationsCache = (key, value)
        return value
    }

    /// Codex's version, sign-in and model list, from the program Pacer found.
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
            let configured = Self.configuredModel(home: codexHome)
            guard let self else { return }
            self.codexDelegationCheck = CodexDelegationCheck(checking: false,
                login: version == nil ? "unknown" : login?.status == 0 ? "ok" : "missing",
                version: version, models: models, defaultModel: configured)
        }
    }

    func clearCodexDelegationHistory() {
        CodexDelegationStatistics.clearHistory(home: claudeHome)
        codexDelegationStatsCache = nil
        objectWillChange.send()
    }
    /// Writes the plugin's skill and runner again.
    func reinstallCodexDelegationSkill() { retryClaudeLocalSetup() }
    func openCodexDelegationRuns() {
        let folder = ClaudeCodexDelegation.root(home: claudeHome)
        if FileManager.default.fileExists(atPath: folder.path) { NSWorkspace.shared.open(folder) }
    }

    /// The one-time hint about run lines is shown until the user closes it.
    var showsDelegationCoach: Bool { !CodexDelegationPreferences(defaults: defaults).coachShown }
    func dismissDelegationCoach() {
        defaults.set(true, forKey: CodexDelegationPreferences.coachShownKey)
        objectWillChange.send()
        onLayoutChange?()
    }

    static func codexModels(_ data: Data) -> [CodexModelChoice]? {
        guard let value = try? JSONSerialization.jsonObject(with: data) else { return nil }
        let list = (value as? [[String: Any]]) ?? ((value as? [String: Any])?["models"] as? [[String: Any]]) ?? []
        let models = list.prefix(64).compactMap { model -> CodexModelChoice? in
            guard let slug = model["slug"] as? String, slug.utf8.count <= 80, [nil, "list"].contains(model["visibility"] as? String) else { return nil }
            return CodexModelChoice(slug: slug, name: ModelDisplay.name(slug, provider: .codex))
        }
        return models.isEmpty ? nil : models
    }

    /// The top-level `model = "…"` of Codex's config.toml.
    static func configuredModel(home: URL) -> String? {
        guard let text = try? String(contentsOf: home.appendingPathComponent("config.toml"), encoding: .utf8) else { return nil }
        for line in text.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("[") { break }
            guard trimmed.hasPrefix("model"), let equals = trimmed.firstIndex(of: "="),
                  trimmed[..<equals].trimmingCharacters(in: .whitespaces) == "model" else { continue }
            let raw = trimmed[trimmed.index(after: equals)...].trimmingCharacters(in: .whitespaces)
            guard raw.hasPrefix("\""), let end = raw.dropFirst().firstIndex(of: "\"") else { return nil }
            let slug = String(raw[raw.index(after: raw.startIndex)..<end])
            return slug.isEmpty || slug.utf8.count > 80 ? nil : slug
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
