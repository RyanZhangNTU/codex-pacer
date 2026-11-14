import AppKit
import CryptoKit
import PacerCore
import SwiftUI
import WebKit

/// One module's account credits, read from its bill through Pacer's own web
/// profile for the chosen site. The registry describes the sites, the sign-in
/// page and the summary script; nothing here names a service.
@MainActor final class HarnessAccountConnection: ObservableObject {
    let provider: AgentProvider
    /// The last bill read, kept through a failed refresh so the bar dims it.
    @Published private(set) var credits: HarnessAccountCredits?
    @Published private(set) var reading: HarnessAccountCredits.Reading?
    @Published private(set) var state: HarnessAccountCredits.State = .signIn
    @Published private(set) var busy = false
    /// Called on the main actor after every change to the credits or state.
    var onChange: (() -> Void)?
    /// Called when the user signs out or switches accounts: the next reading
    /// may belong to someone else, so earlier notices no longer apply.
    var onAccountReset: (() -> Void)?

    private let definition: HarnessAccountCreditsDefinition
    private var enabled = false
    private var site: HarnessAccountCreditsDefinition.Site
    private var operation: Task<Void, Never>?
    private var scheduled: Task<Void, Never>?
    private var login: HarnessAccountLogin?
    private var revision = 0
    private let defaults: UserDefaults

    init(provider: AgentProvider, definition: HarnessAccountCreditsDefinition, defaults: UserDefaults) {
        self.provider = provider; self.definition = definition; self.defaults = defaults
        site = definition.site("automatic", chinese: false)
    }

    /// The site in use, as its preference value.
    var siteID: String { site.id }
    var siteHost: String { site.url.host ?? "" }
    private var key: String { provider.rawValue + "AccountConnected." + site.id }
    /// One profile per module and site, so signing out of one leaves the others.
    private var dataStore: WKWebsiteDataStore {
        let digest = Array(SHA256.hash(data: Data(("pacer-account|" + provider.rawValue + "|" + site.id).utf8)))
        let uuid = UUID(uuid: (digest[0], digest[1], digest[2], digest[3], digest[4], digest[5], digest[6] & 0x0f | 0x40, digest[7],
                               digest[8] & 0x3f | 0x80, digest[9], digest[10], digest[11], digest[12], digest[13], digest[14], digest[15]))
        return WKWebsiteDataStore(forIdentifier: uuid)
    }
    var signedIn: Bool { defaults.bool(forKey: key) || reading != nil }
    var canDisconnect: Bool { signedIn }

    func configure(enabled: Bool, site preference: String, chinese: Bool) {
        let next = definition.site(preference, chinese: chinese)
        guard self.enabled != enabled || site != next else { return }
        stop()
        site = next; self.enabled = enabled
        if enabled, defaults.bool(forKey: key) { refresh() }
    }

    func refresh() {
        guard enabled, !busy, defaults.bool(forKey: key) else { return }
        let origin = site.url, script = definition.summaryScript, store = dataStore
        begin { [weak self] current in
            guard let self else { return }
            let result = await HarnessAccountBrowserRead().read(origin: origin, script: script, store: store)
            guard revision == current, !Task.isCancelled else { return }
            apply(result)
        }
    }

    /// The window closes by itself once credits can be read. Switching
    /// accounts signs the current one out first, or it would read at once.
    func connect(switching: Bool = false) {
        guard enabled, !busy else { return }
        scheduled?.cancel(); scheduled = nil
        defaults.removeObject(forKey: key)
        update(nil, .signIn)
        if switching { onAccountReset?() }
        let store = dataStore
        let panel = HarnessAccountLogin(provider: provider, origin: site.url, loginPath: definition.loginPath,
                                        script: definition.summaryScript, store: store)
        login = panel
        begin { [weak self] current in
            guard let self else { return }
            if switching {
                await store.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast)
                guard revision == current, !Task.isCancelled else { return }
            }
            let result = await panel.signIn()
            guard revision == current, !Task.isCancelled else { return }
            login = nil
            if let result {
                defaults.set(true, forKey: key)
                apply(result)
            }
        }
    }

    func disconnect() {
        guard enabled, !busy else { return }
        scheduled?.cancel(); scheduled = nil
        defaults.removeObject(forKey: key)
        update(nil, .signIn)
        onAccountReset?()
        let store = dataStore
        begin { _ in
            await store.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast)
        }
    }

    func stop() {
        enabled = false; revision &+= 1
        operation?.cancel(); operation = nil
        scheduled?.cancel(); scheduled = nil
        login?.close(); login = nil
        busy = false; update(nil, .signIn)
    }

    /// Demo credits, with no account behind them.
    func showDemo(_ demo: HarnessAccountCredits?) {
        stop()
        update(demo?.reading() == nil ? nil : demo, demo?.reading() == nil ? .signIn : .ready)
    }

    private func begin(_ body: @escaping @MainActor (Int) async -> Void) {
        guard operation == nil else { return }
        busy = true
        let current = revision
        operation = Task { @MainActor [weak self] in
            await body(current)
            guard let self, revision == current else { return }
            operation = nil; busy = false
        }
    }

    private func apply(_ result: HarnessAccountCredits?) {
        if result?.reading() != nil { update(result, .ready) }
        // An expired session needs signing in again, so the button returns.
        else if result?.state == .signIn { defaults.removeObject(forKey: key); update(nil, .signIn) }
        // A failed read keeps the last bill, dimmed.
        else { update(credits, .unavailable) }
        schedule()
    }

    /// Publishes and reports a change only when the bill or state differs,
    /// so starting, stopping or a repeated read stays quiet.
    private func update(_ value: HarnessAccountCredits?, _ next: HarnessAccountCredits.State) {
        guard value != credits || next != state else { return }
        credits = value; reading = value?.reading(); state = next
        onChange?()
    }

    private func schedule() {
        scheduled?.cancel(); scheduled = nil
        guard enabled, state != .signIn, defaults.bool(forKey: key) else { return }
        let seconds = state == .ready ? 120 : 300
        scheduled = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            if !Task.isCancelled { self?.refresh() }
        }
    }
}

