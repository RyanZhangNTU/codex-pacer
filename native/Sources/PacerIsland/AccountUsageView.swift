import SwiftUI
import PacerCore

struct AccountUsageView: View {
    let snapshot: QuotaSnapshot
    let now: Date
    private var summary: QuotaResetSummary? { snapshot.resetCredits }
    private var count: Int? { summary?.remainingCount(at: now, capturedAt: snapshot.capturedAt) }
    private var expiry: Date? { summary?.nextExpiry(at: now) }
    private var expirySoon: Bool { expiry.map { $0.timeIntervalSince(now) < 3 * 86400 } ?? false }

    var body: some View {
        HStack(spacing: 14) {
            Label(count.map { L10n.text("account.reset_count", $0) } ?? L10n.text("account.resets_unknown"), systemImage: "arrow.counterclockwise")
                .foregroundStyle(expirySoon ? Color.orange : .secondary)
                .help(expiryDescription)
                .accessibilityLabel(L10n.text("account.resets_accessibility", count.map(String.init) ?? L10n.text("common.unknown"), expiryDescription))
            Spacer(minLength: 8)
            HStack(spacing: 5) {
                Text(balanceText).foregroundStyle(.primary).monospacedDigit()
                Text(L10n.text("account.credits")).foregroundStyle(.secondary)
            }
            .help(L10n.text("account.credits_help"))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(L10n.text("account.credit_balance", balanceText))
        }
        .font(.system(size: 13)).lineLimit(1)
        .padding(.vertical, 3)
    }
    private var expiryDescription: String {
        if count == 0 { return L10n.text("account.no_resets") }
        if let expiry {
            return L10n.text(summary?.hasCompleteDetails == false ? "account.known_expiry" : "account.next_expiry",
                L10n.date(expiry, date: .complete))
        }
        return summary?.hasNoExpiringCredits(at: now) == true ? L10n.text("account.no_expiry") : L10n.text("account.expiry_unknown")
    }
    private var balanceText: String {
        guard let credits = snapshot.credits else { return "—" }
        if credits.unlimited { return L10n.text("common.unlimited") }
        guard let amount = credits.amount else { return "—" }
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.locale = L10n.locale
        formatter.maximumFractionDigits = 2
        return formatter.string(from: NSDecimalNumber(decimal: amount)) ?? "—"
    }
}
