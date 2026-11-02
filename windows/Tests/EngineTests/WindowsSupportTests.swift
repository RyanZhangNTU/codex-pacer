import Foundation
import XCTest
#if os(Windows)
import WinSDK
#endif
@testable import PacerCore

final class WindowsSupportTests: XCTestCase {
    func testDigestMatchesMacLengthPrefixedIdentity() {
        XCTAssertEqual(CompletionDismissalStore.digest([]),
            "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
        XCTAssertNotEqual(CompletionDismissalStore.digest(["a", "bc"]),
                          CompletionDismissalStore.digest(["ab", "c"]))
    }
    #if os(Windows)
    func testDeepSeekSemaphoreObservationDoesNotAcquireCreateOrKeepTheLock() throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("pacer-lock-" + UUID().uuidString).appendingPathComponent("session.lock")
        XCTAssertTrue(DeepSeekSessionLocks.held(["fixture": path]).isEmpty)
        let name = Array((DeepSeekSessionLocks.name(for: path) + "\0").utf16)
        let handle = try XCTUnwrap(name.withUnsafeBufferPointer { CreateSemaphoreW(nil, 1, 1, $0.baseAddress) })
        XCTAssertEqual(DeepSeekSessionLocks.held(["fixture": path]), ["fixture"])
        XCTAssertEqual(WaitForSingleObject(handle, 0), DWORD(WAIT_OBJECT_0), "Observation must not take the semaphore")
        XCTAssertEqual(DeepSeekSessionLocks.held(["fixture": path]), ["fixture"])
        CloseHandle(handle)
        XCTAssertTrue(DeepSeekSessionLocks.held(["fixture": path]).isEmpty, "The observer must not retain a handle")
        XCTAssertFalse(FileManager.default.fileExists(atPath: path.path))
    }
    #endif
}
