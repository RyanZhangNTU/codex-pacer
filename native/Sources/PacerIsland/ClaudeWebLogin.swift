import AppKit
import CryptoKit
import PacerCore
import WebKit

/// Pacer owns this WebKit profile. It never imports another app's cookies or
/// reads its encryption key; WebKit manages persistence inside this profile.
@MainActor
enum ClaudeWebSessionStore {
    static let profileIdentifier = UUID(uuidString: "92309D02-8D40-469B-A571-5C92D87B914C")!
    static let dataStore = WKWebsiteDataStore(forIdentifier: profileIdentifier)
    private static let userAgentKey = "claudeWebUserAgent"

    static func cookieHeader() async -> String? { (await session())?.cookieHeader }

    static func session() async -> ClaudeWebSession? {
        let cookies: [HTTPCookie] = await withCheckedContinuation { continuation in
            dataStore.httpCookieStore.getAllCookies { continuation.resume(returning: $0) }
        }
        return session(from: cookies)
    }

    /// The bridge retains only the bounded header and a one-way session scope.
    /// SSO provider cookies are never included in a claude.ai request.
    static func session(from cookies: [HTTPCookie], now: Date = Date()) -> ClaudeWebSession? {
        let allowed = cookies.filter { cookie in
            let domain = cookie.domain.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
            return domain == "claude.ai" && (cookie.expiresDate.map { $0 > now } ?? true) &&
                appliesToAPI(cookie.path) &&
                !cookie.name.isEmpty && cookie.name.utf8.count <= 256 && cookie.value.utf8.count <= 16_384 &&
                !cookie.name.contains(";") && !cookie.value.contains(";") &&
                !cookie.name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) &&
                !cookie.value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
        }.sorted {
            $0.path.count == $1.path.count ? $0.name < $1.name : $0.path.count > $1.path.count
        }
        guard allowed.count <= 64 else { return nil }
        let sessions = allowed.filter { $0.name == "sessionKey" && !$0.value.isEmpty }
        guard sessions.count == 1,
              let header = HTTPCookie.requestHeaderFields(with: allowed)["Cookie"],
              header.utf8.count <= 32_768 else { return nil }
        let scope = SHA256.hash(data: Data(sessions[0].value.utf8)).map { String(format: "%02x", $0) }.joined()
        let organization = allowed.first { $0.name == "lastActiveOrg" }
            .flatMap { UUID(uuidString: $0.value)?.uuidString.lowercased() }
        return ClaudeWebSession(cookieHeader: header, sessionHash: scope, organizationID: organization,
            userAgent: validatedUserAgent(UserDefaults.standard.string(forKey: userAgentKey)))
    }

    static func rememberUserAgent(_ value: String) {
        guard let value = validatedUserAgent(value) else { return }
        // Browser version metadata permits the same normal request context
        // after relaunch without retaining a loaded web view or a credential.
        UserDefaults.standard.set(value, forKey: userAgentKey)
    }

    private static func appliesToAPI(_ path: String) -> Bool {
        let requestPath = "/api/"
        guard !path.isEmpty, requestPath.hasPrefix(path) else { return false }
        return requestPath == path || path.hasSuffix("/") || requestPath.dropFirst(path.count).first == "/"
    }

    private static func validatedUserAgent(_ value: String?) -> String? {
        guard let value, value.utf8.count <= 512,
              value.range(of: #"^Mozilla/5\.0 \(Macintosh; (?:Intel|ARM|Apple Silicon) Mac OS X [0-9_.]+\) AppleWebKit/[0-9.]+ \(KHTML, like Gecko\)(?: Version/[0-9.]+)?(?: Safari/[0-9.]+)?$"#,
                options: .regularExpression) != nil else { return nil }
        return value
    }
}

/// Only an explicit sign-in action creates a web view. Closing the owned
/// window releases all views; the persistent cookie store remains available.
/// Keep the native Continue shortcut ahead of a focused WebKit responder.
/// Other chords still follow the ordinary window/content responder chain.
@MainActor
final class ClaudeLoginWindow: NSWindow {
    var onContinue: (@MainActor () -> Void)?

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting(.capsLock)
        guard event.type == .keyDown, event.keyCode == 36, modifiers == [.command], let onContinue else {
            return super.performKeyEquivalent(with: event)
        }
        onContinue()
        return true
    }
}

