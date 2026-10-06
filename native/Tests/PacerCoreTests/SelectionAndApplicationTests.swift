import XCTest
@testable import PacerCore

final class SelectionAndApplicationTests: XCTestCase {
    private func quota(_ id: String?) throws -> QuotaSnapshot {
        let response: [String: Any] = id.map {
            ["rateLimits": ["limitId": $0, "primary": ["usedPercent": 10, "windowDurationMins": 300]]]
        } ?? [:]
        return try QuotaSnapshot.decode(JSONSerialization.data(withJSONObject: response))
    }

    func testUnavailableQuotaPreservesChoiceAndAvailableQuotaValidatesIt() throws {
        XCTAssertEqual(QuotaWindowSelection.validated("custom/primary", snapshot: nil), "custom/primary")
        XCTAssertEqual(QuotaWindowSelection.validated("custom/primary", snapshot: try quota(nil)), "custom/primary")
        XCTAssertEqual(QuotaWindowSelection.validated("custom/primary", snapshot: try quota("custom")), "custom/primary")
        XCTAssertEqual(QuotaWindowSelection.validated("custom/primary", snapshot: try quota("codex")), "auto")
        XCTAssertEqual(QuotaWindowSelection.validated("auto", snapshot: try quota("custom")), "auto")
    }

    func testRelocatedApplicationIsFoundAndUnrelatedBundleIsRejected() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        func app(_ name: String, identifier: String) throws -> URL {
            let url = directory.appendingPathComponent(name + ".app")
            try FileManager.default.createDirectory(at: url.appendingPathComponent("Contents"), withIntermediateDirectories: true)
            let plist: [String: Any] = ["CFBundleIdentifier": identifier, "CFBundlePackageType": "APPL", "CFBundleName": name]
            try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
                .write(to: url.appendingPathComponent("Contents/Info.plist"))
            return url
        }
        let wrong = try app("Codex", identifier: "test.unrelated")
        let moved = try app("Relocated Codex", identifier: "com.openai.codex")
        XCTAssertEqual(CodexApplicationResolver.find(applicationURLs: [wrong, moved]), moved)
        XCTAssertNil(CodexApplicationResolver.find(applicationURLs: [wrong]))
        XCTAssertNil(CodexApplicationResolver.find(applicationURLs: [directory.appendingPathComponent("Missing.app")]))
    }
}
