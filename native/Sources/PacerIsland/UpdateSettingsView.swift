import PacerCore
import SwiftUI

struct UpdateSettingsView: View {
    @ObservedObject var updater: AppUpdater
    @Binding var automaticallyChecks: Bool

    var body: some View {
        Section(L10n.text("updates.section")) {
            Toggle(L10n.text("updates.automatic"), isOn: $automaticallyChecks).disabled(!updater.enabled)
            Text(L10n.text("updates.policy"))
                .font(.system(size: 11)).foregroundStyle(.secondary)
            HStack {
                Button(L10n.text("updates.check")) { updater.checkForUpdates() }.disabled(!updater.canCheck)
                Spacer()
                if let checked = updater.lastChecked {
                    Text(L10n.text("updates.last_check", L10n.date(checked)))
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                }
            }
            if let status = updater.status {
                Text(status).font(.system(size: 11))
                    .foregroundStyle(updater.hasError ? Color.orange : Color.secondary)
                    .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
            }
        }
    }
}
