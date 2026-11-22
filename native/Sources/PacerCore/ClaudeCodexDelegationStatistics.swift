import Foundation

/// Settings → Collaboration's statistics, from the runner's `stats.jsonl`:
/// one line per finished or refused run with times, counts, model choices,
/// Claude's short label and the project folder's name. Never a brief or
/// Codex's output. Both hosts draw the same worded presentation.
public struct CodexDelegationStatistics: Equatable, Sendable, Codable {
    public struct Row: Equatable, Sendable {
        public let at: Date
        public let seconds: Double
        public let status: String
        public let mode: String
        public let model: String?
        public let effort: String?
        public let fast: Bool?
        public let reason: String?
        public let label: String?
        public let project: String?
        public let input: Int
        public let cached: Int
        public let output: Int
    }

    public static func rows(home: URL) -> [Row] {
        guard let data = try? Data(contentsOf: ClaudeCodexDelegation.statsURL(home: home)), data.count < 8 << 20,
              let text = String(data: data, encoding: .utf8) else { return [] }
        return text.split(whereSeparator: \.isNewline).compactMap { line in
            guard let value = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  let at = value["at"] as? Double, at.isFinite, at > 0 else { return nil }
            func text(_ key: String, _ limit: Int) -> String? {
                (value[key] as? String).map { String($0.split(whereSeparator: \.isWhitespace).joined(separator: " ").prefix(limit)) }.flatMap { $0.isEmpty ? nil : $0 }
            }
            func count(_ key: String) -> Int { max(0, value[key] as? Int ?? 0) }
            return Row(at: Date(timeIntervalSince1970: at), seconds: max(0, value["seconds"] as? Double ?? 0),
                       status: text("status", 16) ?? "ok", mode: text("mode", 16) ?? "task", model: text("model", 80),
                       effort: text("effort", 16), fast: value["fast"] as? Bool, reason: text("reason", 24),
                       label: text("label", 60), project: text("project", 80),
                       input: count("input"), cached: count("cached"), output: count("output"))
        }
    }