/// Same-origin blank reader, in an isolated content world. The site gets the
/// cookie set by the login window; native code gets just the credit reading.
@MainActor private final class HarnessAccountBrowserRead: NSObject, WKNavigationDelegate {
    private var view: WKWebView?
    private var origin = URL(fileURLWithPath: "/")
    private var script = ""
    private var reply: CheckedContinuation<HarnessAccountCredits?, Never>?
    private var deadline: Task<Void, Never>?

    func read(origin: URL, script: String, store: WKWebsiteDataStore) async -> HarnessAccountCredits? {
        self.origin = origin; self.script = script
        let config = WKWebViewConfiguration(); config.websiteDataStore = store
        config.defaultWebpagePreferences.allowsContentJavaScript = false
        let browser = WKWebView(frame: .zero, configuration: config)
        view = browser; browser.navigationDelegate = self
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                reply = continuation
                if Task.isCancelled { finish(nil); return }
                deadline = Task { @MainActor [weak self] in
                    try? await Task.sleep(for: .seconds(20))
                    if !Task.isCancelled { self?.finish(nil) }
                }
                let csp = "default-src 'none'; connect-src https://" + (origin.host ?? "")
                browser.loadHTMLString("<!doctype html><meta http-equiv='Content-Security-Policy' content=\"\(csp)\"><title>Pacer</title>", baseURL: origin)
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.finish(nil) }
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        webView.callAsyncJavaScript(script, in: nil, in: .defaultClient) { [weak self] result in
            MainActor.assumeIsolated {
                guard let value = try? result.get(), JSONSerialization.isValidJSONObject(value),
                      let data = try? JSONSerialization.data(withJSONObject: value),
                      let credits = try? JSONDecoder().decode(HarnessAccountCredits.self, from: data) else {
                    self?.finish(nil); return
                }
                self?.finish(credits)
            }
        }
    }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) { finish(nil) }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: any Error) { finish(nil) }
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        let url = navigationAction.request.url
        decisionHandler(url == origin || url?.absoluteString == "about:blank" ? .allow : .cancel)
    }
    private func finish(_ credits: HarnessAccountCredits?) {
        deadline?.cancel(); deadline = nil
        view?.navigationDelegate = nil; view?.stopLoading(); view = nil
        reply?.resume(returning: credits); reply = nil
    }
}

/// The sign-in window, like Claude's and DeepSeek's: the shared banner above
/// the site's page. Credits are read through the window's own profile every
/// few seconds, wherever the page has gone (a QR or third-party step included),
/// and the first reading confirms the sign-in and closes the window.
@MainActor private final class HarnessAccountLogin: NSObject, NSWindowDelegate, WKNavigationDelegate, WKUIDelegate {
    private static let checkInterval: Duration = .seconds(3)
    private let provider: AgentProvider
    private let origin: URL
    private let loginPath: String
    private let script: String
    private let store: WKWebsiteDataStore
    private let banner = WebLoginBannerState()
    private var window: NSWindow?
    private var browser: WKWebView?
    private var popups: [NSWindow] = []
    private var result: CheckedContinuation<HarnessAccountCredits?, Never>?
    private var polling: Task<Void, Never>?
    private var autoClose: Task<Void, Never>?
    private var signedIn: HarnessAccountCredits?

