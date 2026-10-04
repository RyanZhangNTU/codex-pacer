import UserNotifications
import Foundation
import PacerCore

@MainActor
final class NotificationDelivery {
    func deliver(_ notice: IslandNotice) {
        guard UserDefaults.standard.bool(forKey: "systemNotifications") else { return }
        Task {
            let center = UNUserNotificationCenter.current()
            let settings = await center.notificationSettings()
            guard [.authorized, .provisional].contains(settings.authorizationStatus) else { return }
            let content = UNMutableNotificationContent()
            content.title = "Codex Pacer"
            let detail = UserDefaults.standard.bool(forKey: "hideProjects") && notice.kind != .lowQuota ? L10n.text("activity.hidden_local_name") : notice.detail
            content.body = L10n.text("notice.body", notice.title, detail)
            try? await center.add(UNNotificationRequest(identifier: "pacer-" + notice.id, content: content, trigger: nil))
        }
    }
    static func requestPermission() async -> Bool {
        (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert])) ?? false
    }
}
