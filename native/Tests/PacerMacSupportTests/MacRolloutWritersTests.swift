import XCTest
import PacerMacSupport

/// The Mac's answer to "does any process still write this rollout?", on real files
/// held by this test process.
final class MacRolloutWritersTests: XCTestCase {
    private func file() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("pacer-writer-\(UUID().uuidString).jsonl")
        try Data("{}\n".utf8).write(to: url)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
    private func probe(_ url: URL) -> Bool? { MacRolloutWriters.probe(url, url.deletingLastPathComponent()) }

    func testOnlyAnOpenWriteHandleCountsAsAWriter() throws {
        let url = try file()
        XCTAssertEqual(probe(url), false, "No process holds it")

        let reader = try FileHandle(forReadingFrom: url)
        XCTAssertEqual(probe(url), false, "A reader, such as Pacer itself, is not a writer")

        let writer = try FileHandle(forWritingTo: url)
        XCTAssertEqual(probe(url), true)
        try writer.close()
        XCTAssertEqual(probe(url), false, "The writer closed it")

        let updater = try FileHandle(forUpdating: url)
        XCTAssertEqual(probe(url), true, "Codex holds its rollouts open for reading and writing")
        try updater.close(); try reader.close()
    }

    func testAMissingFileIsUnknown() throws {
        let url = try file()
        try FileManager.default.removeItem(at: url)
        XCTAssertNil(probe(url), "Nothing can be said about a file that is gone")
    }
}
