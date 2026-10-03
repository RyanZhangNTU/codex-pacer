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
            Label(count.map { "\($0) 次重置" } ?? "重置 —", systemImage: "arrow.counterclockwise")
                .foregroundStyle(expirySoon ? Color.orange : .secondary)
                .help(expiryDescription)
                .accessibilityLabel("可用重置 \(count.map(String.init) ?? "未知") 次。\(expiryDescription)")
            Spacer(minLength: 8)
            HStack(spacing: 5) {
                Text(balanceText).foregroundStyle(.primary).monospacedDigit()
                Text("credit").foregroundStyle(.secondary)
            }
            .help("账户剩余 credit")
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("剩余 credit：\(balanceText)")
        }
        .font(.system(size: 13)).lineLimit(1)
        .padding(.vertical, 3)
    }
    private var expiryDescription: String {
        if count == 0 { return "暂无可用重置券" }
        if let expiry {
            let label = summary?.hasCompleteDetails == false ? "已知最近到期：" : "最近到期："
            return label + expiry.formatted(date: .complete, time: .shortened)
        }
        return summary?.hasNoExpiringCredits(at: now) == true ? "可用重置券不过期" : "重置券到期时间未知"
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
