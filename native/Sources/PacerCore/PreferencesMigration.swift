import Foundation

/// Preserve native preview preferences when moving to the production bundle.
public enum PreferencesMigration {
    private static let marker = "migratedNativePreviewPreferences"
    private static let keys = [
        "codexExecutable", "codexHome", "monitorSSH", "floatingIsland",
        "islandAppearance", "showInFullscreen", "showInMenuBar", "displayID",
        "compactMetric", "quotaWindowID", "lowQuotaReminder", "inputReminder",
        "completionReminder", "completedRetentionMinutes", "systemNotifications",
        "hideProjects", "glassStyle", "glassTint", "glassTransparency", "glassCornerRadius"
    ]

    public static func migrate(to defaults: UserDefaults, from legacy: [String: Any]) {
        guard !defaults.bool(forKey: marker) else { return }
        for key in keys where defaults.object(forKey: key) == nil {
            if let value = legacy[key] { defaults.set(value, forKey: key) }
        }
        defaults.set(true, forKey: marker)
    }
}
