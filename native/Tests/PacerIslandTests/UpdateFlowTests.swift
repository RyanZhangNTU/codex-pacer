import Sparkle
import XCTest
@testable import PacerIsland

final class UpdateFlowTests: XCTestCase {
    private let release = UpdateFlow.Release(version: "4.3.1", build: "79",
        notes: URL(string: "https://github.com/RyanZhangNTU/codex-pacer/releases/tag/v4.3.1"))

    func testScheduledCheckRemembersTheVersionAndEndsTheSessionQuietly() {
        var flow = UpdateFlow()
        XCTAssertEqual(flow.found(release, installable: true), .dismiss)
        XCTAssertEqual(flow.available, release)
        XCTAssertEqual(flow.phase, .idle)
        flow.dismissed()
        XCTAssertEqual(flow.available, release)
        XCTAssertEqual(flow.phase, .idle)
    }

    func testManualCheckShowsCheckingThenTheFoundVersionOrUpToDate() {
        var flow = UpdateFlow()
        flow.begin(.check)
        XCTAssertEqual(flow.phase, .checking)
        XCTAssertTrue(flow.isBusy)
        XCTAssertEqual(flow.found(release, installable: true), .dismiss)
        XCTAssertEqual(flow.phase, .idle)
        flow.dismissed()

        flow.begin(.check)
        flow.notFound()
        XCTAssertEqual(flow.phase, .upToDate)
        XCTAssertNil(flow.available, "A version the feed no longer offers is forgotten")
        XCTAssertNil(flow.request)
    }

    func testScheduledCheckClearsAWithdrawnVersionButKeepsItAfterNetworkFailure() {
        var flow = UpdateFlow(available: release)
        flow.finishedCycle(error: URLError(.notConnectedToInternet))
        XCTAssertEqual(flow.available, release)

        flow.finishedCycle(error: NSError(domain: SUSparkleErrorDomain, code: Int(SUError.noUpdateError.rawValue)))
        XCTAssertNil(flow.available)
        XCTAssertEqual(flow.phase, .idle, "A background check does not show a manual result")
    }

    func testAnyFailedCheckOffersOtherWaysUntilACheckReadsTheFeed() {
        let then = Date(timeIntervalSince1970: 1_000), later = Date(timeIntervalSince1970: 2_000)
        var flow = UpdateFlow()
        XCTAssertNil(flow.failure)
        // A scheduled check fails only at the end of its cycle, and counts as much as one asked for.
        flow.finishedCycle(error: URLError(.timedOut), at: then)
        XCTAssertEqual(flow.failure, .check)
        XCTAssertEqual(flow.checkFailedAt, then)
        XCTAssertNil(flow.lastSuccess)
        XCTAssertEqual(flow.phase, .idle, "A scheduled failure doesn't take over the status line")

        flow.begin(.check)
        XCTAssertEqual(flow.failure, .check, "The panel stays while the check runs again")
        flow.failed("offline", at: later)
        XCTAssertEqual(flow.checkFailedAt, later, "Each failure is a new one, which brings back a closed banner")

        flow.begin(.check)
        flow.notFound(at: later)
        XCTAssertNil(flow.failure)
        XCTAssertNil(flow.checkFailedAt)
        XCTAssertEqual(flow.lastSuccess, later)

        flow.finishedCycle(error: URLError(.cannotFindHost), at: later)
        XCTAssertEqual(flow.found(release, installable: true, at: then), .dismiss)
        XCTAssertNil(flow.failure, "Finding a version reads the feed too")
        XCTAssertEqual(flow.lastSuccess, then)
    }

    func testAFailedCheckWithAVersionWaitingOffersTheUpdateNotOtherWays() {
        var flow = UpdateFlow(available: release)
        flow.finishedCycle(error: URLError(.notConnectedToInternet))
        XCTAssertNotNil(flow.checkFailedAt)
        XCTAssertNil(flow.failure, "The found version's own banner and button still stand")
    }

    func testAFailedDownloadOffersOtherWaysForThatVersion() {
        var flow = UpdateFlow(available: release)
        flow.begin(.install)
        flow.failed("The download timed out")
        flow.finishedCycle(error: URLError(.timedOut))
        XCTAssertEqual(flow.failure, .download(release))
        XCTAssertNil(flow.checkFailedAt, "A download that failed is not a failed check")
        flow.begin(.install)
        XCTAssertNil(flow.failure, "Trying again shows the download instead")
        flow.cancelled()
        XCTAssertNil(flow.failure, "Cancelling is not a failure")
    }

