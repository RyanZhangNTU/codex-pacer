import Foundation

/// Browser programs shared by native web drivers. Tokens stay inside the page.
public enum DeepSeekWebScripts {
    public static let origin = URL(string: "https://platform.deepseek.com/")!
    public static let summaryScript = resource("deepseek-summary")
    public static let sessionFingerprintScript = resource("deepseek-session-fingerprint")

    private static func resource(_ name: String) -> String {
        guard let url = Bundle.module.url(forResource: name, withExtension: "js"),
              let script = try? String(contentsOf: url, encoding: .utf8) else {
            preconditionFailure("Missing bundled browser script: " + name)
        }
        return script.trimmingCharacters(in: .newlines)
    }
}
