import AppKit
import Combine
import Sparkle
import PacerCore

/// Where an update stands, kept apart from Sparkle so it can be tested.
/// A found version stays `available` until it is installed or the feed
/// stops offering it; `phase` is what the current or last session did.
struct UpdateFlow: Equatable {
    struct Release: Codable, Equatable {
        var version: String
        var build: String
        var notes: URL?
    }

    enum Phase: Equatable {
        case idle, checking, upToDate, installing
        /// The downloaded fraction, or nil before the size is known.
        case downloading(Double?)
        case failed(String)
    }

    /// What the user asked the running session for. Sparkle's scheduled
    /// checks have none and only record what they find.
    enum Request { case check, install }
    enum Choice { case install, dismiss }

    private(set) var phase: Phase = .idle
    private(set) var available: Release?
    private(set) var request: Request?
    private var expected: UInt64 = 0
    private var received: UInt64 = 0

    init(available: Release? = nil) { self.available = available }

    var isBusy: Bool {
        switch phase {
        case .checking, .downloading, .installing: true
        default: false
        }
    }

    mutating func begin(_ request: Request) {
        self.request = request
        phase = request == .check ? .checking : .downloading(nil)
    }

    /// Install only when the user asked for it in this session; otherwise
    /// remember the version and end the session, so nothing waits on a reply.
    mutating func found(_ release: Release, installable: Bool) -> Choice {
        guard installable else {
            if request != nil { phase = .idle }
            return .dismiss
        }
        available = release
        if request == .install { phase = .downloading(nil); return .install }
        if request == .check { phase = .idle }
        return .dismiss
    }

    mutating func notFound() {
        available = nil
        if request != nil { phase = .upToDate }
        request = nil
    }

    mutating func failed(_ message: String) {
        phase = .failed(message)
        request = nil
    }

    mutating func cancelled() {
        phase = .idle
        request = nil
    }

    mutating func downloadStarted() {
        expected = 0
        received = 0
        phase = .downloading(nil)
    }

    mutating func expect(_ length: UInt64) {
        expected = length
        received = 0
        phase = .downloading(fraction)
    }

    mutating func receive(_ length: UInt64) {
        received += length
        phase = .downloading(fraction)
    }

    private var fraction: Double? {
        expected > 0 ? min(1, Double(received) / Double(expected)) : nil
    }

    mutating func installing() { phase = .installing }

    mutating func readyToInstall() -> Choice {
        guard request == .install else { return .dismiss }
        phase = .installing
        return .install
    }

    /// Sparkle ends every session here, after a choice, a cancel or an error.
    mutating func dismissed() {
        if case .installing = phase, request == .install { return }
        if isBusy { phase = .idle }
        request = nil
    }

    /// Sparkle reports some results only when the cycle ends.
    mutating func finishedCycle(error: Error?) {
        guard let failure = error as NSError?, failure.domain == SUSparkleErrorDomain else { return }
        switch failure.code {
        case Int(SUError.noUpdateError.rawValue):
            notFound()
        case Int(SUError.installationCanceledError.rawValue), Int(SUError.installationAuthorizeLaterError.rawValue):
            cancelled()
        default:
            break
        }
    }

    /// A remembered version that this build already has (or passed) is stale.
    static func pending(_ stored: Release?, currentBuild: String?) -> Release? {
        guard let stored, let currentBuild else { return stored }
        return stored.build.compare(currentBuild, options: .numeric) == .orderedDescending ? stored : nil
    }
}

/// Sparkle owns scheduling, verification, replacement and relaunch; Pacer
/// shows each step inline in its own window instead of Sparkle's dialogs.
/// Pacer's normal termination path stops its observers and releases the instance lock.
@MainActor
final class AppUpdater: NSObject, ObservableObject, SPUUpdaterDelegate, SPUUserDriver {
    @Published private(set) var flow: UpdateFlow
    @Published private(set) var canCheck = false
    @Published private(set) var sessionInProgress = false
    @Published private(set) var automaticallyChecks = false
    @Published private(set) var lastChecked: Date?
    let enabled: Bool
    private var updater: SPUUpdater!
    private var started = false
    private var cancelDownload: (() -> Void)?
    private let defaults: UserDefaults
    private static let pendingKey = "pendingUpdate"
    private static let currentBuild = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String

    init(enabled: Bool = true, defaults: UserDefaults = .standard) {
        self.enabled = enabled
        self.defaults = defaults
        let stored = defaults.data(forKey: Self.pendingKey).flatMap { try? JSONDecoder().decode(UpdateFlow.Release.self, from: $0) }
        let pending = enabled ? UpdateFlow.pending(stored, currentBuild: Self.currentBuild) : nil
        flow = UpdateFlow(available: pending)
        super.init()
        // After the update relaunches, the version it was waiting for is this one.
        if enabled, pending == nil { defaults.removeObject(forKey: Self.pendingKey) }
        guard enabled else {
            if let version = UserDefaults.standard.string(forKey: "demoUpdate") {
                flow = UpdateFlow(available: .init(version: version, build: "0"))
            }
            return
        }
        updater = SPUUpdater(hostBundle: .main, applicationBundle: .main, userDriver: self, delegate: self)
        updater.publisher(for: \.canCheckForUpdates).assign(to: &$canCheck)
        updater.publisher(for: \.sessionInProgress).assign(to: &$sessionInProgress)
        updater.publisher(for: \.automaticallyChecksForUpdates).assign(to: &$automaticallyChecks)
        updater.publisher(for: \.lastUpdateCheckDate).assign(to: &$lastChecked)
    }

