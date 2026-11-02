import Foundation

/// Validated SSH route discovery and parsing. Hosts capture stdout without
/// connecting or authenticating, and provide native IPv6 normalization.
public enum ClaudeSSHRouteResolver {
    public static let maximumOutputBytes = ClaudeSSHRouteRules.maximumOutputBytes
    public static func arguments(host: String, port: Int?, timeout: TimeInterval,
                                 normalizeIPv6: (String) -> String?) -> [String]? {
        guard validDestination(host, normalizeIPv6: normalizeIPv6), port.map({ (1...65535).contains($0) }) ?? true,
              timeout.isFinite, timeout > 0, !Task.isCancelled else { return nil }
        var arguments = ["-G", "-o", "CanonicalizeHostname=no", "-o", "PermitLocalCommand=no",
                         "-o", "BatchMode=yes", "-o", "ForwardAgent=no", "-o", "ClearAllForwardings=yes"]
        if let port { arguments += ["-p", String(port)] }
        arguments += ["--", host]
        return arguments
    }
    public static func parse(_ data: Data, normalizeIPv6: (String) -> String?) -> ClaudeSSHRoute? {
        ClaudeSSHRouteRules.parse(data, normalizeIPv6: normalizeIPv6)
    }
    public static func validDestination(_ value: String, normalizeIPv6: (String) -> String?) -> Bool {
        ClaudeSSHRouteRules.validDestination(value, normalizeIPv6: normalizeIPv6)
    }
}