    init(provider: AgentProvider, origin: URL, loginPath: String, script: String, store: WKWebsiteDataStore) {
        self.provider = provider; self.origin = origin; self.loginPath = loginPath; self.script = script; self.store = store
    }

    private var loginURL: URL { origin.appendingPathComponent(loginPath) }

    func signIn() async -> HarnessAccountCredits? {
        await withCheckedContinuation { continuation in
            result = continuation
            let config = WKWebViewConfiguration(); config.websiteDataStore = store
            let page = WKWebView(frame: .zero, configuration: config)
            page.navigationDelegate = self; page.uiDelegate = self; browser = page
            let family = provider.rawValue + ".login."
            let copy = WebLoginBanner.Copy(prompt: L10n.text(family + "prompt"), promptDetail: L10n.text(family + "prompt_detail"),
                signedIn: L10n.text(family + "signed_in"), signedInDetail: L10n.text(family + "signed_in_detail"))
            let strip = NSHostingView(rootView: WebLoginBanner(provider: provider, copy: copy, state: banner,
                onReload: { [weak self] in self?.reloadPage() },
                onLater: { [weak self] in self?.window?.performClose(nil) },
                onDone: { [weak self] in self?.finish() }))
            let panel = makeWindow()
            panel.contentView = NSView.webLoginContainer(banner: strip, page: page)
            window = panel
            polling = Task { @MainActor [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: Self.checkInterval)
                    guard let self, !Task.isCancelled else { return }
                    await self.check()
                }
            }
            page.load(URLRequest(url: loginURL))
            panel.center(); panel.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
        }
    }
    func close() { window?.close() }

    private func makeWindow() -> NSWindow {
        let available = NSScreen.main?.visibleFrame.size ?? CGSize(width: 1024, height: 900)
        let frame = CGRect(x: 0, y: 0, width: min(760, max(420, available.width - 80)), height: min(720, max(400, available.height - 100)))
        let panel = NSWindow(contentRect: frame, styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        panel.title = title(host: origin.host)
        panel.minSize = CGSize(width: 420, height: 400)
        panel.isReleasedWhenClosed = false; panel.delegate = self
        return panel
    }
    private func title(host: String?) -> String { L10n.text(provider.rawValue + ".login.title") + " · " + (host ?? "") }

    private func reloadPage() {
        guard let browser else { return }
        if banner.phase == .loadFailed { banner.phase = .prompt }
        // A failed first load leaves nothing to reload.
        if browser.url == nil { browser.load(URLRequest(url: loginURL)) } else { browser.reload() }
    }

    /// One reading through the window's profile; the first one that has
    /// credits shows the confirmation, then closes the window shortly after.
    private func check() async {
        guard window != nil, signedIn == nil else { return }
        let credits = await HarnessAccountBrowserRead().read(origin: origin, script: script, store: store)
        guard window != nil, signedIn == nil, let credits, credits.reading() != nil else { return }
        signedIn = credits
        banner.phase = .signedIn
        polling?.cancel(); polling = nil
        autoClose = Task { @MainActor [weak self] in
            try? await Task.sleep(for: WebLoginBanner.autoCloseDelay)
            guard !Task.isCancelled else { return }
            self?.finish()
        }
    }

    /// Done and the automatic close return the confirmed reading; closing
    /// the window before one returns nothing.
    private func finish() {
        guard let credits = signedIn else { return }
        result?.resume(returning: credits); result = nil
        close()
    }

    func windowWillClose(_ notification: Notification) {
        guard let closing = notification.object as? NSWindow else { return }
        if closing !== window { popups.removeAll { $0 === closing }; return }
        polling?.cancel(); polling = nil
        autoClose?.cancel(); autoClose = nil
        for popup in popups { popup.delegate = nil; popup.close() }
        popups.removeAll()
        browser?.stopLoading(); browser?.navigationDelegate = nil; browser?.uiDelegate = nil; browser = nil
        window = nil
        result?.resume(returning: nil); result = nil
    }
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        let scheme = navigationAction.request.url?.scheme?.lowercased()
        decisionHandler(scheme == "https" || scheme == "about" ? .allow : .cancel)
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard webView === browser else { return }
        window?.title = title(host: webView.url?.host ?? origin.host)
    }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: any Error) {
        guard webView === browser, banner.phase == .prompt, (error as NSError).code != NSURLErrorCancelled else { return }
        banner.phase = .loadFailed
    }
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        guard popups.count < 4, navigationAction.request.url?.scheme == "https" else { return nil }
        let panel = makeWindow(), page = WKWebView(frame: .zero, configuration: configuration)
        page.navigationDelegate = self; page.uiDelegate = self
        panel.contentView = page; popups.append(panel); panel.makeKeyAndOrderFront(nil)
        return page
    }
    func webViewDidClose(_ webView: WKWebView) { webView.window?.close() }
}
