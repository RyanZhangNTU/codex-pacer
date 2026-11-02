import Foundation

/// The warning slot keeps quota marks in provider order and appends at most
/// one wallet capsule. Native compatibility tests cover the shipping rules.
public enum CompactWarningPresentation {
    public enum FiveHourAlert: Equatable, Sendable { case low(Double), exhausted }
    public static func fiveHourAlert(provider: AgentProvider, snapshot: QuotaSnapshot?, failed: Bool, now: Date) -> FiveHourAlert? {
        guard !failed, let snapshot, !snapshot.isStale(at: now),
              let window = QuotaDashboardPresentation.bucket(provider: provider, snapshot: snapshot)?.windows.first(where: { $0.durationMinutes == 300 }),
              window.resetsAt.map({ $0 > now }) ?? true,
              let remaining = window.remainingPercent, remaining.isFinite else { return nil }
        return remaining <= 0 ? .exhausted : remaining < 20 ? .low(remaining) : nil
    }
    public struct Item: Codable, Equatable, Sendable {
        public let kind: String
        public let provider: String?
        public let solid: Bool
        public let label: String?
        public let symbol: String?
        public let help: String
        public var affectedProviders: [String] = []
    }
    public static func items(enabled: Set<AgentProvider>, warnings: Set<CompactIslandLayout.Warning>,
                             snapshots: [AgentProvider: QuotaSnapshot], failed: Set<AgentProvider> = [],
                             selections: [AgentProvider: QuotaWindowSelection] = [:], sshIssue: Bool = false,
                             wallet: DeepSeekAlertPresentation? = nil, now: Date) -> [Item] {
        let ordered = AgentProvider.allCases.filter { enabled.contains($0) && $0 != .deepseek }
        func windows(_ provider: AgentProvider) -> [QuotaWindow] {
            guard let snapshot = snapshots[provider] else { return [] }
            return (snapshot.buckets.first { $0.id == provider.rawValue } ?? snapshot.buckets.first)?.windows ?? []
        }
        var result: [Item] = []
        if warnings.contains(.fiveHour) {
            for provider in ordered {
                guard let alert = fiveHourAlert(provider: provider, snapshot: snapshots[provider], failed: failed.contains(provider), now: now) else { continue }
                let exhausted = alert == .exhausted
                let help: String
                switch alert {
                case .exhausted: help = L10n.text("quota.five_hour_exhausted", provider.displayName)
                case .low(let remaining): help = L10n.text("quota.five_hour_low", provider.displayName, "\(Int(remaining.rounded()))%")
                }
                result.append(.init(kind: "fiveHour", provider: provider.rawValue, solid: exhausted, label: "5h", symbol: nil, help: help))
            }
        }
        if warnings.contains(.ssh), sshIssue {
            result.append(.init(kind: "ssh", provider: nil, solid: false, label: nil, symbol: "network.slash", help: L10n.text("source.ssh_retrying")))
        }
        if warnings.contains(.quotaDelay) {
            let delayed = ordered.filter { provider in
                guard let snapshot = snapshots[provider] else { return failed.contains(provider) }
                let own = windows(provider)
                let selected = (selections[provider] == .fiveHour ? own.first { $0.durationMinutes == 300 } : nil)
                    ?? own.first { $0.durationMinutes == 10080 } ?? snapshot.windows.first { $0.durationMinutes == 10080 } ?? snapshot.limitingWindow
                return failed.contains(provider) || snapshot.isStale(at: now) || selected?.resetsAt.map({ $0 <= now }) == true
            }
            if !delayed.isEmpty {
                result.append(.init(kind: "quotaDelay", provider: nil, solid: false, label: nil, symbol: "clock.arrow.circlepath",
                    help: delayed.map(\.displayName).joined(separator: " · ") + " · " + L10n.text("warning.quotaDelay"), affectedProviders: delayed.map(\.rawValue)))
            }
        }
        if enabled.contains(.deepseek), let wallet {
            result.append(.init(kind: wallet.kind, provider: "deepseek", solid: wallet.solid, label: wallet.label, symbol: wallet.symbol, help: wallet.help))
        }
        return result
    }
}
