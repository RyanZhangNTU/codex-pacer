import Foundation
import XCTest
@testable import PacerCore

final class DeepSeekWebScriptContractTests: XCTestCase {
    private struct Script: Decodable { let name: String }
    private struct Contract: Decodable { let schemaVersion: Int, origin: String, scripts: [Script] }
    func testBundledBrowserScriptsKeepTheSharedOriginAndNames() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("PresentationTables/browser-scripts.json")
        let table = try JSONDecoder().decode(Contract.self, from: Data(contentsOf: url))
        XCTAssertEqual(table.schemaVersion, 1)
        XCTAssertEqual(DeepSeekWebScripts.origin.absoluteString, table.origin)
        XCTAssertEqual(table.scripts.map(\.name), ["summaryScript", "sessionFingerprintScript"])
        let actual = ["summaryScript": DeepSeekWebScripts.summaryScript,
            "sessionFingerprintScript": DeepSeekWebScripts.sessionFingerprintScript]
        for row in table.scripts {
            XCTAssertFalse(try XCTUnwrap(actual[row.name]).isEmpty, row.name)
        }
    }
}
