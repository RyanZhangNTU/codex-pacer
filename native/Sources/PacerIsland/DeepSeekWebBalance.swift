import AppKit
import PacerCore
import WebKit

/// Pacer's own WebKit profile for platform.deepseek.com. The sign-in token
/// stays in the page's storage; Swift receives only the wallet numbers.
@MainActor
enum DeepSeekWebSessionStore {
    static let profileIdentifier = UUID(uuidString: "5B0E7A43-3C1D-4E0A-9D5B-2F0C6B8E4D71")!
    static let dataStore = WKWebsiteDataStore(forIdentifier: profileIdentifier)
    static let origin = URL(string: "https://platform.deepseek.com/")!

    /// Signing out removes the profile's site data; nothing else is stored.
    static func signOut() async {
        let types = WKWebsiteDataStore.allWebsiteDataTypes()
        await dataStore.removeData(ofTypes: types, modifiedSince: .distantPast)
    }

    /// Runs in Pacer's isolated script world on a blank same-origin document,
    /// so page scripts never run and cannot observe the request.
    static let summaryScript = #"""
    const stored = (key) => {
      const raw = localStorage.getItem(key);
      if (raw == null) return null;
      try { const value = JSON.parse(raw); return value && typeof value === 'object' && 'value' in value ? value.value : value; }
      catch (error) { return raw; }
    };
    const token = stored('userToken');
    if (typeof token !== 'string' || token.length < 8) return { state: 'signedOut' };
    let response;
    try {
      response = await fetch('/api/v0/users/get_user_summary', { credentials: 'include', cache: 'no-store',
        headers: { 'Authorization': 'Bearer ' + token, 'x-client-platform': 'web', 'x-client-version': '1.0.0' } });
    } catch (error) { return { state: 'offline' }; }
    if (response.headers.get('x-amzn-waf-action')) return { state: 'challenge' };
    if (response.status === 401) return { state: 'signedOut' };
    let body;
    try { body = await response.json(); } catch (error) { return { state: 'invalid' }; }
    const code = body && (body.code || (body.data && body.data.biz_code));
    if (code === 40002 || code === 40003) return { state: 'signedOut' };
    const data = body && body.data && body.data.biz_data;
    if (!data) return { state: 'invalid' };
    const wallets = (list) => (Array.isArray(list) ? list : []);
    const cny = (list) => wallets(list).filter((w) => w && w.currency === 'CNY').map((w) => String(w.balance));
    const other = wallets(data.normal_wallets).concat(wallets(data.bonus_wallets)).some((w) => w && w.currency && w.currency !== 'CNY');
    const info = stored('__appKit_userInfo');
    const alert = info && info.balanceAlert && info.balanceAlert.CNY;
    return { state: 'ok', normal: cny(data.normal_wallets), bonus: cny(data.bonus_wallets), otherCurrency: other,
      estimation: data.total_available_token_estimation == null ? null : String(data.total_available_token_estimation),
      alertEnabled: !!(alert && alert.enabled), alertBound: alert && alert.alertBound != null ? String(alert.alertBound) : null };
    """#

    static let signedInScript = #"""
    const raw = localStorage.getItem('userToken');
    if (raw == null) return false;
    try { const value = JSON.parse(raw); return typeof (value && typeof value === 'object' ? value.value : value) === 'string'; }
    catch (error) { return raw.length > 8; }
    """#
}

/// One off-screen view, created for a read and released after it.
@MainActor
final class DeepSeekWebBalanceReader: NSObject, WKNavigationDelegate {
    private var webView: WKWebView?
    private var loaded: CheckedContinuation<Bool, Never>?

    func read(now: Date = Date()) async throws -> DeepSeekBalance {
        defer { release() }
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = DeepSeekWebSessionStore.dataStore
        let view = WKWebView(frame: CGRect(x: 0, y: 0, width: 320, height: 240), configuration: configuration)
        view.navigationDelegate = self
        webView = view
        let ready = await withCheckedContinuation { continuation in
            loaded = continuation
            view.loadHTMLString("<!doctype html><title>Pacer</title>", baseURL: DeepSeekWebSessionStore.origin)
        }
        guard ready else { throw DeepSeekBalanceError.connectionFailed }
        let result: Any?
        do { result = try await view.callAsyncJavaScript(DeepSeekWebSessionStore.summaryScript, contentWorld: .defaultClient) }
        catch { throw DeepSeekBalanceError.connectionFailed }
        guard let reply = result as? [String: Any] else { throw DeepSeekBalanceError.invalidReply }
        if reply["state"] as? String == "offline" { throw DeepSeekBalanceError.connectionFailed }
        return try DeepSeekBalance.web(reply, at: now)
    }

    private func release() {
        loaded?.resume(returning: false); loaded = nil
        webView?.stopLoading(); webView?.navigationDelegate = nil; webView = nil
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { loaded?.resume(returning: true); loaded = nil }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { loaded?.resume(returning: false); loaded = nil }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        loaded?.resume(returning: false); loaded = nil
    }
}

/// The ordinary platform sign-in page in Pacer's profile. Phone, email,
/// verification codes and third-party sign-in are all handled by the page.
@MainActor
final class DeepSeekWebLogin: NSObject, NSWindowDelegate, WKNavigationDelegate, WKUIDelegate {
    private static let shared = DeepSeekWebLogin()
    private var window: NSWindow?
    private var webView: WKWebView?
    private var popups: [ObjectIdentifier: (window: NSWindow, webView: WKWebView)] = [:]
    private var completions: [@MainActor () -> Void] = []
    private let address = NSTextField(labelWithString: "platform.deepseek.com")
    private let message = NSTextField(wrappingLabelWithString: "")
    private var checking = false
    static var isVisible: Bool { shared.window != nil }

    static func open(completion: @escaping @MainActor () -> Void) {
        shared.completions.append(completion)
        shared.show()
    }
    static func close() { shared.window?.close() }

    private func show() {
        if let window { window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true); return }
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = DeepSeekWebSessionStore.dataStore
        let browser = WKWebView(frame: .zero, configuration: configuration)
        browser.navigationDelegate = self; browser.uiDelegate = self
        browser.translatesAutoresizingMaskIntoConstraints = false
        webView = browser
        let panel = makeWindow(width: 760, height: 800)
        let container = NSView()
        address.font = .systemFont(ofSize: 12, weight: .medium); address.textColor = .secondaryLabelColor
        address.translatesAutoresizingMaskIntoConstraints = false
        message.stringValue = L10n.text("deepseek.login.instructions")
        message.font = .systemFont(ofSize: 12); message.textColor = .secondaryLabelColor
        message.translatesAutoresizingMaskIntoConstraints = false
        let proceed = NSButton(title: L10n.text("claude.login.continue"), target: self, action: #selector(continueAfterSignIn))
        proceed.bezelStyle = .rounded; proceed.keyEquivalent = "\r"; proceed.keyEquivalentModifierMask = [.command]
        proceed.translatesAutoresizingMaskIntoConstraints = false
        for view in [address, browser, message, proceed] as [NSView] { container.addSubview(view) }
        NSLayoutConstraint.activate([
            address.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 18),
            address.topAnchor.constraint(equalTo: container.topAnchor, constant: 12),
            browser.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            browser.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            browser.topAnchor.constraint(equalTo: address.bottomAnchor, constant: 10),
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
        browser.load(URLRequest(url: URL(string: "https://platform.deepseek.com/usage")!))
        panel.center(); panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func makeWindow(width: CGFloat, height: CGFloat) -> NSWindow {
        let available = NSScreen.main?.visibleFrame.size ?? CGSize(width: 1024, height: 900)
        let frame = CGRect(x: 0, y: 0, width: min(width, max(420, available.width - 80)), height: min(height, max(400, available.height - 100)))
        let panel = NSWindow(contentRect: frame, styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        panel.title = L10n.text("deepseek.login.title")
        panel.minSize = CGSize(width: 420, height: 400)
        panel.isReleasedWhenClosed = false; panel.delegate = self
        return panel
    }

    @objc private func continueAfterSignIn() {
        guard let webView, !checking else { return }
        checking = true
        Task { @MainActor [weak self] in
            let signedIn = (try? await webView.callAsyncJavaScript(DeepSeekWebSessionStore.signedInScript, contentWorld: .defaultClient)) as? Bool
            guard let self, self.webView === webView else { return }
            self.checking = false
            guard signedIn == true else { self.message.stringValue = L10n.text("deepseek.login.instructions"); return }
            let callbacks = self.completions
            self.completions.removeAll()
            self.window?.close()
            callbacks.forEach { $0() }
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        if webView === self.webView { address.stringValue = webView.url?.host ?? "platform.deepseek.com" }
    }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        if webView === self.webView, (error as NSError).code != NSURLErrorCancelled { message.stringValue = L10n.text("claude.login.load_failed") }
    }
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let scheme = navigationAction.request.url?.scheme?.lowercased(), ["https", "about"].contains(scheme) else {
            decisionHandler(.cancel); return
        }
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
        return browser
    }
    func webViewDidClose(_ webView: WKWebView) {
        if webView === self.webView { window?.close() } else { popups[ObjectIdentifier(webView)]?.window.close() }
    }
    func windowWillClose(_ notification: Notification) {
        guard let closing = notification.object as? NSWindow else { return }
        if closing === window {
            for child in Array(popups.values) { child.window.close() }
            popups.removeAll()
            webView?.stopLoading(); webView?.navigationDelegate = nil; webView?.uiDelegate = nil
            closing.contentView = nil
            webView = nil; window = nil; completions.removeAll(); checking = false
        } else if let key = popups.first(where: { $0.value.window === closing })?.key, let child = popups.removeValue(forKey: key) {
            child.webView.stopLoading(); child.webView.navigationDelegate = nil; child.webView.uiDelegate = nil
            closing.contentView = nil
        }
    }
}
