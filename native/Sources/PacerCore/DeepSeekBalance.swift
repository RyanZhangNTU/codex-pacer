import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// The DeepSeek platform wallet in CNY. Granted credit is spent first.
public struct DeepSeekBalance: Equatable, Sendable {
    public enum Source: String, Sendable { case web, apiKey }
    public let total: Double
    public let granted: Double?
    /// False when the platform reports that requests can no longer be paid.
    public let available: Bool
    /// The platform's own estimate of the tokens the balance buys (web only).
    public let tokenEstimation: Double?
    /// The alert line set on the platform, when enabled there (web only).
    public let alertBound: Double?
    public let capturedAt: Date
    public let source: Source
    /// The existing page-token digest, kept only in memory until HMAC binding.
    public let sessionFingerprint: String?
    public init(total: Double, granted: Double? = nil, available: Bool = true, tokenEstimation: Double? = nil,
                alertBound: Double? = nil, capturedAt: Date, source: Source, sessionFingerprint: String? = nil) {
        self.total = total; self.granted = granted; self.available = available; self.tokenEstimation = tokenEstimation
        self.alertBound = alertBound; self.capturedAt = capturedAt; self.source = source; self.sessionFingerprint = sessionFingerprint
    }
    public var isExhausted: Bool { !available || total <= 0.005 }
    public func isStale(at now: Date) -> Bool { now.timeIntervalSince(capturedAt) > 600 }

    public static func sessionIdentity(_ raw: Any?) -> String? {
        guard let value = raw as? String, value.utf8.count == 64,
              value.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else { return nil }
        return value
    }

    static func amount(_ value: Any?) -> Double? {
        let number: Double?
        switch value {
        case let text as String: number = Double(text.trimmingCharacters(in: .whitespaces))
        case let value as NSNumber: number = value.doubleValue
        default: number = nil
        }
        return number.flatMap { $0.isFinite && $0 >= 0 && $0 < 1e9 ? $0 : nil }
    }

    /// `GET /user/balance`: `{is_available, balance_infos: [{currency, total_balance, granted_balance}]}`.
    public static func api(_ data: Data, at date: Date = Date()) throws -> Self {
        guard data.count <= 64 * 1024, let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let infos = object["balance_infos"] as? [[String: Any]] else { throw DeepSeekBalanceError.invalidReply }
        guard let wallet = infos.first(where: { ($0["currency"] as? String)?.uppercased() == "CNY" }) else {
            throw infos.isEmpty ? DeepSeekBalanceError.invalidReply : DeepSeekBalanceError.unsupportedCurrency
        }
        guard let total = amount(wallet["total_balance"]) else { throw DeepSeekBalanceError.invalidReply }
        return Self(total: total, granted: amount(wallet["granted_balance"]), available: object["is_available"] as? Bool ?? (total > 0),
            capturedAt: date, source: .apiKey)
    }

    /// The numbers the platform page's own summary request returned, already
    /// reduced inside the page to wallets in CNY, an estimate and the alert line.
    public static func web(_ reply: [String: Any], at date: Date = Date()) throws -> Self {
        switch reply["state"] as? String {
        case "signedOut": throw DeepSeekBalanceError.signedOut
        case "challenge": throw DeepSeekBalanceError.challenge
        case "ok": break
        default: throw DeepSeekBalanceError.invalidReply
        }
        let fingerprint: String?
        if let raw = reply["sessionFingerprint"] {
            guard let verified = sessionIdentity(raw) else { throw DeepSeekBalanceError.invalidReply }
            fingerprint = verified
        } else { fingerprint = nil }
        let normal = (reply["normal"] as? [Any] ?? []).compactMap(amount), bonus = (reply["bonus"] as? [Any] ?? []).compactMap(amount)
        guard !(normal.isEmpty && bonus.isEmpty) else {
            throw reply["otherCurrency"] as? Bool == true ? DeepSeekBalanceError.unsupportedCurrency : DeepSeekBalanceError.invalidReply
        }
        let total = normal.reduce(0, +) + bonus.reduce(0, +)
        let alert = reply["alertEnabled"] as? Bool == true ? amount(reply["alertBound"]) : nil
        return Self(total: total, granted: bonus.reduce(0, +), available: total > 0, tokenEstimation: amount(reply["estimation"]),
            alertBound: alert, capturedAt: date, source: .web, sessionFingerprint: fingerprint)
    }
}

public enum DeepSeekBalanceError: Error, LocalizedError, Equatable {
    case signedOut, missingKey, invalidKey, challenge, unsupportedCurrency, invalidReply, connectionFailed, unavailable
    public var errorDescription: String? {
        switch self {
        case .signedOut: L10n.text("deepseek.balance.signed_out")
        case .missingKey: L10n.text("deepseek.balance.missing_key")
        case .invalidKey: L10n.text("deepseek.balance.invalid_key")
        case .challenge: L10n.text("deepseek.balance.challenge")
        case .unsupportedCurrency: L10n.text("deepseek.balance.currency")
        case .invalidReply: L10n.text("deepseek.balance.invalid_reply")
        case .connectionFailed: L10n.text("deepseek.balance.connection_failed")
        case .unavailable: L10n.text("deepseek.balance.unavailable")
        }
    }
    /// Signing in again or replacing the key is the only fix.
    public var needsConnection: Bool { [.signedOut, .missingKey, .invalidKey, .challenge].contains(self) }
}

/// A user-supplied balance key. Storage is supplied by the host.
public struct DeepSeekAPIKeyStore: Sendable {
    private let store: any PlatformCredentialStore
    public init(store: any PlatformCredentialStore) { self.store = store }
    public static func validated(_ raw: String) -> String? {
        let key = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard key.utf8.count >= 16, key.utf8.count <= 256,
              key.range(of: #"^[A-Za-z0-9._-]+\z"#, options: .regularExpression) != nil else { return nil }
        return key
    }
    public func read() -> String? {
        store.read().flatMap { String(data: $0, encoding: .utf8) }.flatMap(Self.validated)
    }
    public var hasKey: Bool { store.exists }
    @discardableResult public func save(_ raw: String) -> Bool {
        guard let key = Self.validated(raw) else { return false }
        return store.save(Data(key.utf8))
    }
    public func remove() { store.remove() }
}

public enum DeepSeekAPIBalanceClient {
    static let endpoint = URL(string: "https://api.deepseek.com/user/balance")!
    public static func read(key: String, session: URLSession = .shared, now: @Sendable () -> Date = { Date() }) async throws -> DeepSeekBalance {
        var request = URLRequest(url: endpoint, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        request.setValue("Bearer " + key, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let data: Data, response: URLResponse
        do { (data, response) = try await session.data(for: request) } catch { throw DeepSeekBalanceError.connectionFailed }
        switch (response as? HTTPURLResponse)?.statusCode ?? 0 {
        case 200: return try DeepSeekBalance.api(data, at: now())
        case 401, 403: throw DeepSeekBalanceError.invalidKey
        case 402: throw DeepSeekBalanceError.unavailable
        default: throw DeepSeekBalanceError.connectionFailed
        }
    }
}
