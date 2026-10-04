import Foundation

/// Keep actionable errors while preventing credentials or account identifiers from entering the UI.
public enum CodexDiagnosticText {
    public static func sanitized(_ input: String, limit: Int = 1600) -> String {
        var text = String(input.prefix(16384))
        let replacements: [(String, String)] = [
            (#"\x1B\[[0-?]*[ -/]*[@-~]"#, ""),
            (#"(?i)\bBearer\s+[A-Za-z0-9._~+/=-]+"#, L10n.text("redaction.bearer")),
            (#"\bsk-(?:proj-)?[A-Za-z0-9_-]{8,}"#, L10n.text("redaction.key")),
            (#"\beyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\b"#, L10n.text("redaction.token")),
            (#"(?i)([?&](?:access_token|refresh_token|id_token|api_key|token|code)=)[^&#\s]+"#, L10n.text("redaction.field")),
            (#"(?i)(["']?(?:access_?token|refresh_?token|id_?token|api_?key|openai_api_key|authorization|client_secret|account_?id|chatgptAccountId|organization_?id|email)["']?\s*[:=]\s*)(?:(?:Bearer\s+)?\[(?:已隐藏|密钥已隐藏|令牌已隐藏|邮箱已隐藏|账户已隐藏|redacted)\]|"[^"]*"|'[^']*'|[^\s,;}\]]+)"#, L10n.text("redaction.field")),
            (#"\b[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}\b"#, L10n.text("redaction.email")),
            (#"\borg-[A-Za-z0-9_-]{6,}\b"#, L10n.text("redaction.account"))
        ]
        for (pattern, replacement) in replacements {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { continue }
            text = regex.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: replacement)
        }
        text = String(String.UnicodeScalarView(text.unicodeScalars.filter {
            !CharacterSet.controlCharacters.contains($0) || $0 == "\n" || $0 == "\t"
        })).trimmingCharacters(in: .whitespacesAndNewlines)
        return text.count > limit ? L10n.text("diagnostic.truncated", String(text.prefix(limit))) : text
    }

    public static func description(of error: Error) -> String {
        if let value = (error as? LocalizedError)?.errorDescription { return sanitized(value) }
        let value = error as NSError
        var detail = L10n.text("diagnostic.system_error", value.localizedDescription, value.domain, String(value.code))
        if let underlying = value.userInfo[NSUnderlyingErrorKey] as? NSError {
            detail += "\n" + L10n.text("diagnostic.system_error", underlying.localizedDescription, underlying.domain, String(underlying.code))
        }
        return sanitized(detail)
    }

    public static func stage(_ method: String) -> String {
        switch method {
        case "initialize": return L10n.text("diagnostic.initialize")
        case "account/read": return L10n.text("diagnostic.account")
        case "account/rateLimits/read": return L10n.text("diagnostic.quota")
        default: return method
        }
    }
}
