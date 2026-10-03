import Foundation
import XCTest
@testable import PacerCore

final class PreferencesMigrationTests: XCTestCase {
    func testMigrationPreservesUserChoicesWithoutImportingUnrelatedDataOrOverwritingProduction() throws {
        let name = "pacer-migration-test-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set(false, forKey: "showInMenuBar")
        PreferencesMigration.migrate(to: defaults, from: [
            "showInMenuBar": true, "glassCornerRadius": 31.0,
            "completedRetentionMinutes": 0, "codexHome": "/fixture/.codex", "unrelated": "private"
        ])
        XCTAssertFalse(defaults.bool(forKey: "showInMenuBar"))
        XCTAssertEqual(defaults.double(forKey: "glassCornerRadius"), 31)
        XCTAssertEqual(defaults.integer(forKey: "completedRetentionMinutes"), 0)
        XCTAssertEqual(defaults.string(forKey: "codexHome"), "/fixture/.codex")
        XCTAssertNil(defaults.object(forKey: "unrelated"))
        defaults.removeObject(forKey: "codexHome")
        PreferencesMigration.migrate(to: defaults, from: ["codexHome": "/fixture/.codex"])
        XCTAssertNil(defaults.object(forKey: "codexHome"))
    }
}
