import Foundation

/// After an update, a short note lists what changed, once. A fresh install or
/// a new major line sees the welcome guide instead, which records the version
/// so the note stays quiet. A version without highlights updates silently.
public enum WhatsNew {
    public static let defaultsKey = "whatsNewVersion"

    public struct Item: Equatable, Sendable {
        public enum Control: Equatable, Sendable { case openAtLogin, showEmbeddedSessions }
        public let symbol: String
        public let titleKey: String
        public let detailKey: String
        public var control: Control?
    }

    public struct Release: Equatable, Sendable {
        public let version: String
        public let items: [Item]
        /// A targeted introduction uses the last confirmed note as its
        /// migration baseline. Older copies did not record launch versions.
        public var requiredSeenVersion: String? = nil
    }

    /// Newest first. Add a version's highlights while preparing its release;
    /// both Localizable.strings catalogs need every key.
    public static let releases = [
        Release(version: "3.2.1", items: [
            Item(symbol: "checkmark.rectangle.stack", titleKey: "whats_new.mark_all_read", detailKey: "whats_new.mark_all_read_detail")
        ], requiredSeenVersion: "3.2.0"),
        Release(version: "3.2.0", items: [
            Item(symbol: "sidebar.left", titleKey: "whats_new.screen_position", detailKey: "whats_new.screen_position_detail"),
            Item(symbol: "ellipsis.bubble", titleKey: "whats_new.claude_next_step", detailKey: "whats_new.claude_next_step_detail")
        ]),
        Release(version: "3.1.2", items: [
            Item(symbol: "arrow.up.forward.app", titleKey: "whats_new.third_party_claude", detailKey: "whats_new.third_party_claude_detail",
                 control: .showEmbeddedSessions)
        ]),
        Release(version: "3.1.1", items: [
            Item(symbol: "network", titleKey: "whats_new.remote_control", detailKey: "whats_new.remote_control_detail"),
            Item(symbol: "checkmark.circle", titleKey: "whats_new.stability", detailKey: "whats_new.stability_detail")
        ]),
        Release(version: "3.1.0", items: [
            Item(symbol: "power", titleKey: "settings.open_at_login", detailKey: "whats_new.open_at_login", control: .openAtLogin),
            Item(symbol: "checkmark.circle", titleKey: "whats_new.child_endings", detailKey: "whats_new.child_endings_detail")
        ])
    ]

    /// Releases after the last version seen, up to the running one, newest
    /// first. Copies from before this note existed only see the running version.
    public static func pending(current: String, defaults: UserDefaults = .standard,
                               releases: [Release] = releases) -> [Release] {
        let seen = defaults.string(forKey: defaultsKey)
        return releases.filter { release in
            guard !newer(release.version, than: current) else { return false }
            if let required = release.requiredSeenVersion {
                guard let seen, seen.compare(required, options: .numeric) == .orderedSame else { return false }
            }
            guard let seen else { return release.version.compare(current, options: .numeric) == .orderedSame }
            return newer(release.version, than: seen)
        }
        .sorted { newer($0.version, than: $1.version) }
    }

    /// Every note up to the running version, newest first, for Settings; a
    /// copy without a version shows them all. Targeting does not apply here.
    public static func history(upTo current: String?, releases: [Release] = releases) -> [Release] {
        releases.filter { release in current.map { !newer(release.version, than: $0) } ?? true }
            .sorted { newer($0.version, than: $1.version) }
    }

    /// Never lowers the record, so running an older copy cannot replay notes.
    public static func markSeen(_ version: String, defaults: UserDefaults = .standard) {
        if let seen = defaults.string(forKey: defaultsKey), !newer(version, than: seen) { return }
        defaults.set(version, forKey: defaultsKey)
    }

    static func newer(_ version: String, than other: String) -> Bool {
        version.compare(other, options: .numeric) == .orderedDescending
    }
}
