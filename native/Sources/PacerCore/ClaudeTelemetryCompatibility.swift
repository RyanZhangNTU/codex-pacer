import Foundation

/// Why Pacer's request telemetry stays off for a Claude home, if it does.
/// `existing`: the user's own settings already export traces elsewhere or
/// would send credentials to Pacer's receiver. `managed`: settings an
/// organization pushes to Claude Code claim the same exporter.
public enum ClaudeTelemetryConflict: String, Codable, Sendable { case none, existing, managed }

/// The telemetry-related parts of the settings an organization pushes to
/// Claude Code: managed settings files, managed preferences, the policy
/// registry key and the cached server-managed settings. Only environment
/// strings and whether a headers helper is set are kept.
public struct ClaudeManagedTelemetry: Equatable, Sendable {
    public var environment: [String: String]
    public var headersHelper: Bool
    public init(environment: [String: String] = [:], headersHelper: Bool = false) {
        self.environment = environment; self.headersHelper = headersHelper
    }
    /// Adds one settings document. A cache may wrap the document in
    /// `settings`; both shapes are read. Any claim counts, so documents are
    /// united rather than ranked.
    public mutating func merge(settings value: [String: Any]) {
        for document in [value, value["settings"] as? [String: Any] ?? [:]] {
            if let env = document["env"] as? [String: Any] {
                for (key, raw) in env.prefix(512) {
                    guard key.utf8.count <= 256, let text = raw as? String ?? (raw as? NSNumber)?.stringValue, text.utf8.count <= 8192 else { continue }
                    environment[key] = text
                }
            }
            if let helper = document["otelHeadersHelper"] as? String, !helper.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                headersHelper = true
            }
        }
    }
    /// Adds a JSON settings document; anything else is ignored.
    public mutating func merge(json data: Data) {
        guard data.count <= 2 * 1024 * 1024, let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        merge(settings: value)
    }
}

/// Decides whether Pacer's trace export can sit beside a home's existing
/// telemetry settings. Rules follow Claude Code's behavior (checked against
/// 2.1.300): trace-specific settings win over generic ones, every OTLP header
/// (static or from `otelHeadersHelper`) is sent with traces too, and managed
/// endpoint, protocol, header or client-certificate settings drop lower-scope
/// trace endpoints.
enum ClaudeTelemetryRules {
    static let endpoint = "http://127.0.0.1:4319/v1/traces"
    /// Keys whose values Pacer's export needs.
    static let required: [String: String] = [
        "CLAUDE_CODE_ENABLE_TELEMETRY": "1", "CLAUDE_CODE_ENHANCED_TELEMETRY_BETA": "1", "OTEL_TRACES_EXPORTER": "otlp",
        "OTEL_EXPORTER_OTLP_TRACES_PROTOCOL": "http/json", "OTEL_EXPORTER_OTLP_TRACES_ENDPOINT": endpoint
    ]
    /// Added when absent; another value only delays exports.
    static let optional: [String: String] = ["OTEL_TRACES_EXPORT_INTERVAL": "1000"]
    static var environment: [String: String] { required.merging(optional) { first, _ in first } }
    private static let flags: Set<String> = ["CLAUDE_CODE_ENABLE_TELEMETRY", "CLAUDE_CODE_ENHANCED_TELEMETRY_BETA"]
    private static let otlp = "OTEL_EXPORTER_OTLP_"
    private static let credentials: Set<String> = ["HEADERS", "CLIENT_KEY", "CLIENT_CERTIFICATE"]

    static func trimmed(_ value: String) -> String { value.trimmingCharacters(in: .whitespacesAndNewlines) }
    /// Claude Code reads its switches as truthy words and exporter lists as
    /// comma-separated names, so `true` and ` otlp` mean what `1` and `otlp` do.
    static func matches(_ key: String, _ value: String) -> Bool {
        guard let wanted = required[key] ?? optional[key] else { return false }
        if flags.contains(key) { return ["1", "true", "yes", "on"].contains(trimmed(value).lowercased()) }
        if key == "OTEL_TRACES_EXPORTER" { return value.split(separator: ",").map { trimmed(String($0)) }.filter { !$0.isEmpty } == ["otlp"] }
        return trimmed(value) == wanted
    }
    static func configured(_ env: [String: String]) -> Bool { required.keys.allSatisfy { key in env[key].map { matches(key, $0) } ?? false } }

    static func conflict(user env: [String: String], headersHelper: Bool, managed: ClaudeManagedTelemetry,
                         owned: [String: String], process: [String: String] = [:]) -> ClaudeTelemetryConflict {
        if claims(managed: managed) { return .managed }
        if claims(user: env, headersHelper: headersHelper, owned: owned) || claims(user: process, headersHelper: false, owned: [:]) { return .existing }
        return .none
    }
    /// Managed settings that change Pacer's keys, or that make Claude Code
    /// drop a lower-scope trace endpoint.
    private static func claims(managed: ClaudeManagedTelemetry) -> Bool {
        if managed.headersHelper { return true }
        for (raw, value) in managed.environment {
            let key = raw.uppercased()
            if required[key] != nil { if !matches(key, value) { return true }; continue }
            guard key.hasPrefix(otlp), !trimmed(value).isEmpty else { continue }
            let rest = String(key.dropFirst(otlp.count))
            if rest == "ENDPOINT" || rest == "PROTOCOL" || credentials.contains(rest) { return true }
            if rest.hasPrefix("TRACES_"), credentials.contains(String(rest.dropFirst(7))) { return true }
        }
        return false
    }
    /// The user's own settings: another destination or switch for traces,
    /// traces already exported elsewhere, or headers that would reach Pacer.
    private static func claims(user env: [String: String], headersHelper: Bool, owned: [String: String]) -> Bool {
        if headersHelper { return true }
        if [otlp + "HEADERS", otlp + "TRACES_HEADERS"].contains(where: { !trimmed(env[$0] ?? "").isEmpty }) { return true }
        if required.contains(where: { key, _ in env[key].map { !matches(key, $0) } ?? false }) { return true }
        // An exporter Pacer did not add, without Pacer's trace endpoint, is
        // already sending traces to a generic or default endpoint.
        if let exporter = env["OTEL_TRACES_EXPORTER"], owned["OTEL_TRACES_EXPORTER"] != exporter,
           env[otlp + "TRACES_ENDPOINT"] == nil { return true }
        return false
    }
}
