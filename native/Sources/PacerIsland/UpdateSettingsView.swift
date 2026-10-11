import AppKit
import PacerCore
import SwiftUI

/// One version row with its status and the check action, then the switch.
struct UpdateSettingsView: View {
    @ObservedObject var updater: AppUpdater
    @Binding var automaticallyChecks: Bool
    private static let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String

    var body: some View {
        Section {
            HStack(spacing: 12) {
                Image(nsImage: NSApplication.shared.applicationIconImage).resizable().interpolation(.high)
                    .frame(width: 34, height: 34).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(["Codex Pacer", Self.version].compactMap { $0 }.joined(separator: " "))
                    if let detail {
                        Text(detail).font(.system(size: 11))
                            .foregroundStyle(updater.hasError ? Color.orange : Color.secondary)
                            .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                    }
                }
                Spacer(minLength: 8)
                Button(L10n.text("updates.check")) { updater.checkForUpdates() }.disabled(!updater.canCheck)
            }
            Toggle(L10n.text("updates.automatic"), isOn: $automaticallyChecks).disabled(!updater.enabled)
                .help(L10n.text("updates.policy"))
        }
    }

    private var detail: String? {
        updater.status ?? updater.lastChecked.map { L10n.text("updates.last_check", L10n.date($0)) }
    }
}
