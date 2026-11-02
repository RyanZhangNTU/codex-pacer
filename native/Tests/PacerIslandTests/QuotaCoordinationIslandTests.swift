import Foundation
import XCTest
import PacerCore
import PacerMacSupport
@testable import PacerIsland

@MainActor
final class QuotaCoordinationIslandTests: XCTestCase {
    func testOrganizationAndSignInRevokeTheCloudOwnerBeforeReturning() async throws {
        let domain = "com.codexpacer.quota-coordination-tests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("pacer-quota-coordination-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        defaults.set(false, forKey: "monitorSSH")
        defaults.set(root.path, forKey: "codexHome")
        defaults.set(root.appendingPathComponent("claude").path, forKey: "claudeHome")
        ProviderModules(codexMode: .disabled, claudeMode: .enabled).save(to: defaults)
        var reads = ClaudeQuotaReadDependencies()
        reads.passive = { _ in nil }; reads.webSession = { nil }
        reads.compatibility = { _ in throw ClaudeQuotaError.unavailable }
        let model = IslandModel(defaults: defaults,
            installation: .init(codexInstalled: false, claudeInstalled: false), claudeQuotaReads: reads,
            completionDismissalStore: .init(fileURL: root.appendingPathComponent("dismissals.json")))
        var made = 0
        model.makeClaudeCloudMonitor = {
            made += 1
            return ClaudeCloudProjectMonitor(cookieProvider: { nil })
        }
        model.applySettings(sourceChanged: false)
        XCTAssertEqual(made, 1)
        model.retryClaudeWebConnection(organizationID: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa")
        XCTAssertEqual(made, 2, "The old Cloud source is revoked synchronously on organization selection")
        model.retryClaudeWebConnection(afterSignIn: true)
        XCTAssertEqual(made, 3, "Sign-in revokes the old owner even before queued cleanup can run")
        XCTAssertNil(defaults.string(forKey: "claudeWebOrganizationID"))
        await model.shutdown()
    }
}
