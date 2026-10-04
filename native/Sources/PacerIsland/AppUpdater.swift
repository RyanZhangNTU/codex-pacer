import AppKit
import Combine
import Sparkle
import PacerCore

/// Sparkle owns scheduling, download verification, replacement and relaunch.
/// Pacer's normal termination path stops its observers and releases the instance lock.
@MainActor
final class AppUpdater: NSObject, ObservableObject, SPUUpdaterDelegate, @preconcurrency SPUStandardUserDriverDelegate {
    @Published private(set) var canCheck = false
    @Published private(set) var sessionInProgress = false
    @Published private(set) var automaticallyChecks = false
    @Published private(set) var lastChecked: Date?
    @Published private(set) var status: String?
    @Published private(set) var hasError = false
    let enabled: Bool
    var onPresentationChange: ((Bool) -> Void)?
    private var controller: SPUStandardUpdaterController!
    private var started = false
    private var updateInterfacePresented = false
    private var modalAlertCount = 0
    private var presentationActive = false

    init(enabled: Bool = true) {
        self.enabled = enabled
        super.init()
        guard enabled else { status = L10n.text("updates.demo_disabled"); return }
        controller = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: self, userDriverDelegate: self)
        controller.updater.publisher(for: \.canCheckForUpdates).assign(to: &$canCheck)
        controller.updater.publisher(for: \.sessionInProgress).assign(to: &$sessionInProgress)
        controller.updater.publisher(for: \.automaticallyChecksForUpdates).assign(to: &$automaticallyChecks)
        controller.updater.publisher(for: \.lastUpdateCheckDate).assign(to: &$lastChecked)
    }

    func start() {
        guard enabled, !started else { return }
        started = true
        controller.startUpdater()
    }

    func setAutomaticallyChecks(_ value: Bool) {
        guard enabled, value != automaticallyChecks else { return }
        controller.updater.automaticallyChecksForUpdates = value
    }

    @objc func checkForUpdates(_ sender: Any? = nil) {
        guard canCheck else { return }
        status = L10n.text("updates.checking")
        hasError = false
        updateInterfacePresented = true
        updatePresentation()
        controller.checkForUpdates(sender)
    }

    private func updatePresentation() {
        let active = updateInterfacePresented || modalAlertCount > 0
        guard active != presentationActive else { return }
        presentationActive = active
        // This must happen synchronously, before Sparkle enters a modal run loop.
        onPresentationChange?(active)
    }

    func standardUserDriverWillShowModalAlert() {
        modalAlertCount += 1
        updatePresentation()
    }

    func standardUserDriverDidShowModalAlert() {
        // Sparkle calls this after runModal returns, once the alert is dismissed.
        modalAlertCount = max(0, modalAlertCount - 1)
        updatePresentation()
    }

    func standardUserDriverWillHandleShowingUpdate(_ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem, state: SPUUserUpdateState) {
        guard handleShowingUpdate else { return }
        updateInterfacePresented = true
        updatePresentation()
    }

    func standardUserDriverWillFinishUpdateSession() {
        updateInterfacePresented = false
        updatePresentation()
    }

    func updater(_ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck, error: Error?) {
        updateInterfacePresented = false
        updatePresentation()
    }

    func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        status = L10n.text("updates.available", item.displayVersionString)
        hasError = false
    }

    func updaterDidNotFindUpdate(_ updater: SPUUpdater, error: Error) {
        status = L10n.text("updates.no_update")
        hasError = false
    }

    func updater(_ updater: SPUUpdater, didAbortWithError error: Error) {
        let failure = error as NSError
        if failure.domain == SUSparkleErrorDomain, failure.code == Int(SUError.noUpdateError.rawValue) { return }
        if failure.domain == SUSparkleErrorDomain, failure.code == Int(SUError.installationCanceledError.rawValue) {
            status = L10n.text("updates.cancelled"); hasError = false; return
        }
        var message = failure.localizedDescription
        if let reason = failure.localizedFailureReason { message += "\n" + reason }
        if let underlying = failure.userInfo[NSUnderlyingErrorKey] as? NSError {
            message += "\n" + underlying.localizedDescription
        }
        status = L10n.text("updates.failed", CodexDiagnosticText.sanitized(message))
        hasError = true
    }
}
