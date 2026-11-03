import Foundation
import PacerCore

typealias CodexQuotaMonitor = CodexQuotaCoordinator

extension CodexQuotaServices {
    static var live: Self {
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("CodexPacerIsland/CurrentCycle", isDirectory: true)
        return .init(makeClient: { home, customPath in
            let report = await Task.detached(priority: .utility) {
                CodexExecutableResolver.discover(customPath: customPath)
            }.value
            try Task.checkCancellation()
            guard let selected = report.selected else {
                throw CodexClientError.executableNotFound(report.issue ?? L10n.text("cli.missing_short"))
            }
            return CodexClient(executable: selected.url, home: home)
        }, history: QuotaHistoryStore(directory: directory, files: WindowsRecoveringHistoryFiles(kind: .quota)))
    }
}
