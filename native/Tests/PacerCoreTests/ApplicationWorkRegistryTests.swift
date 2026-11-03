import Foundation
import XCTest
@testable import PacerCore

final class ApplicationWorkRegistryTests: XCTestCase {
    func testCancellationReleasesOwnershipAndAnOldCompletionCannotClearANewTask() async {
        var work = ApplicationWorkRegistry()
        let key = ApplicationWorkRegistry.Key(.activity, provider: .codex)
        let first = work.begin(key, version: 1)
        let task = Task<Void, Never> { try? await Task.sleep(nanoseconds: 10_000_000_000) }
        work.attach(task, to: first)
        work.cancel(provider: .codex)
        XCTAssertTrue(task.isCancelled); XCTAssertEqual(work.count, 0)
        let next = work.begin(key, version: 2)
        XCTAssertFalse(work.finish(first)); XCTAssertTrue(work.owns(next)); XCTAssertEqual(work.count, 1)
        await task.value
        XCTAssertTrue(work.finish(next)); XCTAssertEqual(work.count, 0)
    }
    func testProviderAndWorkKindCancellationPreserveUnrelatedWork() {
        var work = ApplicationWorkRegistry()
        let codex = work.begin(.init(.hostScan, provider: .codex), version: 1)
        let claude = work.begin(.init(.hostRetry, provider: .claude), version: 1)
        let display = work.begin(.init(.displayExpiry), version: 1)
        work.cancel(provider: .claude, kinds: [.hostScan, .hostRetry])
        XCTAssertTrue(work.owns(codex)); XCTAssertFalse(work.owns(claude)); XCTAssertTrue(work.owns(display))
        work.cancel()
        XCTAssertEqual(work.count, 0); XCTAssertFalse(work.owns(codex)); XCTAssertFalse(work.owns(display))
    }
}
