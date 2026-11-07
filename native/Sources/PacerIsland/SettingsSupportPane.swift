import AppKit
import PacerCore
import SwiftUI

/// Thanks, then the ways to help back: a star, a share and a coffee, each a
/// card with its buttons at the bottom, then feature requests and bug reports.
/// This page is the only place Pacer asks; nothing here prompts or reads the network.
struct SettingsSupportPane: View {
    private let codes = ProjectSupport.codes()
    @State private var copied = false
    @State private var copyReset: Task<Void, Never>?
    private static let starTint = Color(red: 0.96, green: 0.68, blue: 0.11)
    private static let shareTint = Color(red: 0.2, green: 0.66, blue: 0.45)
    private static let coffeeTint = Color(red: 0.62, green: 0.42, blue: 0.27)

    var body: some View {
        VStack(spacing: 12) {
            hero
            HStack(alignment: .top, spacing: 12) {
                card("support.star", symbol: "star.fill", tint: Self.starTint) {
                    Button { NSWorkspace.shared.open(ProjectSupport.star) } label: {
                        Label(L10n.text("support.star.action"), systemImage: "star").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(MainButtonStyle(prominent: true, height: 28))
                }
                card("support.share", symbol: "square.and.arrow.up.fill", tint: Self.shareTint) {
                    ShareLink(item: ProjectSupport.repository, subject: Text(L10n.text("support.share.subject")),
                              message: Text(L10n.text("support.share.message"))) {
                        Label(L10n.text("support.share.action"), systemImage: "square.and.arrow.up").frame(maxWidth: .infinity)
                    }
                    Button(action: copyLink) {
                        Label(L10n.text(copied ? "support.share.copied" : "support.share.copy"),
                              systemImage: copied ? "checkmark" : "link").frame(maxWidth: .infinity)
                    }
                }
                if !codes.isEmpty || !ProjectSupport.donationLinks.isEmpty {
                    card("support.coffee", symbol: "cup.and.saucer.fill", tint: Self.coffeeTint) {
                        ForEach(codes, id: \.titleKey) { SupportCodeButton(code: $0) }
                        ForEach(ProjectSupport.donationLinks, id: \.url) { link in
                            Button { NSWorkspace.shared.open(link.url) } label: {
                                Label(link.title, systemImage: "cup.and.saucer").frame(maxWidth: .infinity)
                            }
                        }
                    }
                }
            }
            .fixedSize(horizontal: false, vertical: true)
        }
        MainCard(title: L10n.text("main.support.feedback")) {
            SupportLinkRow(title: L10n.text("support.star.feature"), symbol: "lightbulb.fill",
                           tint: Color(red: 0.98, green: 0.76, blue: 0.2), url: ProjectSupport.featureRequest)
            SupportLinkRow(title: L10n.text("support.star.bug"), symbol: "ladybug.fill",
                           tint: Color(red: 0.94, green: 0.36, blue: 0.33), url: ProjectSupport.bugReport)
        }
    }

    /// The icon and thanks over a faint wash of the three services' colors.
    private var hero: some View {
        HStack(spacing: 16) {
            Image(nsImage: NSApp.applicationIconImage).resizable().interpolation(.high)
                .frame(width: 60, height: 60).shadow(color: .black.opacity(0.25), radius: 6, y: 2)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 5) {
                Text(L10n.text("support.thanks.title")).font(.system(size: 17, weight: .semibold))
                Text(L10n.text("support.thanks.detail")).font(.system(size: 12.5)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 20).padding(.vertical, 18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            ZStack {
                MainPalette.card
                LinearGradient(colors: [AgentProvider.codex.tint.opacity(0.16), AgentProvider.claude.tint.opacity(0.12),
                                        AgentProvider.deepseek.tint.opacity(0.16)],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
            }
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(MainPalette.cardBorder))
        .accessibilityElement(children: .combine)
    }

    /// One way to help: its tile, name and a sentence, with the buttons
    /// pinned to the bottom so the three cards line up.
    private func card<Actions: View>(_ key: String, symbol: String, tint: Color, @ViewBuilder actions: () -> Actions) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsIconTile(symbol: symbol, tint: tint, size: 30)
            Text(L10n.text(key + ".title")).font(.system(size: 13.5, weight: .semibold))
                .fixedSize(horizontal: false, vertical: true).padding(.top, 12)
                .accessibilityAddTraits(.isHeader)
            Text(L10n.text(key + ".detail")).font(.system(size: 12)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true).padding(.top, 4)
            Spacer(minLength: 14)
            VStack(spacing: 6) { actions() }
                .buttonStyle(MainButtonStyle(height: 28))
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .mainCardSurface(radius: 14)
    }

    private func copyLink() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(ProjectSupport.repository.absoluteString, forType: .string)
        copied = true
        copyReset?.cancel()
        copyReset = Task {
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            copied = false
        }
    }
}

/// A row that opens a GitHub form in the browser, lit on hover.
private struct SupportLinkRow: View {
    let title: String
    let symbol: String
    let tint: Color
    let url: URL
    @State private var hovering = false

    var body: some View {
        Button { NSWorkspace.shared.open(url) } label: {
            HStack(spacing: 10) {
                SettingsIconTile(symbol: symbol, tint: tint)
                Text(title).font(.system(size: 13))
                Spacer(minLength: 8)
                Image(systemName: "arrow.up.right").font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(hovering ? Color.primary : Color.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(url.absoluteString)
    }
}

/// A payment app's QR code, shown on request. It sits on white so it scans in
/// dark Settings too.
private struct SupportCodeButton: View {
    let code: ProjectSupport.Code
    @State private var showing = false
    @State private var escapeMonitor: Any?

    var body: some View {
        Button { showing.toggle() } label: {
            Label(L10n.text(code.titleKey), systemImage: "qrcode").frame(maxWidth: .infinity)
        }
        .popover(isPresented: $showing, arrowEdge: .bottom) {
            VStack(spacing: 8) {
                if let image = NSImage(contentsOf: code.image) {
                    Image(nsImage: image).resizable().interpolation(.high).scaledToFit()
                        .frame(width: 220, height: 220)
                        .background(Color.white, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
                Text(L10n.text(code.hintKey)).font(.system(size: 12)).foregroundStyle(.secondary)
            }
            .padding(12)
        }
        .onChange(of: showing) { _, open in
            if open { watchEscape() } else { stopWatchingEscape() }
        }
        .onDisappear(perform: stopWatchingEscape)
    }

    /// Settings closes on Esc, so the open popover claims the key first.
    private func watchEscape() {
        escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard event.keyCode == 53 else { return event }
            showing = false
            return nil
        }
    }

    private func stopWatchingEscape() {
        if let escapeMonitor { NSEvent.removeMonitor(escapeMonitor) }
        escapeMonitor = nil
    }
}
