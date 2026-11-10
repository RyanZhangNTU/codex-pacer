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
///
/// Claude Code takes each `env` variable from the highest-priority managed
/// source that sets it: server-managed settings, then MDM or HKLM policy, then
/// the managed files (drop-ins after `managed-settings.json`, later names
/// winning), and HKCU only without any of those. OTLP routing and credentials
/// (`otlpFamily`) are one group, taken whole from the highest source that sets
/// any of them or a headers helper. Callers `fill` sources in that order. A
/// headers helper from any source counts, which can only over-report.
public struct ClaudeManagedTelemetry: Equatable, Sendable {
    public var environment: [String: String]
    public var headersHelper: Bool
    public init(environment: [String: String] = [:], headersHelper: Bool = false) {
        self.environment = environment; self.headersHelper = headersHelper
    }
    /// Adds one settings document over the ones before it, as Claude Code
    /// layers files within one source. A cache may wrap the document in
    /// `settings`; both shapes are read.
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
    /// Adds a JSON settings document; anything else is ignored. Returns
    /// whether `data` held a settings document.
    @discardableResult public mutating func merge(json data: Data) -> Bool {
        guard data.count <= 2 * 1024 * 1024, let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
        merge(settings: value); return true
    }
    /// The managed files in `folder` as one source: `managed-settings.json`,
    /// then visible `managed-settings.d/*.json` drop-ins by name, later files
    /// winning. `found` says whether any of them held a settings document.
    public static func files(in folder: URL) -> (value: ClaudeManagedTelemetry, found: Bool) {
        var result = ClaudeManagedTelemetry(), found = false
        let dropIns = folder.appendingPathComponent("managed-settings.d")
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: dropIns.path)) ?? [])
            .filter { $0.hasSuffix(".json") && !$0.hasPrefix(".") }.sorted().prefix(64)
        for url in [folder.appendingPathComponent("managed-settings.json")] + names.map(dropIns.appendingPathComponent) {
            if let data = small(url), result.merge(json: data) { found = true }
        }
        return (result, found)
    }
    /// A regular file of at most 2 MiB.
    public static func small(_ url: URL) -> Data? {
        guard let size = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber,
              size.intValue <= 2 * 1024 * 1024 else { return nil }
        return try? Data(contentsOf: url)
    }
    /// Keys Claude Code takes as one group across managed sources.
    static let otlpFamilyKeys: Set<String> = [
        "OTEL_LOG_RAW_API_BODIES", "OTEL_LOG_USER_PROMPTS", "OTEL_LOG_ASSISTANT_RESPONSES", "OTEL_LOG_TOOL_CONTENT", "OTEL_LOG_TOOL_DETAILS",
        "OTEL_LOG_MANAGED_SETTINGS", "OTEL_LOGS_EXPORTER", "ENABLE_BETA_TRACING_DETAILED", "BETA_TRACING_ENDPOINT", "ANT_OTEL_LOGS_EXPORTER"
    ]
    static func otlpFamily(_ key: String) -> Bool {
        let key = key.uppercased()
        return key.hasPrefix("OTEL_EXPORTER_OTLP_") || key.hasPrefix("ANT_OTEL_EXPORTER_OTLP_") || otlpFamilyKeys.contains(key)
    }
    /// Adds a lower-priority source: it supplies only variables no
    /// higher-priority source set, and no OTLP family key once a higher source
    /// set one or a headers helper. Empty family values count as unset.
    public mutating func fill(_ lower: ClaudeManagedTelemetry) {
        func blank(_ value: String) -> Bool { value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        let claimed = headersHelper || environment.contains { Self.otlpFamily($0.key) && !blank($0.value) }
        for (key, value) in lower.environment where environment[key] == nil {
            if Self.otlpFamily(key), claimed || blank(value) { continue }
            environment[key] = value
        }
        headersHelper = headersHelper || lower.headersHelper
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
    static let enableKey = "CLAUDE_CODE_ENABLE_TELEMETRY", endpointKey = "OTEL_EXPORTER_OTLP_TRACES_ENDPOINT"
    /// Exporters that the telemetry switch also turns on.
    private static let otherExporters = ["OTEL_METRICS_EXPORTER", "OTEL_LOGS_EXPORTER"]

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
    /// A metrics or logs exporter is set to something other than `none`.
    static func exportsOtherSignals(_ env: [String: String]) -> Bool {
        otherExporters.contains { key in
            env[key].map { value in value.split(separator: ",").map { trimmed(String($0)).lowercased() }.contains { !$0.isEmpty && $0 != "none" } } ?? false
        }
    }

    static func conflict(user env: [String: String], headersHelper: Bool, managed: ClaudeManagedTelemetry,
                         owned: [String: String], process: [String: String] = [:]) -> ClaudeTelemetryConflict {
        if claims(managed: managed) { return .managed }
        if claims(user: env, headersHelper: headersHelper, owned: owned) || claims(user: process, headersHelper: false, owned: [:]) { return .existing }
        // Pacer's switch would also start metrics or logs exporters that sit
        // configured but off; whoever configured them decides.
        if [env, managed.environment, process].allSatisfy({ $0[enableKey] == nil }) {
            if exportsOtherSignals(managed.environment) { return .managed }
            if exportsOtherSignals(env) || exportsOtherSignals(process) { return .existing }
        }
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