    /// Clears the recent-runs list: labels and project names leave the file,
    /// the numbers stay.
    @discardableResult public static func clearHistory(home: URL) -> Bool {
        let url = ClaudeCodexDelegation.statsURL(home: home)
        guard let data = try? Data(contentsOf: url), let text = String(data: data, encoding: .utf8) else { return true }
        let lines = text.split(whereSeparator: \.isNewline).compactMap { line -> String? in
            guard var value = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else { return nil }
            value.removeValue(forKey: "label"); value.removeValue(forKey: "project")
            return (try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])).map { String(decoding: $0, as: UTF8.self) }
        }
        return (try? Data((lines.joined(separator: "\n") + (lines.isEmpty ? "" : "\n")).utf8).write(to: url, options: .atomic)) != nil
    }

    public struct Kpi: Equatable, Sendable, Codable {
        public let title: String
        public let value: String
        public let note: String?
        public let tone: String?
    }
    public struct Day: Equatable, Sendable, Codable {
        public let label: String
        public let ok: Int
        public let stopped: Int
        public let failed: Int
    }
    public struct Share: Equatable, Sendable, Codable {
        public let name: String
        public let count: Int
        public let fraction: Double
    }
    public struct Breakdown: Equatable, Sendable, Codable {
        public let title: String
        public let shares: [Share]
    }
    public struct Recent: Equatable, Sendable, Codable {
        public let time: String
        public let title: String
        public let project: String?
        public let detail: String
        public let duration: String
        public let result: String
        /// `ok`, `stopped` or `failed`.
        public let tone: String
    }
    public let days: Int
    public let runs: Int
    public let kpis: [Kpi]
    public let chart: [Day]
    /// The tallest day in the chart, for its scale.
    public let chartMax: Int
    public let breakdowns: [Breakdown]
    public let recent: [Recent]
    public let summary: String

    /// The last `days` calendar days, today included, against the `days` before.
    public init(rows: [Row], days: Int, hideProjects: Bool = false, at now: Date, calendar: Calendar = .current) {
        self.days = days
        let today = calendar.startOfDay(for: now)
        let start = calendar.date(byAdding: .day, value: -(days - 1), to: today) ?? today
        let previousStart = calendar.date(byAdding: .day, value: -days, to: start) ?? start
        let current = rows.filter { $0.at >= start && $0.at <= now }
        let previous = rows.filter { $0.at >= previousStart && $0.at < start && $0.status != "refused" }
        let ran = current.filter { $0.status != "refused" }
        let ok = ran.filter { $0.status == "ok" }.count, stopped = ran.filter { $0.status == "stopped" }.count
        let failed = ran.count - ok - stopped
        runs = ran.count
        let seconds = ran.reduce(0) { $0 + $1.seconds }, longest = ran.map(\.seconds).max() ?? 0
        let input = ran.reduce(0) { $0 + $1.input }, cached = ran.reduce(0) { $0 + $1.cached }, output = ran.reduce(0) { $0 + $1.output }
        func duration(_ value: Double) -> String { value < 60 ? L10n.text("collaboration.stats.seconds", Int(value.rounded())) : CompactDuration.text(value) }
        let delta = ran.count - previous.count
        kpis = [
            Kpi(title: L10n.text("collaboration.stats.runs"), value: String(ran.count),
                note: previous.isEmpty && ran.isEmpty ? nil : L10n.text(delta >= 0 ? "collaboration.stats.more" : "collaboration.stats.fewer", abs(delta)),
                tone: delta > 0 ? "good" : nil),
            Kpi(title: L10n.text("collaboration.stats.success"), value: ran.isEmpty ? "—" : String(Int((Double(ok) / Double(ran.count) * 100).rounded())) + "%",
                note: stopped + failed == 0 ? nil : L10n.text("collaboration.stats.stopped_failed", stopped, failed), tone: failed > 0 ? "warn" : nil),
            Kpi(title: L10n.text("collaboration.stats.time"), value: ran.isEmpty ? "—" : duration(seconds),
                note: ran.isEmpty ? nil : L10n.text("collaboration.stats.average") + " " + duration(seconds / Double(ran.count))
                    + " · " + L10n.text("collaboration.stats.longest") + " " + duration(longest), tone: nil),
            Kpi(title: L10n.text("collaboration.stats.tokens"), value: ClaudeCodexDelegation.compactCount(input + output),
                note: input == 0 ? nil : L10n.text("delegation.detail.cached", Int((Double(cached) / Double(input) * 100).rounded())), tone: nil)
        ]
        var chart: [Day] = []
        for offset in 0..<days {
            guard let dayStart = calendar.date(byAdding: .day, value: offset, to: start),
                  let next = calendar.date(byAdding: .day, value: 1, to: dayStart) else { continue }
            let rows = ran.filter { $0.at >= dayStart && $0.at < next }
            let good = rows.filter { $0.status == "ok" }.count, halted = rows.filter { $0.status == "stopped" }.count
            chart.append(Day(label: L10n.format(dayStart, Date.FormatStyle().month(.defaultDigits).day(), calendar: calendar),
                             ok: good, stopped: halted, failed: rows.count - good - halted))
        }
        self.chart = chart
        chartMax = max(1, chart.map { $0.ok + $0.stopped + $0.failed }.max() ?? 1)
        func shares(_ names: [String], limit: Int = 3) -> [Share] {
            let counts = Dictionary(grouping: names, by: { $0 }).mapValues(\.count).sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }
            let total = max(1, names.count)
            var result = counts.prefix(limit).map { Share(name: $0.key, count: $0.value, fraction: Double($0.value) / Double(total)) }
            let rest = counts.dropFirst(limit).reduce(0) { $0 + $1.value }
            if rest > 0 { result.append(Share(name: L10n.text("collaboration.stats.others", counts.count - limit), count: rest, fraction: Double(rest) / Double(total))) }
            return result
        }
        var breakdowns = [
            Breakdown(title: L10n.text("collaboration.stats.by_mode"),
                      shares: shares(ran.map { L10n.text("delegation.mode." + (["task", "review", "resume"].contains($0.mode) ? $0.mode : "task")) })),
            Breakdown(title: L10n.text("collaboration.stats.by_model"),
                      shares: shares(ran.map { $0.model.map { ModelDisplay.name($0, provider: .codex) } ?? L10n.text("collaboration.stats.unknown_model") }))
        ]
        if !hideProjects {
            breakdowns.append(Breakdown(title: L10n.text("collaboration.stats.by_project"),
                                        shares: shares(ran.map { $0.project ?? L10n.text("collaboration.stats.unknown_project") })))
        }
        let problems = current.filter { !["ok"].contains($0.status) && $0.reason != nil && $0.reason != "stopped" }
        if !problems.isEmpty {
            breakdowns.append(Breakdown(title: L10n.text("collaboration.stats.by_reason"),
                                        shares: shares(problems.map { L10n.text("delegation.reason." + Self.reasonKey($0.reason)) })))
        }
        self.breakdowns = breakdowns
        recent = rows.sorted { $0.at > $1.at }.prefix(50).map { row in
            let sameDay = calendar.isDate(row.at, inSameDayAs: now)
            let time = sameDay ? L10n.format(row.at, Date.FormatStyle().hour(.twoDigits(amPM: .omitted)).minute(.twoDigits), calendar: calendar)
                : L10n.format(row.at, Date.FormatStyle().month(.defaultDigits).day(), calendar: calendar)
            let mode = L10n.text("delegation.mode." + (["task", "review", "resume"].contains(row.mode) ? row.mode : "task"))
            let model = row.model.map { ModelDisplay.name($0, provider: .codex) }
            let effort = row.effort.flatMap { ModelDisplay.effortLabel($0) }
            let detail = [mode, [model, effort].compactMap { $0 }.joined(separator: " ") + (row.fast == true ? " ⚡" : "")]
                .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.joined(separator: " · ")
            let tone = row.status == "ok" ? "ok" : row.status == "stopped" ? "stopped" : "failed"
            let result = row.status == "ok" ? L10n.text("delegation.status.ok")
                : row.status == "stopped" ? L10n.text("delegation.status.stopped")
                : L10n.text("delegation.reason." + Self.reasonKey(row.status == "timedOut" ? "timeout" : row.reason))
            return Recent(time: time, title: hideProjects ? mode : row.label ?? mode, project: hideProjects ? nil : row.project,
                          detail: detail, duration: row.status == "refused" ? "—" : duration(row.seconds), result: result, tone: tone)
        }
        summary = ran.isEmpty ? L10n.text("collaboration.week_none")
            : L10n.text("collaboration.week", ran.count, Int((seconds / 60).rounded()), failed) + " · " + ClaudeCodexDelegation.compactCount(input + output) + " tokens"
    }

    static func reasonKey(_ reason: String?) -> String {
        ["login", "quota", "model", "timeout", "concurrency", "writer", "stopped"].contains(reason ?? "") ? reason! : "other"
    }
}
