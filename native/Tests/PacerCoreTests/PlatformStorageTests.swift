import XCTest
@testable import PacerCore

final class PlatformStorageTests: XCTestCase {
    private final class Files: PlatformFileSystem, @unchecked Sendable {
        var data = Data()
        var size: UInt64 = 0
        var identity = "opaque-file-1"
        var reads = 0
        var readLimit = 0
        var failReplacement = false
        func metadata(_ url: URL) -> PlatformFileMetadata? {
            .init(identity: identity, size: size, modified: Date(timeIntervalSince1970: 10), created: nil, isRegularFile: true)
        }
        func read(_ url: URL, offset: UInt64, maximumBytes: Int) throws -> Data {
            reads += 1; readLimit = maximumBytes
            return Data(data.dropFirst(Int(offset)).prefix(maximumBytes))
        }
        func replace(_ url: URL, with data: Data) -> Bool {
            guard !failReplacement else { return false }
            self.data = data; size = UInt64(data.count); return true
        }
    }
    private final class Secrets: PlatformCredentialStore, @unchecked Sendable {
        var value: Data?
        var saves = 0
        func read() -> Data? { value }
        var exists: Bool { value != nil }
        func save(_ data: Data) -> Bool { saves += 1; value = data; return true }
        func remove() { value = nil }
    }

    func testFailedReplacementPreservesPreviousAcknowledgments() {
        let files = Files(), url = URL(fileURLWithPath: "/fixture/dismissals.json")
        let store = CompletionDismissalStore(fileURL: url, files: files)
        let first = CompletionDismissalStore.digest(["first"]), next = CompletionDismissalStore.digest(["next"])
        XCTAssertTrue(store.saveDigests([first]))
        let previous = files.data
        files.failReplacement = true
        XCTAssertFalse(store.saveDigests([next]))
        XCTAssertEqual(files.data, previous)
        XCTAssertEqual(store.loadDigests(), [first])
        XCTAssertLessThanOrEqual(files.readLimit, 64 * 1024 + 1)
        files.size = 64 * 1024 + 1
        let before = files.reads
        XCTAssertTrue(store.loadDigests().isEmpty)
        XCTAssertEqual(files.reads, before, "Oversized files must be rejected before a read")
    }

    func testFileIdentityInvalidatesAuthenticationWithoutReadingCredentials() {
        let files = Files(), home = URL(fileURLWithPath: "/fixture/home")
        let first = CodexClient.authenticationFingerprint(home: home, files: files)
        XCTAssertEqual(CodexClient.authenticationFingerprint(home: home, files: files), first)
        files.identity = "opaque-file-2"
        XCTAssertNotEqual(CodexClient.authenticationFingerprint(home: home, files: files), first)
        XCTAssertEqual(files.reads, 0)
    }

    func testKeyValidationPrecedesStorageAndInvalidStoredValuesRemainUnavailable() {
        let secrets = Secrets(), store = DeepSeekAPIKeyStore(store: secrets)
        XCTAssertFalse(store.save("short")); XCTAssertEqual(secrets.saves, 0)
        XCTAssertTrue(store.save("  sk-0123456789abcdef0123 \n"))
        XCTAssertEqual(store.read(), "sk-0123456789abcdef0123"); XCTAssertTrue(store.exists)
        secrets.value = Data("invalid stored value".utf8)
        XCTAssertNil(store.read())
        store.remove(); XCTAssertFalse(store.exists)
    }
}
