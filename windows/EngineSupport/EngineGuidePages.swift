import Foundation
import PacerCore

/// Only immutable release metadata and public project links cross this query.
enum EngineGuidePages {
    struct Request: Decodable {
        let current: String
        let seen: String?
        let welcomed: Int
        let language: String
        let demo: Bool
        let settings: Bool
        let forceWelcome: Bool
        let forceWhatsNew: Bool
    }
    struct Item: Encodable {
        let symbol: String, title: String, detail: String
        let control: String?
    }
    struct Release: Encodable {
        let version: String, title: String
        let items: [Item]
    }
    struct Value: Encodable {
        let schemaVersion = 1
        let page: String?
        let major: Int
        let nextSeen: String
        let recordLaunch: Bool, recordClose: Bool
        let versionTitle: String
        let steps: [String]
        let moduleOff: [String: String]
        let releases: [Release], history: [Release]
        let links: [String: String]
        let supportCode: String?
    }
    static func project(_ input: Request) -> Value? {
        guard let language = AppLanguage(rawValue: input.language), input.welcomed >= 0,
              validVersion(input.current), input.seen.map({ $0.utf8.count <= 64 }) ?? true else { return nil }
        let quiet = input.demo || input.settings
        let welcome = input.forceWelcome || (!quiet && input.welcomed < WelcomeGuide.currentMajor)
        let pending = WhatsNew.pending(current: input.current, seen: input.seen)
        let note = !welcome && (input.forceWhatsNew || (!quiet && !pending.isEmpty))
        func release(_ value: WhatsNew.Release) -> Release {
            Release(version: value.version, title: L10n.text("whats_new.version", value.version, language: language),
                items: value.items.map { item in
                    let control: String?
                    switch item.control {
                    case .openAtLogin: control = "openAtLogin"
                    case .showEmbeddedSessions: control = "showEmbeddedSessions"
                    case .showAppButtons: control = "showAppButtons"
                    case nil: control = nil
                    }
                    return Item(symbol: item.symbol, title: L10n.text(item.titleKey, language: language),
                        detail: L10n.text(item.detailKey, language: language), control: control)
                })
        }
        let nextSeen = input.seen.flatMap { WhatsNew.newer(input.current, than: $0) ? nil : $0 } ?? input.current
        let repository = ProjectSupport.repository.absoluteString
        return Value(page: welcome ? "welcome" : note ? "whatsNew" : nil, major: WelcomeGuide.currentMajor,
            nextSeen: nextSeen, recordLaunch: !input.demo && (welcome || (!input.settings && !note)), recordClose: !input.demo,
            versionTitle: L10n.text("whats_new.version", input.current, language: language),
            steps: (1...2).map { L10n.text("welcome.step_of", $0, 2, language: language) },
            moduleOff: Dictionary(uniqueKeysWithValues: AgentProvider.allCases.map { ($0.rawValue, L10n.text("welcome.module.off", $0.displayName, language: language)) }),
            releases: (pending.isEmpty && note ? Array(WhatsNew.releases.prefix(1)) : pending).map(release),
            history: WhatsNew.history(upTo: input.current).map(release),
            links: ["repository": repository, "star": ProjectSupport.star.absoluteString,
                "feature": ProjectSupport.featureRequest.absoluteString, "bug": ProjectSupport.bugReport.absoluteString,
                "donate": ProjectSupport.donationLinks.first?.url.absoluteString ?? repository,
                "manual": repository + (language == .simplifiedChinese ? "/blob/main/docs/guide.zh-CN.md" : "/blob/main/docs/guide.md"),
                "issues": repository + "/issues", "releaseNotes": repository + "/releases/tag/v" + input.current],
            supportCode: ProjectSupport.codes().first?.image.lastPathComponent)
    }
    private static func validVersion(_ value: String) -> Bool {
        let parts = value.split(separator: ".", omittingEmptySubsequences: false)
        return value.utf8.count <= 32 && (1...4).contains(parts.count)
            && parts.allSatisfy { !$0.isEmpty && $0.allSatisfy { $0.isASCII && $0.isNumber } }
    }
}
