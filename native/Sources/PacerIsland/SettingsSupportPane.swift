import AppKit
import PacerCore
import SwiftUI

/// Thanks, then the ways to help back: a star, a share and a coffee. This page
/// is the only place Pacer asks; nothing here prompts or reads the network.
struct SettingsSupportPane: View {
    private let codes = ProjectSupport.codes()
    @State private var copied = false
    @State private var copyReset: Task<Void, Never>?

    var body: some View {
        Section {
            HStack(spacing: 14) {
                Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 48, height: 48).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text(L10n.text("support.thanks.title")).font(.system(size: 15, weight: .semibold))
                    Text(L10n.text("support.thanks.detail")).font(.system(size: 11)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.vertical, 4)
            .accessibilityElement(children: .combine)
        }
        Section {
            row("support.star", symbol: "star.fill", tint: Color(red: 0.96, green: 0.68, blue: 0.11)) {
                Button { NSWorkspace.shared.open(ProjectSupport.star) } label: {
                    Label(L10n.text("support.star.action"), systemImage: "star")
                }
                .buttonStyle(.borderedProminent)
                Button(L10n.text("support.star.feature")) { NSWorkspace.shared.open(ProjectSupport.featureRequest) }
                Button(L10n.text("support.star.bug")) { NSWorkspace.shared.open(ProjectSupport.bugReport) }
            }
            row("support.share", symbol: "square.and.arrow.up.fill", tint: Color(red: 0.2, green: 0.66, blue: 0.45)) {
                ShareLink(item: ProjectSupport.repository, subject: Text(L10n.text("support.share.subject")),
                          message: Text(L10n.text("support.share.message"))) {
                    Text(L10n.text("support.share.action"))
                }
                Button(L10n.text(copied ? "support.share.copied" : "support.share.copy"), action: copyLink)
            }
            if !codes.isEmpty || !ProjectSupport.donationLinks.isEmpty {
                row("support.coffee", symbol: "cup.and.saucer.fill", tint: Color(red: 0.62, green: 0.42, blue: 0.27)) {
                    ForEach(codes, id: \.titleKey) { SupportCodeButton(code: $0) }
                    ForEach(ProjectSupport.donationLinks, id: \.url) { link in
                        Button { NSWorkspace.shared.open(link.url) } label: {
                            Label(link.title, systemImage: "cup.and.saucer")
                        }
                    }
                }
            }
        }
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

    private func row<Actions: View>(_ key: String, symbol: String, tint: Color, @ViewBuilder actions: () -> Actions) -> some View {
        HStack(alignment: .top, spacing: 12) {
            SettingsIconTile(symbol: symbol, tint: tint)
            VStack(alignment: .leading, spacing: 6) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(L10n.text(key + ".title"))
                    Text(L10n.text(key + ".detail")).font(.system(size: 11)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                HStack(spacing: 8) { actions() }
            }
        }
        .padding(.vertical, 2)
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
            Label(L10n.text(code.titleKey), systemImage: "qrcode")
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
