import Foundation

public enum ClaudeQuotaCredentialCache {
    public static func location(home: URL, source: String) -> String {
        ClaudeQuotaDecoder.digest("pacer-claude-quota|" + source + "|" + home.standardizedFileURL.path)
    }

    public static func accountBinding(home: URL, account: String) -> String {
        ClaudeQuotaDecoder.digest("pacer-claude-account|" + home.standardizedFileURL.path + "|" + account.lowercased())
    }

    public static func decode(_ data: Data, accountBinding: String, expectedScope: String?, now: Date,
                       expectedCiphertextFingerprint: String? = nil) throws -> ClaudeOAuthCredential? {
        guard data.count <= 32_768, let value = try? ClaudeQuotaDecoder.dictionary(data),
              ClaudeQuotaDecoder.number(value["version"]) == 1,
              value["account_binding"] as? String == accountBinding,
              let scope = value["scope"] as? String, scope.count == 64, scope.allSatisfy(\.isHexDigit),
              expectedScope == nil || scope == expectedScope,
              expectedCiphertextFingerprint == nil || value["ciphertext_fingerprint"] as? String == expectedCiphertextFingerprint,
              let token = value["access_token"] as? String, ClaudeCredentialStore.validToken(token),
              let seconds = ClaudeQuotaDecoder.number(value["expires_at"]), seconds > 0,
              seconds < 253_402_300_800 else { return nil }
        let expiry = Date(timeIntervalSince1970: seconds)
        guard expiry > now else { throw ClaudeQuotaError.credentialsExpired }
        let plan = (value["plan"] as? String).flatMap { ["pro", "max", "team", "enterprise"].contains($0) ? $0 : nil }
        return ClaudeOAuthCredential(token: token, expiresAt: expiry, plan: plan, scope: scope)
    }

    public static func encode(_ credential: ClaudeOAuthCredential, accountBinding: String, now: Date,
                       ciphertextFingerprint: String? = nil) -> Data? {
        guard let expiry = credential.expiresAt, expiry > now, expiry.timeIntervalSince1970 < 253_402_300_800,
              ClaudeCredentialStore.validToken(credential.token),
              credential.scope.count == 64, credential.scope.allSatisfy(\.isHexDigit),
              accountBinding.count == 64, accountBinding.allSatisfy(\.isHexDigit) else { return nil }
        var value: [String: Any] = ["version": 1, "account_binding": accountBinding,
            "scope": credential.scope, "access_token": credential.token, "expires_at": expiry.timeIntervalSince1970]
        if let plan = credential.plan { value["plan"] = plan }
        if let ciphertextFingerprint {
            guard ciphertextFingerprint.count == 64, ciphertextFingerprint.allSatisfy(\.isHexDigit) else { return nil }
            value["ciphertext_fingerprint"] = ciphertextFingerprint
        }
        return try? JSONSerialization.data(withJSONObject: value)
    }

}
