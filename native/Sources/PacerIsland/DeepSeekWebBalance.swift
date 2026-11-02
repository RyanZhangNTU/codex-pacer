import AppKit
import PacerCore
import SwiftUI
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

    /// A SHA-256 digest of the page token, or null when signed out, so the
    /// login window can tell a new sign-in without Swift seeing the token.
    static let sessionFingerprintScript = #"""
    const raw = localStorage.getItem('userToken');
    if (raw == null) return null;
    let token = raw;
    try { const value = JSON.parse(raw); token = value && typeof value === 'object' ? value.value : value; } catch (error) {}
    if (typeof token !== 'string' || token.length < 8) return null;
    const digest = new Uint8Array(await crypto.subtle.digest('SHA-256', new TextEncoder().encode(token)));
    return Array.from(digest, (byte) => byte.toString(16).padStart(2, '0')).join('');
    """#
}

/// One off-screen view, created for a read and released after it.
@MainActor
final class DeepSeekWebBalanceReader: NSObject, WKNavigationDelegate {
    private var webView: WKWebView?
    private var loaded: CheckedContinuation<Bool, Never>?

    func read(now: Date = Date()) async throws -> DeepSeekBalance {
        let result = try await evaluate(DeepSeekWebSessionStore.summaryScript)
        guard let reply = result as? [String: Any] else { throw DeepSeekBalanceError.invalidReply }
        if reply["state"] as? String == "offline" { throw DeepSeekBalanceError.connectionFailed }
        return try DeepSeekBalance.web(reply, at: now)
    }

    /// The profile's token fingerprint wherever the visible page has navigated.
    func sessionFingerprint() async throws -> String? {
        try await evaluate(DeepSeekWebSessionStore.sessionFingerprintScript) as? String
    }

    private func evaluate(_ script: String) async throws -> Any? {
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
        do { return try await view.callAsyncJavaScript(script, contentWorld: .defaultClient) }
        catch { throw DeepSeekBalanceError.connectionFailed }
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
/// A new token in the profile shows the signed-in banner and closes the
/// window; closing it any other way still completes when a token is present.
@MainActor
final class DeepSeekWebLogin: NSObject, NSWindowDelegate, WKNavigationDelegate, WKUIDelegate {
    private static let shared = DeepSeekWebLogin()
    private static let loginURL = URL(string: "https://platform.deepseek.com/usage")!
    private var window: NSWindow?
    private var webView: WKWebView?
    private var popups: [ObjectIdentifier: (window: NSWindow, webView: WKWebView)] = [:]
    private var completions: [@MainActor (_ newSession: Bool) -> Void] = []
    private let banner = WebLoginBannerState()
    private var watch = WebLoginSessionWatch()
    private var polling: Task<Void, Never>?
    private var autoClose: Task<Void, Never>?
    private var checking = false
    private var finishing = false
    private var closeRequested = false
    private var loginGeneration = 0
    static var isVisible: Bool { shared.window != nil }

    /// `newSession` is false when the window closes on the token it opened
    /// with, so the same account keeps its balance history.
    static func open(completion: @escaping @MainActor (_ newSession: Bool) -> Void) {
        shared.completions.append(completion)
        shared.show()
    }
    static func close() { shared.window?.close() }

    private func show() {
        if let window { window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true); return }
        loginGeneration += 1
        watch = WebLoginSessionWatch(); banner.phase = .prompt
        checking = false; finishing = false; closeRequested = false
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = DeepSeekWebSessionStore.dataStore
        let browser = WKWebView(frame: .zero, configuration: configuration)
        browser.navigationDelegate = self; browser.uiDelegate = self
        webView = browser
        let panel = makeWindow(width: 760, height: 800)
        let copy = WebLoginBanner.Copy(prompt: L10n.text("deepseek.login.prompt"), promptDetail: L10n.text("deepseek.login.prompt_detail"),
            signedIn: L10n.text("deepseek.login.signed_in"), signedInDetail: L10n.text("deepseek.login.signed_in_detail"))
        let strip = NSHostingView(rootView: WebLoginBanner(provider: .deepseek, copy: copy, state: banner,
            onReload: { [weak self] in self?.reloadPage() },
            onLater: { [weak self] in self?.window?.performClose(nil) },
            onDone: { [weak self] in self?.finish(requiringSession: true) }))
        panel.contentView = NSView.webLoginContainer(banner: strip, page: browser)
        panel.title = Self.title(host: Self.loginURL.host)
        window = panel
        recordBaseline()
        // The page stores its token without necessarily navigating after
        // sign-in, so the open page is checked once a second.
        let generation = loginGeneration
        polling = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let self, self.loginGeneration == generation else { return }
                self.checkSession()
            }
        }
        browser.load(URLRequest(url: Self.loginURL))
        panel.center(); panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private static func title(host: String?) -> String {
        L10n.text("deepseek.login.title") + " · " + (host ?? "platform.deepseek.com")
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

    private func reloadPage() {
        guard let webView else { return }
        if banner.phase == .loadFailed { banner.phase = .prompt }
        // A failed first load leaves nothing to reload.
        if webView.url == nil { webView.load(URLRequest(url: Self.loginURL)) } else { webView.reload() }
    }

    /// The token at open is the baseline a new sign-in must differ from.
    private func recordBaseline() {
        let generation = loginGeneration
        Task { @MainActor [weak self] in
            let fingerprint: String?
            do { fingerprint = try await DeepSeekWebBalanceReader().sessionFingerprint() } catch { return }
            guard let self, self.loginGeneration == generation else { return }
            _ = self.watch.observe(fingerprint)
        }
    }

    /// Compares the open page's token with the baseline. Script failures and
    /// other origins, such as a third-party sign-in page, are skipped.
    private func checkSession() {
        guard let webView, !checking, !finishing, banner.phase != .signedIn,
              webView.url?.host == DeepSeekWebSessionStore.origin.host else { return }
        checking = true
        let generation = loginGeneration
        Task { @MainActor [weak self] in
            var fingerprint: String?, readable = true
            do {
                fingerprint = try await webView.callAsyncJavaScript(DeepSeekWebSessionStore.sessionFingerprintScript,
                    contentWorld: .defaultClient) as? String
            } catch { readable = false }
            guard let self, self.loginGeneration == generation else { return }
            self.checking = false
            guard readable, self.webView === webView, !self.finishing,
                  self.watch.observe(fingerprint), self.banner.phase != .signedIn else { return }
            self.banner.phase = .signedIn
            self.autoClose = Task { @MainActor [weak self] in
                try? await Task.sleep(for: WebLoginBanner.autoCloseDelay)
                guard let self, !Task.isCancelled, self.loginGeneration == generation else { return }
                self.finish(requiringSession: true)
            }
        }
    }

    /// A token present now completes the sign-in, as a new one when it
    /// differs from the token at open. Without one, Done keeps the window
    /// open, while closing it simply closes.
    private func finish(requiringSession: Bool) {
        guard window != nil, !finishing else { return }
        finishing = true
        let generation = loginGeneration
        Task { @MainActor [weak self] in
            // Read through the profile, wherever the page has navigated.
            let fingerprint = try? await DeepSeekWebBalanceReader().sessionFingerprint()
            guard let self, self.window != nil, self.loginGeneration == generation else { return }
            let outcome = self.watch.outcome(for: fingerprint)
            if outcome == .none, requiringSession, !self.closeRequested {
                self.finishing = false
                return
            }
            let callbacks = outcome == .none ? [] : self.completions
            self.completions.removeAll()
            self.window?.close()
            callbacks.forEach { $0(outcome == .new) }
        }
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard sender === window else { return true }
        closeRequested = true
        finish(requiringSession: false)
        return false
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        if webView === self.webView {
            window?.title = Self.title(host: webView.url?.host)
            if banner.phase == .loadFailed { banner.phase = .prompt }
            checkSession()
        }
        if let popup = popups[ObjectIdentifier(webView)] { popup.window.title = Self.title(host: webView.url?.host) }
    }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        if webView === self.webView, (error as NSError).code != NSURLErrorCancelled, banner.phase != .signedIn {
            banner.phase = .loadFailed
        }
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
            polling?.cancel(); polling = nil; autoClose?.cancel(); autoClose = nil
            loginGeneration += 1; checking = false; finishing = false; closeRequested = false
            for child in Array(popups.values) { child.window.close() }
            popups.removeAll()
            webView?.stopLoading(); webView?.navigationDelegate = nil; webView?.uiDelegate = nil
            closing.contentView = nil
            webView = nil; window = nil; completions.removeAll()
        } else if let key = popups.first(where: { $0.value.window === closing })?.key, let child = popups.removeValue(forKey: key) {
            child.webView.stopLoading(); child.webView.navigationDelegate = nil; child.webView.uiDelegate = nil
            closing.contentView = nil
        }
    }
}
