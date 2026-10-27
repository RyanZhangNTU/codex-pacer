import Foundation

/// Model and reasoning effort are bounded configuration metadata, never
/// conversation content. Sources report raw identifiers; the task row shows a
/// short name and a localized effort label.
public enum ModelDisplay {
    /// Claude writes `<synthetic>` on locally generated records such as an
    /// interruption; it never names the model doing the work.
    static func sanitizedModel(_ raw: Any?) -> String? {
        guard let value = (raw as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty, value.utf8.count <= 256, !value.hasPrefix("<") else { return nil }
        return value
    }

    /// Efforts are short vendor tokens such as `xhigh`; anything else is dropped.
    static func sanitizedEffort(_ raw: Any?) -> String? {
        guard let value = (raw as? String)?.lowercased(), value.utf8.count <= 32,
              value.range(of: #"^[a-z][a-z0-9_-]*\z"#, options: .regularExpression) != nil else { return nil }
        return value
    }

    /// `claude-opus-5-5` → Opus 5.5, `gpt-6.1-sol` → GPT-6.1 Sol. Unknown
    /// identifiers stay as reported, without a bracketed variant such as `[1m]`.
    public static func name(_ raw: String) -> String {
        let id = raw.replacingOccurrences(of: #"\[[^\]]*\]\z"#, with: "", options: .regularExpression)
        let lower = id.lowercased()
        let parts = lower.split(separator: "-").map(String.init)
        if parts.first == "claude", parts.count >= 3 {
            var words = Array(parts.dropFirst())
            if let last = words.last, last.count == 8, last.allSatisfy(\.isNumber) { words.removeLast() }
            let numbers = words.filter { $0.allSatisfy(\.isNumber) }
            let families = words.filter { !$0.allSatisfy(\.isNumber) }
            guard families.count == 1, (1...2).contains(numbers.count), numbers.allSatisfy({ $0.count <= 2 }) else { return id }
            return families[0].capitalized + " " + numbers.joined(separator: ".")
        }
        if parts.first == "gpt", parts.count >= 2, parts[1].first?.isNumber == true {
            let suffix = parts.dropFirst(2).map { ["mini", "nano"].contains($0) || $0.contains(where: \.isNumber) ? $0 : $0.capitalized }
            return (["GPT-" + parts[1]] + suffix).joined(separator: " ")
        }
        return id
    }

    /// `none` means the model reasons by default and has nothing to show.
    public static func effortLabel(_ raw: String, language: AppLanguage? = nil) -> String? {
        guard raw != "none" else { return nil }
        let known = ["minimal", "low", "medium", "high", "xhigh", "max", "ultra", "persistent"]
        return known.contains(raw) ? L10n.text("model.effort." + raw, language: language) : raw
    }
}
