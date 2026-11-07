import PacerCore
import SwiftUI

/// The newest update note in full, with the same highlights and switches as
/// the once-per-update note, then every earlier one folded to a line.
struct SettingsWhatsNewPane: View {
    private static let releaseNotes = URL(string: "https://github.com/RyanZhangNTU/codex-pacer/releases")!
    @ObservedObject var launchAtLogin: LaunchAtLoginPreference
    @State private var expanded: Set<String> = []

    var body: some View {
        let history = WhatsNew.history(upTo: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String)
        if let latest = history.first {
            LatestRelease(release: latest, notes: Self.releaseNotes, launchAtLogin: launchAtLogin)
        }
        if history.count > 1 {
            MainCard(title: L10n.text("whats_new.earlier")) {
                ForEach(history.dropFirst(), id: \.version) { release in
                    EarlierRelease(release: release, launchAtLogin: launchAtLogin, isExpanded: Binding(
                        get: { expanded.contains(release.version) },
                        set: { if $0 { expanded.insert(release.version) } else { expanded.remove(release.version) } }))
                }
            }
        }
    }
}

/// The newest note as a feature list: large symbols, and the full release
/// notes one click away.
private struct LatestRelease: View {
    let release: WhatsNew.Release
    let notes: URL
    @ObservedObject var launchAtLogin: LaunchAtLoginPreference

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(L10n.text("whats_new.version", release.version)).font(.system(size: 15, weight: .semibold))
                    .monospacedDigit().accessibilityAddTraits(.isHeader)
                Spacer(minLength: 8)
                Link(destination: notes) {
                    HStack(spacing: 3) {
                        Text(L10n.text("whats_new.release_notes"))
                        Image(systemName: "arrow.up.right").font(.system(size: 9, weight: .semibold))
                    }
                }
                .font(.system(size: 12.5))
            }
            ForEach(Array(release.items.enumerated()), id: \.offset) { _, item in
                WhatsNewItemRow(item: item, launchAtLogin: launchAtLogin, large: true, detailInInfo: true)
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .mainCardSurface()
    }
}

/// An earlier version on one line: its highlights' titles until opened.
private struct EarlierRelease: View {
    let release: WhatsNew.Release
    @ObservedObject var launchAtLogin: LaunchAtLoginPreference
    @Binding var isExpanded: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Button {
                withAnimation(.easeOut(duration: 0.15)) { isExpanded.toggle() }
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "chevron.right").font(.system(size: 10, weight: .bold)).foregroundStyle(.secondary)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0)).frame(width: 10)
                    Text(release.version).font(.system(size: 13, weight: .medium)).monospacedDigit()
                        .frame(minWidth: 42, alignment: .leading)
                    Text(release.items.map { L10n.text($0.titleKey) }.joined(separator: " · "))
                        .font(.system(size: 12.5)).foregroundStyle(.secondary).lineLimit(1)
                        .opacity(isExpanded ? 0 : 1)
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, minHeight: 28, alignment: .leading).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(L10n.text("whats_new.version", release.version))
            .accessibilityValue(L10n.text(isExpanded ? "main.info_shown" : "main.info_hidden"))
            if isExpanded {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(Array(release.items.enumerated()), id: \.offset) { _, item in
                        WhatsNewItemRow(item: item, launchAtLogin: launchAtLogin, detailInInfo: true)
                    }
                }
                .padding(.leading, 20).padding(.bottom, 4)
            }
        }
    }
}
