#if os(Windows)
import Foundation
import PacerCore
import CWindowsSupport

enum WindowsHostApplication {
    typealias Application = ActivityHostApplication.ApplicationIdentity
    static func capture(_ identity: ProcessInstance) -> Application? {
        var image = [UInt16](repeating: 0, count: 32768), applicationID = [UInt16](repeating: 0, count: 512)
        var stamp = pacer_application_stamp()
        guard pacer_process_application(identity.pid, identity.started, &image, image.count, &applicationID, applicationID.count, &stamp) != 0 else { return nil }
        return .init(executable: URL(fileURLWithPath: String(decoding: image.prefix { $0 != 0 }, as: UTF16.self)),
                     volume: stamp.volume, low: stamp.low, high: stamp.high, modified: stamp.modified, size: stamp.size,
                     packageApplicationID: String(decoding: applicationID.prefix { $0 != 0 }, as: UTF16.self))
    }
    /// A live PID that has been reused is never activated. Relaunch uses only
    /// the file/package identity captured from the original same-user process.
    static func activate(_ host: ActivityHostApplication,
                         inspect: (ProcessInstance) -> ProcessInstance? = { WindowsProcessOwnership.inspect($0.pid)?.identity },
                         activateWindow: (ProcessInstance) -> Bool = { WindowsHostWindow.activate(pid: $0.pid, started: $0.started) },
                         open: (Application) -> Bool = open) -> Bool {
        guard !Task.isCancelled else { return false }
        if let live = inspect(host.identity), live == host.identity { return activateWindow(live) }
        guard let application = host.application else { return false }
        return open(application)
    }
    static func open(_ application: Application) -> Bool {
        var stamp = pacer_application_stamp(volume: application.volume, low: application.low, high: application.high,
                                             modified: application.modified, size: application.size)
        return pacer_application_open(Array(WindowsCodexExecutableDiscovery.path(application.executable).utf16) + [0],
                                      Array(application.packageApplicationID.utf16) + [0], &stamp) != 0
    }
}
#endif