@MainActor
final class ClaudeWebLogin: NSObject, NSWindowDelegate, WKNavigationDelegate, WKUIDelegate {
    private static let shared = ClaudeWebLogin()
    private var window: NSWindow?
    private var webView: WKWebView?
    private var popups: [ObjectIdentifier: (window: NSWindow, webView: WKWebView)] = [:]
    private var completions: [@MainActor () -> Void] = []
    private let address = NSTextField(labelWithString: "claude.ai")
    private let message = NSTextField(wrappingLabelWithString: "")
    private var continueButton: NSButton?
    private var organizationWindow: NSWindow?
    private var organizationPicker: NSPopUpButton?
    private var organizationContinueButton: NSButton?
    private var organizationCompletion: (@MainActor (String) -> Void)?
    private var lastVisibility = false
    static var onVisibilityChange: (@MainActor (Bool) -> Void)?
    static var isVisible: Bool { shared.window != nil || shared.organizationWindow != nil }
    private var continuing = false
    private var loginGeneration = 0

    static func open(completion: @escaping @MainActor () -> Void) {
        shared.completions.append(completion)
        shared.show()
    }

    static func chooseOrganization(_ organizations: [ClaudeWebOrganization], completion: @escaping @MainActor (String) -> Void) {
        shared.showOrganizationPicker(organizations, completion: completion)
    }

    static func close() { shared.window?.close(); shared.organizationWindow?.close() }

