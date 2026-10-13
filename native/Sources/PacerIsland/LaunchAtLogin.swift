import AppKit
import Combine
import PacerCore
import ServiceManagement

/// The system's login-item record for this app, replaceable in tests and demo.
protocol LoginItemService {
    var status: SMAppService.Status { get }
    func register() throws
    func unregister() throws
}

extension SMAppService: LoginItemService {}

/// Demo runs flip an in-memory record, so checks never add a real login item.
final class DemoLoginItemService: LoginItemService {
    private(set) var status = SMAppService.Status.notRegistered
    func register() throws { status = .enabled }
    func unregister() throws { status = .notRegistered }
}

/// Open at Login. macOS owns the choice and shows it in System Settings →
/// General → Login Items, so Pacer reads it back rather than storing a copy;
/// a change made there appears when Pacer next becomes active.
@MainActor
final class LaunchAtLoginPreference: ObservableObject {
    @Published private(set) var enabled = false
    /// Registered, but macOS keeps it from opening until the user allows it.
    @Published private(set) var needsApproval = false
    @Published private(set) var failure: String?
    private let service: LoginItemService
    private var activation: AnyCancellable?

    init(service: LoginItemService) {
        self.service = service
        refresh()
        activation = NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)
            .sink { [weak self] _ in MainActor.assumeIsolated { self?.refresh() } }
    }

    convenience init(demo: Bool) {
        self.init(service: demo ? DemoLoginItemService() : SMAppService.mainApp)
    }

    func refresh() {
        let status = service.status
        enabled = status == .enabled || status == .requiresApproval
        needsApproval = status == .requiresApproval
    }

    /// Registering an item that is already registered, or removing one that is
    /// gone, is an error, so only an actual change reaches the system.
    func setEnabled(_ requested: Bool) {
        failure = nil
        refresh()
        do {
            if requested, !enabled { try service.register() }
            if !requested, enabled { try service.unregister() }
        } catch {
            failure = L10n.text("settings.login_item_failed", CodexDiagnosticText.description(of: error))
        }
        refresh()
    }

    func openSystemSettings() { SMAppService.openSystemSettingsLoginItems() }
}
