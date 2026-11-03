import Foundation

/// Labels and state-dependent tones from the original time dial. Platform
/// renderers receive no source credentials or account identifiers.
public struct DeepSeekDialPresentation: Codable, Equatable, Sendable {
    public enum Tone: String, Codable, Sendable { case primary, secondary, tertiary, attention, danger, provider, staleSegment }
    public let balanceWhole: String, balanceCents: String
    public let todayText: String
    public let subtitle: String
    public let subtitleTone: Tone
    public let balanceTone: Tone
    public let segmentTone: Tone
    public let dimmedFace: Bool
    public let staleCaption: Bool
    public let connectTitle: String?
    public let freshness: String
    public let help: String
    public let accessibilityLabel: String
    public let peakHelp: String
    public let peakText: String?

    public init(wallet: DeepSeekWallet, at now: Date, refreshing: Bool = false, needsConnection: Bool = true, apiKey: Bool = false) {
        let parts = String(format: "%.2f", max(0, wallet.balance?.total ?? 0)).split(separator: ".")
        balanceWhole = String(parts.first ?? "0"); balanceCents = "." + String(parts.last ?? "00")
        if let captured = wallet.balance?.capturedAt {
            let elapsed = max(0, Int(now.timeIntervalSince(captured)))
            freshness = elapsed < 10 ? L10n.text("quota.just_updated") : elapsed < 60 ? L10n.text("quota.seconds_ago", elapsed) : L10n.text("quota.minutes_ago", elapsed / 60)
        } else { freshness = L10n.text("quota.not_read") }
        let today = L10n.text("deepseek.today", Self.amount(wallet.todayTotal))
        todayText = today
        if wallet.balance == nil { subtitle = refreshing ? L10n.text("deepseek.reading") : today }
        else if wallet.state == .exhausted { subtitle = L10n.text("deepseek.wallet.exhausted") }
        else if wallet.state == .stale { subtitle = freshness }
        else if let days = wallet.runwayDays { subtitle = days >= 365 ? L10n.text("deepseek.runway_year") : L10n.text("deepseek.runway_short", max(1, Int(days.rounded(.down)))) }
        else { subtitle = today }
        switch wallet.state {
        case .normal: balanceTone = .primary; subtitleTone = .secondary
        case .low: balanceTone = .attention; subtitleTone = .attention
        case .exhausted: balanceTone = .danger; subtitleTone = .danger
        case .stale: balanceTone = .secondary; subtitleTone = .tertiary
        case .disconnected: balanceTone = .secondary; subtitleTone = .tertiary
        }
        dimmedFace = wallet.state == .stale && wallet.balance != nil
        staleCaption = dimmedFace
        segmentTone = dimmedFace ? .staleSegment : wallet.state == .exhausted ? .danger : .provider
        connectTitle = wallet.balance == nil && !refreshing && needsConnection ? L10n.text(apiKey ? "deepseek.paste_key_short" : "deepseek.sign_in") : nil
        var details = [L10n.text("deepseek.dial_help")]
        if !wallet.peakToday.isEmpty { details.append(L10n.text("deepseek.peak_hours_help")) }
        details.append(L10n.text("deepseek.estimate_help"))
        if let days = wallet.runwayDays, wallet.balance != nil { details.append(L10n.text("deepseek.runway_help_days", Self.amount(wallet.averageDaily ?? 0), Int(days.rounded(.down)))) }
        if wallet.balance != nil { details.append(freshness) }
        help = details.joined(separator: "\n")
        accessibilityLabel = L10n.text("deepseek.dial_accessibility", wallet.balance.map { Self.amount($0.total) } ?? L10n.text("common.unknown"), Self.amount(wallet.todayTotal), L10n.text(wallet.peakNow ? "deepseek.now.peak" : "deepseek.now.offpeak"))
        peakHelp = L10n.text("deepseek.peak_hours_help")
        peakText = wallet.peakNow ? "×2" : nil
    }
    public static func amount(_ value: Double) -> String {
        value < 1000 ? String(format: "¥%.2f", max(0, value)) : DeepSeekWallet.compactAmount(value)
    }
}