    func testCancellingOrDeferringInstallerAuthorizationAllowsRetry() {
        for error in [SUError.installationCanceledError, .installationAuthorizeLaterError] {
            var flow = UpdateFlow(available: release)
            flow.begin(.install)
            flow.installing()
            flow.dismissed()
            flow.finishedCycle(error: NSError(domain: SUSparkleErrorDomain, code: Int(error.rawValue)))
            XCTAssertEqual(flow.phase, .idle)
            XCTAssertNil(flow.request)
            XCTAssertEqual(flow.available, release)
        }
    }

    func testOneClickInstallsWithoutAskingAgainAndKeepsInstallingThroughDismissal() {
        var flow = UpdateFlow(available: release)
        flow.begin(.install)
        XCTAssertEqual(flow.phase, .downloading(nil))
        XCTAssertEqual(flow.found(release, installable: true), .install)
        flow.downloadStarted()
        flow.expect(200)
        flow.receive(50)
        XCTAssertEqual(flow.phase, .downloading(0.25))
        flow.receive(400)
        XCTAssertEqual(flow.phase, .downloading(1), "A short Content-Length never shows more than 100%")
        flow.installing()
        XCTAssertEqual(flow.readyToInstall(), .install)
        XCTAssertEqual(flow.phase, .installing)
        flow.dismissed()
        XCTAssertEqual(flow.phase, .installing, "The app is about to quit; the button must not come back")
    }

    func testOnlyAnInstallRequestInstallsAReadyUpdate() {
        var flow = UpdateFlow(available: release)
        XCTAssertEqual(flow.readyToInstall(), .dismiss)
        flow.begin(.check)
        XCTAssertEqual(flow.readyToInstall(), .dismiss)
    }

    func testAnUnknownSizeShowsAnIndeterminateDownload() {
        var flow = UpdateFlow(available: release)
        flow.begin(.install)
        flow.downloadStarted()
        flow.receive(1_000)
        XCTAssertEqual(flow.phase, .downloading(nil))
    }

    func testFailureAndCancelKeepTheVersionForAnotherTry() {
        var flow = UpdateFlow(available: release)
        flow.begin(.install)
        flow.failed("offline")
        XCTAssertEqual(flow.phase, .failed("offline"))
        XCTAssertEqual(flow.available, release)
        XCTAssertFalse(flow.isBusy)
        flow.dismissed()
        XCTAssertEqual(flow.phase, .failed("offline"), "The reason stays visible after the session ends")

        flow.begin(.install)
        flow.downloadStarted()
        flow.dismissed()
        XCTAssertEqual(flow.phase, .idle, "A cancelled download returns to the update button")
        XCTAssertEqual(flow.available, release)
    }

    func testAnInformationOnlyItemIsNeitherOfferedNorInstalled() {
        var flow = UpdateFlow()
        flow.begin(.install)
        XCTAssertEqual(flow.found(release, installable: false), .dismiss)
        XCTAssertNil(flow.available)
        XCTAssertEqual(flow.phase, .idle)
    }

    func testFailureReasonsLeaveOutSparkleCachePaths() {
        let detail = NSError(domain: "SUSparkleErrorDomain", code: 3001, userInfo: [NSLocalizedDescriptionKey:
            "(Ed)DSA signature validation before unarchiving failed for update /Users/someone/Library/Caches/app/Installation/x/a.zip"])
        let error = NSError(domain: "SUSparkleErrorDomain", code: 3001, userInfo: [
            NSLocalizedDescriptionKey: "The update is improperly signed.", NSUnderlyingErrorKey: detail])
        XCTAssertEqual(AppUpdater.describe(error), "The update is improperly signed.")

        let offline = NSError(domain: "SUSparkleErrorDomain", code: 2001, userInfo: [
            NSLocalizedDescriptionKey: "An error occurred in retrieving update information.",
            NSUnderlyingErrorKey: NSError(domain: NSURLErrorDomain, code: -1009, userInfo: [NSLocalizedDescriptionKey: "The Internet connection appears to be offline."])])
        XCTAssertEqual(AppUpdater.describe(offline), "An error occurred in retrieving update information.\nThe Internet connection appears to be offline.")

        let onlyPath = NSError(domain: "x", code: 1, userInfo: [NSLocalizedDescriptionKey: "Could not move /private/tmp/a/b.app"])
        XCTAssertEqual(AppUpdater.describe(onlyPath), "Could not move …")
    }

    func testARememberedVersionIsDroppedOnceThisBuildHasIt() {
        XCTAssertEqual(UpdateFlow.pending(release, currentBuild: "78"), release)
        XCTAssertNil(UpdateFlow.pending(release, currentBuild: "79"))
        XCTAssertNil(UpdateFlow.pending(release, currentBuild: "100"), "Builds compare as numbers")
        XCTAssertEqual(UpdateFlow.pending(release, currentBuild: nil), release)
        XCTAssertNil(UpdateFlow.pending(nil, currentBuild: "78"))
    }
}
