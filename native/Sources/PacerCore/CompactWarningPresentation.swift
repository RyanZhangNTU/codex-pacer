import Foundation

/// The warning slot keeps quota marks in provider order and appends at most
/// one wallet capsule.
public enum CompactWarningPresentation {
    public enum FiveHourAlert: Equatable, Sendable { case low(Double), exhausted }
    public static func fiveHourAlert(provider: AgentProvider, snapshot: QuotaSnapshot?, failed: Bool, now: Date) -> FiveHourAlert? {
        alerts(provider: provider, snapshot: snapshot, failed: failed, now: now).map(\.1).min { a, b in
            switch (a, b) {
            case (.exhausted, .low): true
            case (.low(let left), .low(let right)): left < right
            default: false
            }
        }
    }
    private static func alerts(provider: AgentProvider, snapshot: QuotaSnapshot?, failed: Bool, now: Date) -> [(String, FiveHourAlert)] {
        guard !failed, let snapshot, !snapshot.isStale(at: now) else { return [] }
        let buckets = provider == .antigravity ? snapshot.buckets : [QuotaDashboardPresentation.bucket(provider: provider, snapshot: snapshot)].compactMap { $0 }
        return buckets.compactMap { bucket in
            guard let window = bucket.windows.first(where: { $0.durationMinutes == 300 }),
                  window.resetsAt.map({ $0 > now }) ?? true, let remaining = window.remainingPercent,
                  remaining < 20 else { return nil }
            let name = provider == .antigravity ? [provider.displayName, bucket.name].compactMap { $0 }.joined(separator: " · ") : provider.displayName
            return (name, remaining <= 0 ? .exhausted : .low(remaining))
        }
    }
    public struct Item: Codable, Equatable, Sendable {
        public enum Kind: String, Codable, CaseIterable, Sendable {
            case fiveHour, ssh, quotaDelay, exhausted, lowBalance, spike, overBudget, nearingBudget, lowCredits, resetExpiry, codexHooks

