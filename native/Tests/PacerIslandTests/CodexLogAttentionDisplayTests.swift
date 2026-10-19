import XCTest
@testable import PacerCore
@testable import PacerIsland

@MainActor
final class CodexLogAttentionDisplayTests: XCTestCase {
    private let thread = "019a0000-0000-7000-8000-0000000000e1"
    private let epoch = Date(timeIntervalSince1970: 1_800_000_000)

    func testLogFallbackAndDesktopApprovalCoexistWithoutDuplicatingInput() async throws {
        let model = try fixture()
        let activity = task()
        let logged = request("log", kind: .input)
        let live = request("desktop", kind: .input)
        let approval = request("approval", kind: .approval)
        model.receiveLocalUpdate([activity], requests: [logged])
        XCTAssertEqual(model.pendingInputRequests.map(\.id), [logged.id])
        XCTAssertEqual(model.headerActivity().attention, .input)
        model.receiveRemoteUpdate([], statuses: [:], unavailable: [], requests: [approval], names: [])
        XCTAssertEqual(Set(model.pendingInputRequests.map(\.id)), [logged.id, approval.id])
        model.receiveRemoteUpdate([], statuses: [:], unavailable: [], requests: [approval, live], names: [])
        XCTAssertEqual(Set(model.pendingInputRequests.map(\.id)), [live.id, approval.id])
        model.receiveRemoteUpdate([], statuses: [:], unavailable: [], requests: [approval], names: [])
        XCTAssertEqual(Set(model.pendingInputRequests.map(\.id)), [logged.id, approval.id])
        model.receiveLocalUpdate([activity], requests: [])
        XCTAssertEqual(model.pendingInputRequests.map(\.id), [approval.id], "A logged reply clears only the question")
        model.receiveRemoteUpdate([], statuses: [:], unavailable: [], requests: [], names: [])
        XCTAssertTrue(model.pendingInputRequests.isEmpty)
        XCTAssertEqual(model.activities.first?.phase, .running, "Attention cannot pause or finish ongoing work")
        await model.shutdown()
    }

    func testNewRuntimeTurnOrEndingSuppressesStaleLogQuestion() async throws {
        let model = try fixture()
        model.receiveLocalUpdate([task()], requests: [request("log", kind: .input)])
        var live = task()
        live.applyRuntime(["method": "turn/started", "threadId": thread, "turnId": "new-turn", "at": epoch.addingTimeInterval(20).timeIntervalSince1970])
        model.receiveRemoteUpdate([live], statuses: [:], unavailable: [], requests: [], names: [])
        XCTAssertTrue(model.pendingInputRequests.isEmpty)
        live = task()
        live.applyRuntime(["method": "turn/completed", "threadId": thread, "turnId": "turn-a", "status": "completed", "at": epoch.addingTimeInterval(30).timeIntervalSince1970])
        model.receiveRemoteUpdate([live], statuses: [:], unavailable: [], requests: [], names: [])
        XCTAssertTrue(model.pendingInputRequests.isEmpty)
        await model.shutdown()
    }

    private func request(_ id: String, kind: PendingAttentionRequest.Kind) -> PendingAttentionRequest {
        PendingAttentionRequest(id: id, threadID: thread, sourceHostID: nil, sourceName: nil,
            kind: kind, detectedAt: epoch.addingTimeInterval(10))
    }
    private func task() -> SessionActivity {
        var activity = SessionActivity(id: thread)
        activity.applyRuntime(["method": "turn/started", "threadId": thread, "turnId": "turn-a", "at": epoch.timeIntervalSince1970])
        return activity
    }
    private func fixture() throws -> IslandModel {
        let domain = "com.codexpacer.log-attention-tests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: domain))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("pacer-log-attention-model-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { defaults.removePersistentDomain(forName: domain); try? FileManager.default.removeItem(at: root) }
        defaults.set(root.appendingPathComponent("codex").path, forKey: "codexHome")
        defaults.set(root.appendingPathComponent("claude").path, forKey: "claudeHome")
        defaults.set(false, forKey: "monitorSSH")
        defaults.set(false, forKey: "monitorRemoteControl")
        ProviderModules(codexMode: .enabled, claudeMode: .disabled).save(to: defaults)
        let model = IslandModel(defaults: defaults,
            installation: ProviderInstallationDetection(codexInstalled: false, claudeInstalled: false),
            completionDismissalStore: CompletionDismissalStore(fileURL: root.appendingPathComponent("dismissals.json")))
        model.hostApplicationResolver = { _, _, _ in [:] }
        return model
    }
}
