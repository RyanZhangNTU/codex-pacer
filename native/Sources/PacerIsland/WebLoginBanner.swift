import AppKit
import PacerCore
import SwiftUI

/// Tells a new sign-in from the session a login window opened with. Both
/// windows pass one-way fingerprints only (Claude's session hash, a digest of
/// DeepSeek's page token), so reopening the window while signed in, or a
/// challenge that keeps the same session, never reads as a new account.
struct WebLoginSessionWatch: Equatable {
    enum Outcome: Equatable {
        /// No session: closing the window changes nothing.
        case none
        /// The session the window opened with: read again with the same choices.
        case existing
        /// A different session: a new sign-in, possibly another account.
        case new
    }

    private var baselineKnown = false
    private var baseline: String?

    /// The first observation is the baseline; later ones report a new sign-in.
    mutating func observe(_ fingerprint: String?) -> Bool {
        guard baselineKnown else {
            baselineKnown = true; baseline = fingerprint
            return false
        }
        return outcome(for: fingerprint) == .new
    }

    func outcome(for fingerprint: String?) -> Outcome {
        guard let fingerprint else { return .none }
        return baselineKnown && fingerprint != baseline ? .new : .existing
    }
}

@MainActor
final class WebLoginBannerState: ObservableObject {
    enum Phase { case prompt, loadFailed, signedIn }
    @Published var phase = Phase.prompt
}

/// The strip above Pacer's sign-in pages: what signing in shows, then a
/// confirmation once a new sign-in appears, shortly before the window closes.
struct WebLoginBanner: View {
    struct Copy {
        var prompt: String
        var promptDetail: String
        var signedIn: String
        var signedInDetail: String
    }

    static let autoCloseDelay: Duration = .milliseconds(1500)

    let provider: AgentProvider
    let copy: Copy
    @ObservedObject var state: WebLoginBannerState
    let onReload: () -> Void
    let onLater: () -> Void
    let onDone: () -> Void

    var body: some View {
        let signedIn = state.phase == .signedIn
        HStack(spacing: 11) {
            if signedIn {
                Image(systemName: "checkmark.circle.fill").font(.system(size: 24)).foregroundStyle(.green)
                    .frame(width: 28, height: 28).accessibilityHidden(true)
            } else {
                SettingsIconTile(symbol: provider.glyph, tint: provider.shade(light: false), glyph: Color.black.opacity(0.72), size: 28)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(signedIn ? copy.signedIn : copy.prompt).font(.system(size: 13, weight: .semibold))
                Text(detail).font(.system(size: 11.5)).foregroundStyle(state.phase == .loadFailed ? .orange : .secondary)
            }
            .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            if signedIn {
                Button(L10n.text("login.done"), action: onDone)
                    .keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent)
            } else {
                Button(action: onReload) { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.borderless).help(L10n.text("common.refresh"))
                    .accessibilityLabel(L10n.text("common.refresh"))
                Button(L10n.text("login.later"), action: onLater)
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background((signedIn ? Color.green : provider.tint).opacity(0.16))
        .overlay(alignment: .bottom) { Divider() }
        .animation(.easeOut(duration: 0.2), value: state.phase)
        .environment(\.locale, L10n.locale)
    }

    private var detail: String {
        switch state.phase {
        case .prompt: copy.promptDetail
        case .loadFailed: L10n.text("claude.login.load_failed")
        case .signedIn: copy.signedInDetail
        }
    }
}

extension NSView {
    /// The login windows' layout: the banner above a page that fills the rest.
    static func webLoginContainer(banner: NSView, page: NSView) -> NSView {
        let container = NSView()
        for view in [banner, page] {
            view.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(view)
        }
        NSLayoutConstraint.activate([
            banner.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            banner.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            banner.topAnchor.constraint(equalTo: container.topAnchor),
            page.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            page.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            page.topAnchor.constraint(equalTo: banner.bottomAnchor),
            page.bottomAnchor.constraint(equalTo: container.bottomAnchor)
        ])
        return container
    }
}
