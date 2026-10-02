import SwiftUI
import PacerCore

struct AccountUsageView: View {
    let snapshot: QuotaSnapshot
    let now: Date
    private var summary: QuotaResetSummary? { snapshot.resetCredits }
    private var count: Int? { summary?.remainingCount(at: now, capturedAt: snapshot.capturedAt) }
    private var expiry: Date? { summary?.nextExpiry(at: now) }

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            metric("重置次数", value: count.map { "\($0) 次" } ?? "—")
            metric(summary?.hasCompleteDetails == false && expiry != nil ? "已知到期" : "最近到期",
                value: expiryText,
                color: expiry.map { $0.timeIntervalSince(now) < 3 * 86400 ? .orange : .primary } ?? .primary)
                .help(expiry.map { $0.formatted(date: .complete, time: .shortened) } ?? "可用重置券的到期时间")
            metric("剩余 credit", value: balanceText)
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }
    private func metric(_ title: String, value: String, color: Color = .primary) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.system(size: 11)).foregroundStyle(.secondary)
            Text(value).font(.system(size: 15, weight: .medium)).monospacedDigit().foregroundStyle(color)
                .lineLimit(1).minimumScaleFactor(0.8)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
    private var expiryText: String {
        if count == 0 { return "—" }
        if let expiry {
            let formatter = DateFormatter(); formatter.dateFormat = "MM/dd HH:mm"
            return formatter.string(from: expiry)
        }
        return summary?.hasNoExpiringCredits(at: now) == true ? "不过期" : "—"
    }
    private var balanceText: String {
        guard let credits = snapshot.credits else { return "—" }
        if credits.unlimited { return "不限" }
        guard let amount = credits.amount else { return "—" }
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = 2
        return formatter.string(from: NSDecimalNumber(decimal: amount)) ?? "—"
    }
}