    func start() {
        guard enabled, !started else { return }
        started = true
        do { try updater.start() } catch { update { $0.failed(Self.describe(error)) } }
    }

    func setAutomaticallyChecks(_ value: Bool) {
        guard enabled, value != automaticallyChecks else { return }
        updater.automaticallyChecksForUpdates = value
    }

    @objc func checkForUpdates(_ sender: Any? = nil) { run(.check) }

    /// Download, verify, install and relaunch without another question.
    func installUpdate() { run(.install) }

    func cancel() { cancelDownload?() }

    private func run(_ request: UpdateFlow.Request) {
        guard enabled, canCheck, !flow.isBusy else { return }
        update { $0.begin(request) }
        updater.checkForUpdates()
    }

    private func update(_ change: (inout UpdateFlow) -> Void) {
        var next = flow
        change(&next)
        guard next != flow else { return }
        if next.available != flow.available {
            if let release = next.available, let data = try? JSONEncoder().encode(release) {
                defaults.set(data, forKey: Self.pendingKey)
            } else {
                defaults.removeObject(forKey: Self.pendingKey)
            }
        }
        flow = next
    }

    /// The reason in the user's language. Sparkle's extra lines often name
    /// its cache paths, which say nothing useful and include the user's name.
    nonisolated static func describe(_ error: Error) -> String {
        let failure = error as NSError
        let underlying = failure.userInfo[NSUnderlyingErrorKey] as? NSError
        let path = #"(?:^|[\s(])(?:/[^\s/]+){2,}"#
        var lines: [String] = []
        for line in [failure.localizedDescription, failure.localizedFailureReason, underlying?.localizedDescription] {
            guard let line = line?.trimmingCharacters(in: .whitespacesAndNewlines), !line.isEmpty,
                  line.range(of: path, options: .regularExpression) == nil, !lines.contains(line) else { continue }
            lines.append(line)
        }
        let message = lines.isEmpty
            ? failure.localizedDescription.replacingOccurrences(of: path, with: " …", options: .regularExpression)
            : lines.joined(separator: "\n")
        return CodexDiagnosticText.sanitized(message)
    }

    func updater(_ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck, error: Error?) {
        cancelDownload = nil
        update { $0.finishedCycle(error: error) }
    }

    // MARK: SPUUserDriver

    /// Info.plist enables daily checks, so Sparkle should never ask; if it
    /// does, keep that documented default.
    func show(_ request: SPUUpdatePermissionRequest, reply: @escaping (SUUpdatePermissionResponse) -> Void) {
        reply(SUUpdatePermissionResponse(automaticUpdateChecks: true, sendSystemProfile: false))
    }

    func showUserInitiatedUpdateCheck(cancellation: @escaping () -> Void) {}

    func showUpdateFound(with appcastItem: SUAppcastItem, state: SPUUserUpdateState, reply: @escaping (SPUUserUpdateChoice) -> Void) {
        let release = UpdateFlow.Release(version: appcastItem.displayVersionString, build: appcastItem.versionString,
                                         notes: appcastItem.infoURL)
        var choice = UpdateFlow.Choice.dismiss
        update { choice = $0.found(release, installable: !appcastItem.isInformationOnlyUpdate) }
        reply(choice == .install ? .install : .dismiss)
    }

    func showUpdateReleaseNotes(with downloadData: SPUDownloadData) {}
    func showUpdateReleaseNotesFailedToDownloadWithError(_ error: Error) {}

    func showUpdateNotFoundWithError(_ error: Error, acknowledgement: @escaping () -> Void) {
        update { $0.notFound() }
        acknowledgement()
    }

    func showUpdaterError(_ error: Error, acknowledgement: @escaping () -> Void) {
        let failure = error as NSError
        if failure.domain == SUSparkleErrorDomain, failure.code == Int(SUError.installationCanceledError.rawValue) {
            update { $0.cancelled() }
        } else {
            update { $0.failed(Self.describe(error)) }
        }
        acknowledgement()
    }

    func showDownloadInitiated(cancellation: @escaping () -> Void) {
        cancelDownload = cancellation
        update { $0.downloadStarted() }
    }

    func showDownloadDidReceiveExpectedContentLength(_ expectedContentLength: UInt64) {
        update { $0.expect(expectedContentLength) }
    }

    func showDownloadDidReceiveData(ofLength length: UInt64) {
        update { $0.receive(length) }
    }

    func showDownloadDidStartExtractingUpdate() {
        cancelDownload = nil
        update { $0.installing() }
    }

    func showExtractionReceivedProgress(_ progress: Double) {}

    func showReady(toInstallAndRelaunch reply: @escaping (SPUUserUpdateChoice) -> Void) {
        var choice = UpdateFlow.Choice.dismiss
        update { choice = $0.readyToInstall() }
        reply(choice == .install ? .install : .dismiss)
    }

    func showInstallingUpdate(withApplicationTerminated applicationTerminated: Bool, retryTerminatingApplication: @escaping () -> Void) {
        update { $0.installing() }
    }

    func showUpdateInstalledAndRelaunched(_ relaunched: Bool, acknowledgement: @escaping () -> Void) {
        acknowledgement()
    }

    func dismissUpdateInstallation() {
        cancelDownload = nil
        update { $0.dismissed() }
    }

    /// A check while a download runs just brings the window forward.
    func showUpdateInFocus() {}
}
