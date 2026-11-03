import Foundation

enum ClaudeSSHRouteRules {
    static let maximumOutputBytes = 64 * 1024
    static func parse(_ data: Data, normalizeIPv6: (String) -> String?) -> ClaudeSSHRoute? {
        guard data.count <= maximumOutputBytes, let text = String(data: data, encoding: .utf8) else { return nil }
        var hostname: String?, user: String?, port: Int?
        for line in text.split(separator: "\n") {
            guard let boundary = line.firstIndex(where: { $0.isWhitespace }) else { continue }
            let key = line[..<boundary].lowercased()
            let value = line[boundary...].trimmingCharacters(in: .whitespacesAndNewlines)
            switch key {
            case "hostname":
                guard hostname == nil, let normalized = normalizedHostname(value, normalizeIPv6: normalizeIPv6) else { return nil }
                hostname = normalized
            case "user":
                guard user == nil, validUser(value) else { return nil }
                user = value
            case "port":
                guard port == nil, !value.isEmpty, value.utf8.allSatisfy({ (48...57).contains($0) }),
                      let number = Int(value), (1...65535).contains(number) else { return nil }
                port = number
            default: break
            }
        }
        guard let hostname, let user, let port else { return nil }
        return ClaudeSSHRoute(hostname: hostname, user: user, port: port)
    }

    static func validDestination(_ value: String, normalizeIPv6: (String) -> String?) -> Bool {
        guard !value.isEmpty, value.utf8.count <= 512 else { return false }
        let parts = value.split(separator: "@", omittingEmptySubsequences: false)
        if parts.count == 2 { return validUser(String(parts[0])) && validHostname(String(parts[1]), normalizeIPv6: normalizeIPv6) }
        guard parts.count == 1 else { return false }
        if value.contains(":") { return validHostname(value, normalizeIPv6: normalizeIPv6) }
        return value.range(of: #"^[A-Za-z0-9][A-Za-z0-9._-]{0,128}\z"#, options: .regularExpression) != nil
    }

    private static func validUser(_ value: String) -> Bool {
        value.utf8.count <= 64 && value.range(of: #"^[A-Za-z0-9_][A-Za-z0-9._-]*\z"#, options: .regularExpression) != nil
    }

    private static func validHostname(_ value: String, normalizeIPv6: (String) -> String?) -> Bool {
        guard !value.isEmpty, value.utf8.count <= 253 else { return false }
        if value.contains(":") {
            return normalizeIPv6(value) != nil
        }
        return value.range(of: #"^[A-Za-z0-9][A-Za-z0-9._-]*\z"#, options: .regularExpression) != nil
    }

    private static func normalizedHostname(_ value: String, normalizeIPv6: (String) -> String?) -> String? {
        guard validHostname(value, normalizeIPv6: normalizeIPv6) else { return nil }
        if value.contains(":") {
            return normalizeIPv6(value)
        }
        let lower = value.lowercased()
        return lower.hasSuffix(".") ? String(lower.dropLast()) : lower
    }

}
