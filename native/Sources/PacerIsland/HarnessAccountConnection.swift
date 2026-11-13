import AppKit
import PacerCore
import SwiftUI
import WebKit

@MainActor final class HarnessAccountConnection: ObservableObject {
    @Published private(set) var reading: HarnessAccountCredits.Reading?
    @Published private(set) var state: HarnessAccountCredits.State = .signIn
    @Published private(set) var busy = false

    private var enabled = false
    private var origin = WorkBuddyAccountWeb.international
    private var operation: Task<Void, Never>?
    private var scheduled: Task<Void, Never>?
    private var login: HarnessAccountLogin?
    private var revision = 0
    private let defaults: UserDefaults

    init(defaults: UserDefaults) { self.defaults = defaults }

    private var key: String { "workbuddyAccountConnected." + (origin == WorkBuddyAccountWeb.china ? "china" : "international") }
    private var dataStore: WKWebsiteDataStore {
        WKWebsiteDataStore(forIdentifier: UUID(uuidString: origin == WorkBuddyAccountWeb.china
            ? "D6FC4CB6-9EF3-4F99-823E-E877E534641B" : "7200B491-3A3C-4328-BEDD-8F7BD1F93B0D")!)
    }
    var canDisconnect: Bool { defaults.bool(forKey: key) || reading != nil }

    func configure(enabled: Bool, china: Bool) {
        let site = china ? WorkBuddyAccountWeb.china : WorkBuddyAccountWeb.international
        guard self.enabled != enabled || origin != site else { return }
        stop()
        origin = site; self.enabled = enabled
        if enabled, defaults.bool(forKey: key) { refresh() }
    }

    func refresh() {
        guard enabled, !busy, defaults.bool(forKey: key) else { return }
        begin { [weak self] current in
            guard let self else { return }
            let result = await HarnessAccountBrowserRead().read(origin: origin, store: dataStore)
            guard revision == current, !Task.isCancelled else { return }
            apply(result)
        }
    }

    func connect() {
        guard enabled, !busy else { return }
        scheduled?.cancel(); scheduled = nil
        defaults.removeObject(forKey: key)
        reading = nil; state = .signIn
        let panel = HarnessAccountLogin(origin: origin, store: dataStore)
        login = panel
        begin { [weak self] current in
            guard let self else { return }
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
        reading = nil; state = .signIn
        begin { [weak self] _ in
            guard let self else { return }
            await dataStore.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast)
        }
    }

    func stop() {
        enabled = false; revision &+= 1
        operation?.cancel(); operation = nil
        scheduled?.cancel(); scheduled = nil
        login?.close(); login = nil
        busy = false; reading = nil; state = .signIn
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
        if let current = result?.reading() {
            reading = current; state = .ready
        } else if result?.state == .signIn {
            reading = nil; state = .signIn
        } else {
            state = .unavailable
        }
        schedule()
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
    private var origin = WorkBuddyAccountWeb.international
    private var reply: CheckedContinuation<HarnessAccountCredits?, Never>?
    private var deadline: Task<Void, Never>?

    func read(origin: URL, store: WKWebsiteDataStore) async -> HarnessAccountCredits? {
        self.origin = origin
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
        webView.callAsyncJavaScript(WorkBuddyAccountWeb.summaryScript, in: nil, in: .defaultClient) { [weak self] result in
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

@MainActor private final class HarnessAccountLogin: NSObject, NSWindowDelegate, WKNavigationDelegate, WKUIDelegate {
    private let origin: URL
    private let store: WKWebsiteDataStore
    private let label = NSTextField(wrappingLabelWithString: "")
    private let done = NSButton(title: L10n.text("login.done"), target: nil, action: nil)
    private var window: NSWindow?
    private var browser: WKWebView?
    private var popups: [NSWindow] = []
    private var result: CheckedContinuation<HarnessAccountCredits?, Never>?
    private var verification: Task<Void, Never>?

    init(origin: URL, store: WKWebsiteDataStore) { self.origin = origin; self.store = store }

    func signIn() async -> HarnessAccountCredits? {
        await withCheckedContinuation { continuation in
            result = continuation
            let config = WKWebViewConfiguration(); config.websiteDataStore = store
            let page = WKWebView(frame: .zero, configuration: config)
            page.navigationDelegate = self; page.uiDelegate = self; browser = page
            done.target = self; done.action = #selector(verify); done.bezelStyle = .rounded
            label.stringValue = L10n.text("windows.workbuddy.login.instructions")
            label.setContentHuggingPriority(.defaultLow, for: .horizontal)
            let strip = NSStackView(views: [label, done]); strip.orientation = .horizontal
            strip.edgeInsets = NSEdgeInsets(top: 12, left: 14, bottom: 12, right: 14)
            let panel = makeWindow()
            panel.contentView = NSView.webLoginContainer(banner: strip, page: page)
            window = panel
            page.load(URLRequest(url: origin.appendingPathComponent(WorkBuddyAccountWeb.loginPath)))
            panel.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
        }
    }
    func close() { window?.close() }
    private func makeWindow() -> NSWindow {
        let panel = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 680), styleMask: [.titled, .closable, .resizable],
                             backing: .buffered, defer: false)
        panel.title = L10n.text("workbuddy.login.title") + " · " + (origin.host ?? "")
        panel.isReleasedWhenClosed = false; panel.delegate = self; panel.center()
        return panel
    }
    @objc private func verify() {
        guard verification == nil else { return }
        done.isEnabled = false; label.stringValue = L10n.text("harness.account.reading")
        verification = Task { @MainActor [weak self] in
            guard let self else { return }
            let credits = await HarnessAccountBrowserRead().read(origin: origin, store: store)
            guard !Task.isCancelled, window != nil else { return }
            verification = nil; done.isEnabled = true
            if let credits, credits.reading() != nil {
                result?.resume(returning: credits); result = nil; close()
            } else { label.stringValue = L10n.text("harness.account.sign_in_again") }
        }
    }
    func windowWillClose(_ notification: Notification) {
        guard let closing = notification.object as? NSWindow else { return }
        if closing !== window { popups.removeAll { $0 === closing }; return }
        verification?.cancel(); verification = nil
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
        let panel = webView.window
        panel?.title = L10n.text("workbuddy.login.title") + " · " + (webView.url?.host ?? origin.host ?? "")
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
