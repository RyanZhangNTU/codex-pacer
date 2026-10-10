import PacerCore
import SwiftUI

/// First-launch guide for 3.0: two quick-start actions, then the same legend
/// as Settings → Help, which stays available afterwards.
struct WelcomeView: View {
    @ObservedObject var model: IslandModel
    let onOpenSettings: (SettingsPane) -> Void
    let onDone: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 52, height: 52).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text(L10n.text("welcome.title")).font(.system(size: 20, weight: .semibold))
                    Text(L10n.text("welcome.subtitle")).font(.system(size: 12)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 24).padding(.top, 22).padding(.bottom, 6)
            Form {
                Section(L10n.text("welcome.section.start")) {
                    if model.isModuleEnabled(.claude) { action(.claude, key: "welcome.claude") }
                    action(.collapsedBar, key: "welcome.layout")
                }
                SettingsHelpPane()
            }
            .formStyle(.grouped)
            Divider()
            HStack(spacing: 12) {
                Text(L10n.text("welcome.footer")).font(.system(size: 11)).foregroundStyle(.secondary)
                Spacer(minLength: 8)
                Button(L10n.text("welcome.done"), action: onDone)
                    .keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent)
            }
            .padding(.horizontal, 20).padding(.vertical, 12)
        }
        .frame(width: 560, height: 640)
        .environment(\.locale, L10n.locale)
    }

    private func action(_ pane: SettingsPane, key: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: pane.symbol).font(.system(size: 11, weight: .semibold)).foregroundStyle(pane.glyphColor)
                .frame(width: 26, height: 26)
                .background(pane.tint.gradient, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(L10n.text(key + ".title"))
                Text(L10n.text(key + ".detail")).font(.system(size: 11)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Button(L10n.text("welcome.go")) { onOpenSettings(pane) }
        }
    }
}
