import UserNotifications
import Foundation
import Combine
import PacerCore

@MainActor
final class NotificationDelivery {
    private let defaults: UserDefaults
    private let authorizationStatus: @MainActor () async -> UNAuthorizationStatus
    private let addRequest: @MainActor (UNNotificationRequest) async throws -> Void
    init(defaults: UserDefaults = .standard,
         authorizationStatus: @escaping @MainActor () async -> UNAuthorizationStatus = {
             await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
         }, addRequest: @escaping @MainActor (UNNotificationRequest) async throws -> Void = {
             try await UNUserNotificationCenter.current().add($0)
         }) {
        self.defaults = defaults; self.authorizationStatus = authorizationStatus; self.addRequest = addRequest
    }

    func deliver(_ notice: IslandNotice) {
        guard defaults.bool(forKey: "systemNotifications") else { return }
        let hidden = defaults.bool(forKey: "hideProjects") && notice.kind != .lowQuota
        Task {
            guard [.authorized, .provisional].contains(await authorizationStatus()) else { return }
            let content = UNMutableNotificationContent()
            content.title = "Codex Pacer"
            let detail = hidden ? L10n.text("activity.hidden_local_name") : notice.detail
            content.body = L10n.text("notice.body", notice.title, detail)
            if let category = notice.category { content.categoryIdentifier = category }
            try? await addRequest(UNNotificationRequest(identifier: "pacer-" + notice.id, content: content, trigger: nil))
        }
    }
    static let openHarnessAction = "deepseek.open-harness"
    static let snoozeSpikeAction = "deepseek.snooze-spike"
    static let topUpAction = "deepseek.top-up"
    /// DeepSeek's spend and balance notices offer their next step as buttons.
    static func registerCategories() {
        let spike = UNNotificationCategory(identifier: DeepSeekBalanceAttention.spikeCategory, actions: [
            UNNotificationAction(identifier: openHarnessAction, title: L10n.text("deepseek.notice.open_harness"), options: [.foreground]),
            UNNotificationAction(identifier: snoozeSpikeAction, title: L10n.text("deepseek.notice.snooze"), options: [])
        ], intentIdentifiers: [])
        let balance = UNNotificationCategory(identifier: DeepSeekBalanceAttention.balanceCategory, actions: [
            UNNotificationAction(identifier: topUpAction, title: L10n.text("deepseek.notice.top_up"), options: [.foreground])
        ], intentIdentifiers: [])
        UNUserNotificationCenter.current().setNotificationCategories([spike, balance])
    }
    static func requestPermission() async -> Bool {
        (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert])) ?? false
    }
}

/// Owned by the app, so closing/reopening Settings cannot leave an old
/// permission callback writing over a newer switch choice.
@MainActor
final class SystemNotificationPreference: ObservableObject {
    @Published private(set) var enabled: Bool
    @Published private(set) var denied = false
    private let defaults: UserDefaults
    private let requestPermission: @MainActor () async -> Bool
    private var revision = 0
    private var permissionTask: Task<Void, Never>?

    init(defaults: UserDefaults = .standard,
         requestPermission: @escaping @MainActor () async -> Bool = { await NotificationDelivery.requestPermission() }) {
        self.defaults = defaults
        self.requestPermission = requestPermission
        enabled = defaults.bool(forKey: "systemNotifications")
    }

    @discardableResult func setEnabled(_ requested: Bool) -> Task<Void, Never>? {
        revision += 1
        permissionTask?.cancel(); permissionTask = nil
        enabled = requested
        denied = false
        guard requested else { defaults.set(false, forKey: "systemNotifications"); return nil }
        guard !defaults.bool(forKey: "systemNotifications") else { return nil }
        let revision = revision
        permissionTask = Task { [weak self, requestPermission] in
            let allowed = await requestPermission()
            guard let self, !Task.isCancelled, revision == self.revision, self.enabled else { return }
            self.defaults.set(allowed, forKey: "systemNotifications")
            self.enabled = allowed
            self.denied = !allowed
            self.permissionTask = nil
        }
        return permissionTask
    }
}
