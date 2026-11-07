import PacerCore
import SwiftUI

/// Every update note up to the running version, newest first, with the same
/// highlights and switches as the once-per-update note.
struct SettingsWhatsNewPane: View {
    private static let releaseNotes = URL(string: "https://github.com/RyanZhangNTU/codex-pacer/releases")!
    @ObservedObject var launchAtLogin: LaunchAtLoginPreference

    var body: some View {
        ForEach(WhatsNew.history(upTo: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String),
                id: \.version) { release in
            MainCard(title: L10n.text("whats_new.version", release.version)) {
                ForEach(Array(release.items.enumerated()), id: \.offset) { _, item in
                    WhatsNewItemRow(item: item, launchAtLogin: launchAtLogin)
                }
            }
        }
        Link(destination: Self.releaseNotes) { Label(L10n.text("whats_new.release_notes"), systemImage: "doc.text") }
            .font(.system(size: 12.5)).padding(.leading, 4)
    }
}
