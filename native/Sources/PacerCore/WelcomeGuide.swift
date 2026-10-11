import Foundation

/// The getting-started guide appears once per major release line: on a fresh
/// install and on the first launch after upgrading from an earlier major
/// version. Closing it records the line so later updates within it stay quiet.
public enum WelcomeGuide {
    public static let defaultsKey = "welcomeGuideVersion"
    public static let currentMajor = 3

    public static func shouldShow(defaults: UserDefaults = .standard) -> Bool {
        defaults.integer(forKey: defaultsKey) < currentMajor
    }

    public static func markShown(defaults: UserDefaults = .standard) {
        defaults.set(currentMajor, forKey: defaultsKey)
    }
}