    private func show() {
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        loginGeneration += 1
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = ClaudeWebSessionStore.dataStore
        let browser = WKWebView(frame: .zero, configuration: configuration)
        browser.navigationDelegate = self; browser.uiDelegate = self
        browser.translatesAutoresizingMaskIntoConstraints = false
        webView = browser
        recordUserAgent(from: browser)

        let panel = makeWindow(width: 760, height: 800, handlesLoginShortcut: true)
        let container = NSView()
        let header = NSStackView()
        header.orientation = .horizontal; header.spacing = 12
        header.translatesAutoresizingMaskIntoConstraints = false
        address.font = .systemFont(ofSize: 12, weight: .medium)
        address.textColor = .secondaryLabelColor
        let reload = NSButton(image: NSImage(systemSymbolName: "arrow.clockwise", accessibilityDescription: L10n.text("common.refresh"))!,
            target: self, action: #selector(reloadPage))
        reload.bezelStyle = .inline; reload.toolTip = L10n.text("common.refresh")
        header.addArrangedSubview(address); header.addArrangedSubview(NSView()); header.addArrangedSubview(reload)

        message.stringValue = L10n.text("claude.login.instructions")
        message.font = .systemFont(ofSize: 12); message.textColor = .secondaryLabelColor
        message.translatesAutoresizingMaskIntoConstraints = false
        let proceed = NSButton(title: L10n.text("claude.login.continue"), target: self, action: #selector(continueAfterSignIn))
        proceed.bezelStyle = .rounded
        proceed.keyEquivalent = "\r"; proceed.keyEquivalentModifierMask = [.command]
        proceed.toolTip = L10n.text("claude.login.continue_shortcut")
        proceed.translatesAutoresizingMaskIntoConstraints = false
        continueButton = proceed
        container.addSubview(header); container.addSubview(browser); container.addSubview(message); container.addSubview(proceed)
        NSLayoutConstraint.activate([
            header.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 18),
            header.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -18),
            header.topAnchor.constraint(equalTo: container.topAnchor, constant: 10),
            header.heightAnchor.constraint(equalToConstant: 24),
            browser.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            browser.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            browser.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 10),
            browser.bottomAnchor.constraint(equalTo: message.topAnchor, constant: -14),
            message.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 18),
            message.trailingAnchor.constraint(equalTo: proceed.leadingAnchor, constant: -16),
            message.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -16),
            proceed.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -18),
            proceed.centerYAnchor.constraint(equalTo: message.centerYAnchor),
            proceed.widthAnchor.constraint(greaterThanOrEqualToConstant: 88)
        ])
        panel.contentView = container
        window = panel
        browser.load(URLRequest(url: URL(string: "https://claude.ai/login")!))
        panel.center(); panel.makeKeyAndOrderFront(nil)
        publishVisibility()
        NSApp.activate(ignoringOtherApps: true)
    }

    private func makeWindow(width: CGFloat, height: CGFloat, handlesLoginShortcut: Bool = false) -> NSWindow {
        let available = NSScreen.main?.visibleFrame.size ?? CGSize(width: 1024, height: 900)
        let frame = CGRect(x: 0, y: 0,
            width: min(width, max(420, available.width - 80)), height: min(height, max(400, available.height - 100)))
        let style: NSWindow.StyleMask = [.titled, .closable, .miniaturizable, .resizable]
        let panel: NSWindow
        if handlesLoginShortcut {
            let login = ClaudeLoginWindow(contentRect: frame, styleMask: style, backing: .buffered, defer: false)
            login.onContinue = { [weak self] in self?.continueAfterSignIn() }
            panel = login
        } else {
            panel = NSWindow(contentRect: frame, styleMask: style, backing: .buffered, defer: false)
        }
        panel.title = L10n.text("claude.login.title")
        panel.minSize = CGSize(width: 420, height: 400)
        panel.isReleasedWhenClosed = false; panel.delegate = self
        return panel
    }

    @objc private func reloadPage() { webView?.reload() }

    private func recordUserAgent(from browser: WKWebView) {
        // Isolated client-world metadata cannot read or modify sign-in fields.
        browser.evaluateJavaScript("navigator.userAgent", in: nil, in: .defaultClient) { result in
            if case .success(let value) = result, let value = value as? String {
                ClaudeWebSessionStore.rememberUserAgent(value)
            }
        }
    }

    @objc private func continueAfterSignIn() {
        guard window != nil, !continuing else { return }
        continuing = true
        let generation = loginGeneration
        Task { @MainActor [weak self] in
            let session = await ClaudeWebSessionStore.session()
            guard let self, self.window != nil, self.loginGeneration == generation else { return }
            defer { if self.loginGeneration == generation { self.continuing = false } }
            guard session != nil else {
                self.message.stringValue = L10n.text("claude.login.instructions")
                return
            }
            let callbacks = self.completions
            self.completions.removeAll()
            self.window?.close()
            // Presence of an owned cookie is a candidate session. The quota
            // client independently verifies membership and the usage response.
            callbacks.forEach { $0() }
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        if webView === self.webView {
            address.stringValue = webView.url?.host ?? "claude.ai"
            message.stringValue = L10n.text("claude.login.instructions")
        }
        if let popup = popups[ObjectIdentifier(webView)] {
            popup.window.title = L10n.text("claude.login.title") + " · " + (webView.url?.host ?? "claude.ai")
        }
        recordUserAgent(from: webView)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        if webView === self.webView, (error as NSError).code != NSURLErrorCancelled {
            message.stringValue = L10n.text("claude.login.load_failed")
        }
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let scheme = navigationAction.request.url?.scheme?.lowercased(), ["https", "about"].contains(scheme) else {
            decisionHandler(.cancel); return
        }
        // HTTPS SSO redirects retain WebKit's normal certificate and security
        // checks. No custom authentication or certificate challenge handler.
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        guard window != nil, popups.count < 4 else { return nil }
        let browser = WKWebView(frame: .zero, configuration: configuration)
        browser.navigationDelegate = self; browser.uiDelegate = self
        let panel = makeWindow(width: 620, height: 740)
        browser.autoresizingMask = [.width, .height]
        panel.contentView = browser
        popups[ObjectIdentifier(browser)] = (panel, browser)
        panel.center(); panel.makeKeyAndOrderFront(nil)
        // WebKit loads the original request using its supplied configuration,
        // preserving the SSO opener and the same profile's cookie context.
        return browser
    }

    func webViewDidClose(_ webView: WKWebView) {
        if webView === self.webView { window?.close() }
        else { popups[ObjectIdentifier(webView)]?.window.close() }
    }

    private func showOrganizationPicker(_ organizations: [ClaudeWebOrganization], completion: @escaping @MainActor (String) -> Void) {
        let choices = organizations.filter { UUID(uuidString: $0.id) != nil }
        guard !choices.isEmpty else { return }
        organizationWindow?.close()
        let panel = makeWindow(width: 440, height: 220)
        panel.title = L10n.text("claude.login.organization_title")
        panel.styleMask.remove(.resizable); panel.minSize = CGSize(width: 440, height: 220)
        let container = NSView()
        let instructions = NSTextField(wrappingLabelWithString: L10n.text("claude.login.organization_instructions"))
        instructions.font = .systemFont(ofSize: 13); instructions.translatesAutoresizingMaskIntoConstraints = false
        let picker = NSPopUpButton(frame: .zero, pullsDown: false)
        picker.translatesAutoresizingMaskIntoConstraints = false
        picker.addItem(withTitle: L10n.text("claude.login.organization_placeholder"))
        picker.item(at: 0)?.isEnabled = false
        for (index, organization) in choices.enumerated() {
            let name = organization.name?.trimmingCharacters(in: .whitespacesAndNewlines)
            picker.addItem(withTitle: name?.isEmpty == false ? name! : L10n.text("claude.login.organization_number", index + 1))
            picker.lastItem?.representedObject = organization.id
        }
        picker.selectItem(at: 0)
        picker.target = self; picker.action = #selector(organizationChanged)
        let cancel = NSButton(title: L10n.text("common.cancel"), target: self, action: #selector(cancelOrganization))
        cancel.bezelStyle = .rounded; cancel.keyEquivalent = "\u{1b}"; cancel.translatesAutoresizingMaskIntoConstraints = false
        let proceed = NSButton(title: L10n.text("claude.login.continue"), target: self, action: #selector(continueWithOrganization))
        proceed.bezelStyle = .rounded; proceed.keyEquivalent = "\r"; proceed.isEnabled = false
        proceed.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(instructions); container.addSubview(picker); container.addSubview(cancel); container.addSubview(proceed)
        NSLayoutConstraint.activate([
            instructions.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 22),
            instructions.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -22),
            instructions.topAnchor.constraint(equalTo: container.topAnchor, constant: 20),
            picker.leadingAnchor.constraint(equalTo: instructions.leadingAnchor),
            picker.trailingAnchor.constraint(equalTo: instructions.trailingAnchor),
            picker.topAnchor.constraint(equalTo: instructions.bottomAnchor, constant: 18),
            proceed.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -22),
            proceed.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -18),
            cancel.trailingAnchor.constraint(equalTo: proceed.leadingAnchor, constant: -10),
            cancel.centerYAnchor.constraint(equalTo: proceed.centerYAnchor)
        ])
        panel.contentView = container
        organizationWindow = panel; organizationPicker = picker
        organizationContinueButton = proceed; organizationCompletion = completion
        panel.center(); panel.makeKeyAndOrderFront(nil); publishVisibility()
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func organizationChanged() {
        organizationContinueButton?.isEnabled = organizationPicker?.selectedItem?.representedObject is String
    }

    @objc private func cancelOrganization() { organizationWindow?.close() }

    @objc private func continueWithOrganization() {
        guard let identifier = organizationPicker?.selectedItem?.representedObject as? String,
              UUID(uuidString: identifier) != nil else { return }
        let completion = organizationCompletion
        organizationCompletion = nil; organizationWindow?.close()
        completion?(identifier)
    }

    private func publishVisibility() {
        let visible = Self.isVisible
        guard visible != lastVisibility else { return }
        lastVisibility = visible; Self.onVisibilityChange?(visible)
    }

    func windowWillClose(_ notification: Notification) {
        guard let closing = notification.object as? NSWindow else { return }
        if closing === window {
            (closing as? ClaudeLoginWindow)?.onContinue = nil
            loginGeneration += 1; continuing = false
            let children = Array(popups.values)
            for child in children { child.window.close() }
            popups.removeAll()
            webView?.stopLoading(); webView?.navigationDelegate = nil; webView?.uiDelegate = nil
            webView?.removeFromSuperview(); closing.contentView = nil
            webView = nil; window = nil; continueButton = nil; completions.removeAll()
        } else if let key = popups.first(where: { $0.value.window === closing })?.key,
                  let child = popups.removeValue(forKey: key) {
            child.webView.stopLoading(); child.webView.navigationDelegate = nil; child.webView.uiDelegate = nil
            closing.contentView = nil
        } else if closing === organizationWindow {
            closing.contentView = nil; organizationWindow = nil
            organizationPicker = nil; organizationContinueButton = nil; organizationCompletion = nil
        }
        publishVisibility()
    }
}
