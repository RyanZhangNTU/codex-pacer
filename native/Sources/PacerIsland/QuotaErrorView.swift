import PacerCore
import SwiftUI

struct QuotaErrorView: View {
    let message: String
    let cliPath: String?
    let homePath: String
    let cachedAt: Date?
    let refreshing: Bool
    let onRetry: () -> Void
    let onSettings: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(L10n.text("quota.unavailable"), systemImage: "exclamationmark.circle")
                .font(.system(size: 13, weight: .semibold)).foregroundStyle(.orange)
            Text(message)
                .font(.system(size: 12)).foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
            VStack(alignment: .leading, spacing: 4) {
                if let cliPath, !message.contains(cliPath) {
                    Text(L10n.text("cli.path", cliPath))
                }
                Text(L10n.text("cli.home", homePath))
            }
            .font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
            if let cachedAt {
                Text(L10n.text("quota.cached", L10n.date(cachedAt)))
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 14) {
                Button(refreshing ? L10n.text("common.retrying") : L10n.text("common.retry"), action: onRetry).disabled(refreshing)
                Button(L10n.text("common.open_settings"), action: onSettings)
            }
            .font(.system(size: 12)).buttonStyle(.borderless)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(.orange.opacity(0.06)))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(.orange.opacity(0.14), lineWidth: 0.5))
    }
}
