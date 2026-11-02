import Foundation

/// The saved balance choice is distinct from Harness's current billing mode.
public enum DeepSeekBalanceSelection: String, Codable, CaseIterable, Identifiable, Sendable {
    case automatic, web, apiKey
    public var id: String { rawValue }
    public func mode(detected: DeepSeekAuthMode?) -> DeepSeekAuthMode? {
        switch self { case .automatic: detected; case .web: .account; case .apiKey: .apiKey }
    }
}

/// The original connection row, without a key, account identity or source path.
public struct DeepSeekConnectionPresentation: Codable, Equatable, Sendable {
    public let title: String, text: String, color: String, detectedText: String
    public let connected: Bool, keyEditor: Bool, showDetection: Bool
    public let action: String?, actionLabel: String?
    public init(source: DeepSeekBalanceSelection, detected: DeepSeekAuthMode?, balance: DeepSeekBalance?,
                error: DeepSeekBalanceError?, refreshing: Bool, now: Date) {
        let mode = source.mode(detected: detected), web = mode != .apiKey
        connected = balance != nil && error?.needsConnection != true
        keyEditor = !web; showDetection = source != .automatic || balance == nil
        title = L10n.text(web ? "deepseek.platform_account" : "deepseek.api_key")
        let age = max(0, Int(now.timeIntervalSince(balance?.capturedAt ?? now)))
        let freshness = age < 10 ? L10n.text("quota.just_updated") : age < 60 ? L10n.text("quota.seconds_ago", age) : L10n.text("quota.minutes_ago", age / 60)
        if connected { text = L10n.text("deepseek.connected", freshness); color = "green" }
        else if refreshing { text = L10n.text("claude.account.checking"); color = "secondary" }
        else if error?.needsConnection == true || error == nil { text = L10n.text(web ? "deepseek.signed_out" : "deepseek.no_key"); color = "orange" }
        else { text = error?.localizedDescription ?? L10n.text("deepseek.balance.unavailable"); color = "orange" }
        let found = detected.map { L10n.text($0 == .account ? "deepseek.detected.account" : "deepseek.detected.api") } ?? L10n.text("deepseek.detected.unknown")
        detectedText = source == .automatic ? found : L10n.text("deepseek.detected.overridden", found)
        if web && !connected { action = "signIn"; actionLabel = L10n.text("deepseek.sign_in") }
        else if !web && (error != nil || connected) { action = "refresh"; actionLabel = L10n.text("common.refresh") }
        else { action = nil; actionLabel = nil }
    }
}

/// The unchanged Mac status beneath a time/budget dial. Connection errors
/// use the dial's sign-in/key action; transient reads keep Retry and Settings.
public struct DeepSeekBalanceStatusPresentation: Codable, Equatable, Sendable {
    public enum Tone: String, Codable, Sendable { case secondary, attention }
    public let message: String
    public let tone: Tone
    public let actions: [QuotaConnectionPresentation.Action]

    public init?(error: DeepSeekBalanceError?, refreshing: Bool) {
        guard let error else { return nil }
        message = error.errorDescription ?? ""
        tone = error.needsConnection ? .secondary : .attention
        actions = error.needsConnection ? [] : [
            .init(kind: .retry, title: L10n.text(refreshing ? "common.retrying" : "common.retry"), enabled: !refreshing),
            .init(kind: .settings, title: L10n.text("common.settings"), enabled: true)
        ]
    }
}
