import Foundation
import Security

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
    public init(total: Double, granted: Double? = nil, available: Bool = true, tokenEstimation: Double? = nil,
                alertBound: Double? = nil, capturedAt: Date, source: Source) {
        self.total = total; self.granted = granted; self.available = available; self.tokenEstimation = tokenEstimation
        self.alertBound = alertBound; self.capturedAt = capturedAt; self.source = source
    }
    public var isExhausted: Bool { !available || total <= 0.005 }
    public func isStale(at now: Date) -> Bool { now.timeIntervalSince(capturedAt) > 600 }

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
        let normal = (reply["normal"] as? [Any] ?? []).compactMap(amount), bonus = (reply["bonus"] as? [Any] ?? []).compactMap(amount)
        guard !(normal.isEmpty && bonus.isEmpty) else {
            throw reply["otherCurrency"] as? Bool == true ? DeepSeekBalanceError.unsupportedCurrency : DeepSeekBalanceError.invalidReply
        }
        let total = normal.reduce(0, +) + bonus.reduce(0, +)
        let alert = reply["alertEnabled"] as? Bool == true ? amount(reply["alertBound"]) : nil
        return Self(total: total, granted: bonus.reduce(0, +), available: total > 0, tokenEstimation: amount(reply["estimation"]),
            alertBound: alert, capturedAt: date, source: .web)
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

/// A key pasted into Pacer, kept in Pacer's own login-keychain item. It is
/// sent only to the balance endpoint and never written to preferences or logs.
public enum DeepSeekAPIKeyStore {
    static let service = "Codex Pacer DeepSeek balance"
    static let account = "api-key"
    private static var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
    }
    public static func validated(_ raw: String) -> String? {
        let key = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard key.utf8.count >= 16, key.utf8.count <= 256,
              key.range(of: #"^[A-Za-z0-9._-]+\z"#, options: .regularExpression) != nil else { return nil }
        return key
    }
    public static func read() -> String? {
        var request = query
        request[kSecReturnData as String] = true; request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(request as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8).flatMap(validated)
    }
    public static var exists: Bool {
        var request = query; request[kSecReturnAttributes as String] = true
        return SecItemCopyMatching(request as CFDictionary, nil) == errSecSuccess
    }
    @discardableResult public static func save(_ raw: String) -> Bool {
        guard let key = validated(raw) else { return false }
        let data = Data(key.utf8)
        let update = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if update == errSecSuccess { return true }
        guard update == errSecItemNotFound else { return false }
        var item = query
        item[kSecValueData as String] = data; item[kSecAttrLabel as String] = "Codex Pacer DeepSeek balance key"
        return SecItemAdd(item as CFDictionary, nil) == errSecSuccess
    }
    public static func remove() { _ = SecItemDelete(query as CFDictionary) }
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
