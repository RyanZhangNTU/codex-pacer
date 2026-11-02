import Foundation
import XCTest
@testable import PacerCore
@testable import PacerIsland

/// B3 will point this contract at the shared browser resource. Until then the
/// adapter reads the actual compiled strings, without keeping another script.
@MainActor
final class DeepSeekWebScriptContractTests: XCTestCase {
    private struct Script: Decodable { let name: String, sha256: String }
    private struct Contract: Decodable { let schemaVersion: Int, origin: String, scripts: [Script] }
    func testCurrentMacBrowserScriptsMatchTheFixedSharedContract() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("PresentationTables/browser-scripts.json")
        let table = try JSONDecoder().decode(Contract.self, from: Data(contentsOf: url))
        XCTAssertEqual(table.schemaVersion, 1)
        XCTAssertEqual(DeepSeekWebSessionStore.origin.absoluteString, table.origin)
        XCTAssertEqual(table.scripts.map(\.name), ["summaryScript", "sessionFingerprintScript"])
        let actual = ["summaryScript": DeepSeekWebSessionStore.summaryScript,
            "sessionFingerprintScript": DeepSeekWebSessionStore.sessionFingerprintScript]
        for row in table.scripts {
            XCTAssertEqual(ClaudeQuotaDecoder.digest(try XCTUnwrap(actual[row.name])), row.sha256, row.name)
        }
    }
}