            init(_ wallet: DeepSeekAlertPresentation.Kind) {
                switch wallet {
                case .exhausted: self = .exhausted
                case .lowBalance: self = .lowBalance
                case .spike: self = .spike
                case .overBudget: self = .overBudget
                case .nearingBudget: self = .nearingBudget
                }
            }
        }
        public let kind: Kind
        public let provider: String?
        public let solid: Bool
        public let label: String?
        public let symbol: String?
        public let help: String
        public var affectedProviders: [String] = []
    }
    public static func summary(_ items: [Item]) -> String {
        var fiveHour: [String] = [], other: [String] = []
        for item in items {
            switch item.kind {
            case .fiveHour: fiveHour.append(item.help)
            case .ssh, .codexHooks, .quotaDelay, .exhausted, .lowBalance, .spike, .overBudget, .nearingBudget, .lowCredits, .resetExpiry: other.append(item.help)
            }
        }
        return ([fiveHour.joined(separator: " · ")] + other).filter { !$0.isEmpty }.joined(separator: "\n")
    }
    public static func items(enabled: Set<AgentProvider>, warnings: Set<CompactIslandLayout.Warning>,
                             snapshots: [AgentProvider: QuotaSnapshot], failed: Set<AgentProvider> = [],
                             selections: [AgentProvider: QuotaWindowSelection] = [:], sshIssue: Bool = false, codexHooksNeedUser: Bool = false,
                             wallet: DeepSeekAlertPresentation? = nil,
                             credits: [AgentProvider: HarnessAccountCredits] = [:],
                             creditSettings: [AgentProvider: HarnessCreditsSettings] = [:],
                             resetLeadDays: Int = ResetExpiryReminder.defaultLeadDays, now: Date) -> [Item] {
        let ordered = HarnessRegistry.ids(where: \.hasQuotaWindows).filter(enabled.contains)
        func windows(_ provider: AgentProvider) -> [QuotaWindow] {
            guard let snapshot = snapshots[provider] else { return [] }
            return (snapshot.buckets.first { $0.id == provider.rawValue } ?? snapshot.buckets.first)?.windows ?? []
        }
        var result: [Item] = []
        if warnings.contains(.fiveHour) {
            for provider in ordered {
                let readings = alerts(provider: provider, snapshot: snapshots[provider], failed: failed.contains(provider), now: now)
                guard !readings.isEmpty else { continue }
                let help = readings.map { name, alert in
                    switch alert {
                    case .exhausted: L10n.text("quota.five_hour_exhausted", name)
                    case .low(let remaining): L10n.text("quota.five_hour_low", name, "\(Int(remaining.rounded()))%")
                    }
                }.joined(separator: "\n")
                result.append(.init(kind: .fiveHour, provider: provider.rawValue, solid: readings.contains { $0.1 == .exhausted },
                                    label: "5h", symbol: nil, help: help))
            }
        }
        if warnings.contains(.ssh), sshIssue {
            result.append(.init(kind: .ssh, provider: nil, solid: false, label: L10n.text("warning.label.ssh"), symbol: nil, help: L10n.text("source.ssh_retrying")))
        }
        // Until the user allows Pacer's hooks in Codex, no local Codex task can show. Like an
        // empty wallet, this shows whatever the warning choices, and only until it is resolved.
        if codexHooksNeedUser, enabled.contains(.codex) {
            result.append(.init(kind: .codexHooks, provider: AgentProvider.codex.rawValue, solid: false, label: L10n.text("warning.label.codexHooks"),
                                symbol: nil, help: L10n.text("codex.hooks.needs_approval")))
        }
        if warnings.contains(.quotaDelay) {
            let delayed = ordered.filter { provider in
                guard let snapshot = snapshots[provider] else { return failed.contains(provider) }
                if provider == .antigravity {
                    return failed.contains(provider) || snapshot.isStale(at: now) || snapshot.windows.contains { $0.resetsAt.map { $0 <= now } == true }
                }
                let own = windows(provider)
                let selected = (selections[provider] == .fiveHour ? own.first { $0.durationMinutes == 300 } : nil)
                    ?? own.first { $0.durationMinutes == 10080 } ?? snapshot.windows.first { $0.durationMinutes == 10080 } ?? snapshot.limitingWindow
                return failed.contains(provider) || snapshot.isStale(at: now) || selected?.resetsAt.map({ $0 <= now }) == true
            }
            if !delayed.isEmpty {
                // A failed read needs the user; a late update only needs noticing.
                result.append(.init(kind: .quotaDelay, provider: nil, solid: delayed.contains { failed.contains($0) },
                    label: L10n.text("warning.label.quotaDelay"), symbol: nil,
                    help: delayed.flatMap { provider -> [String] in
                        guard provider == .antigravity, let snapshot = snapshots[provider] else { return [provider.displayName] }
                        return snapshot.buckets.filter { bucket in
                            failed.contains(provider) || snapshot.isStale(at: now) || bucket.windows.contains { $0.resetsAt.map { $0 <= now } == true }
                        }.map { provider.displayName + " · " + ($0.name ?? $0.id) }
                    }.joined(separator: " · ") + " · " + L10n.text("warning.quotaDelay"), affectedProviders: delayed.map(\.rawValue)))
            }
        }
        if warnings.contains(.lowCredits) {
            for provider in HarnessRegistry.ids(where: \.reportsAccountCredits) where enabled.contains(provider) {
                guard let reading = credits[provider]?.reading(at: now), let level = HarnessCreditsNoticePolicy.level(reading, settings: creditSettings[provider] ?? .default) else { continue }
                result.append(.init(kind: .lowCredits, provider: provider.rawValue, solid: level == .exhausted, label: nil,
                    symbol: "exclamationmark.circle",
                    help: L10n.text("warning.low_credits_help", provider.displayName, HarnessAccountCredits.compactAmount(reading.remaining))))
            }
        }
        if warnings.contains(.resetExpiry), enabled.contains(.codex),
           let item = ResetExpiryReminder.warning(snapshots[.codex], leadDays: resetLeadDays, now: now) {
            result.append(item)
        }
        if enabled.contains(.deepseek), let wallet {
            let label = wallet.kind == .spike ? L10n.text("warning.label.spike") : wallet.label
            result.append(.init(kind: .init(wallet.kind), provider: "deepseek", solid: wallet.solid, label: label,
                symbol: label == nil ? wallet.symbol : nil, help: wallet.help))
        }
        return Self.ordered(result)
    }

    /// Marks that need the user come first; each group keeps its source order.
    public static func ordered(_ items: [Item]) -> [Item] { items.filter(\.solid) + items.filter { !$0.solid } }

    /// The marks a collapsed bar draws and how many fold into the "+N" mark.
    /// A limit of zero shows every mark.
    public static func visible(_ items: [Item], limit: Int) -> (shown: [Item], hidden: Int) {
        let sorted = ordered(items)
        guard limit > 0, sorted.count > limit else { return (sorted, 0) }
        return (Array(sorted.prefix(limit)), sorted.count - limit)
    }
}
