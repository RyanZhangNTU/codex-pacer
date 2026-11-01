import Foundation

/// Where the Support page leads. Pacer never signs in to GitHub: each link opens
/// in the browser that holds the user's session.
public enum ProjectSupport {
    public struct Code: Equatable, Sendable {
        public let titleKey: String
        public let hintKey: String
        public let image: URL
    }

    public struct DonationLink: Equatable, Sendable {
        public let title: String
        public let url: URL
    }

    public static let repository = URL(string: "https://github.com/RyanZhangNTU/codex-pacer")!
    /// The link GitHub's own Star button uses when signed out. A signed-in browser
    /// goes straight to the project; a signed-out one signs in and then returns
    /// there, so either way the next click is Star.
    public static let star = URL(string: "https://github.com/login?return_to=%2FRyanZhangNTU%2Fcodex-pacer")!
    /// GitHub keeps these addresses through its own sign-in.
    public static let featureRequest = URL(string: "https://github.com/RyanZhangNTU/codex-pacer/issues/new?template=feature_request.yml")!
    public static let bugReport = URL(string: "https://github.com/RyanZhangNTU/codex-pacer/issues/new?template=bug_report.yml")!

    public static let donationLinks = [DonationLink(title: "Buy Me a Coffee", url: URL(string: "https://buymeacoffee.com/codexpacer")!)]
    private static let codeResources = [(resource: "support-wechat", titleKey: "support.code.wechat", hintKey: "support.code.wechat_hint")]

    /// A QR code is offered only when its image ships with the app.
    public static func codes(in bundle: Bundle = L10n.resourceBundle) -> [Code] {
        codeResources.compactMap { code in
            bundle.url(forResource: code.resource, withExtension: "png").map { Code(titleKey: code.titleKey, hintKey: code.hintKey, image: $0) }
        }
    }
}
