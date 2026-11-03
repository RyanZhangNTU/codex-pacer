import Foundation
import XCTest
@testable import PacerCore
import PacerMacSupport

final class ClientTests: XCTestCase {
    func testReusableTransportAndConcurrentRefresh() async throws {
        let (client, directory) = try fixture(timeout: 2, answerQuota: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        async let first = client.readQuota()
        async let second = client.readQuota()
        let snapshots = try await [first, second]
        XCTAssertEqual(snapshots[0], snapshots[1])
        XCTAssertEqual(snapshots.first?.windows.first?.remainingPercent, 75)
        let repeated = try await client.readQuota()
        XCTAssertEqual(repeated.windows.first?.remainingPercent, 75)
        await client.disconnect()
    }
    func testUnresponsiveChildTimesOutAndCanReconnect() async throws {
        let (client, directory) = try fixture(timeout: 0.2, answerQuota: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        for _ in 0..<2 {
            do { _ = try await client.readQuota(); XCTFail("expected timeout") }
            catch { XCTAssertTrue(error is CodexClientError) }
        }
        await client.disconnect()
    }
    func testUsageFromDifferentAccountIsRejected() async throws {
        let (client, directory) = try fixture(timeout: 2, answerQuota: true, differentAccount: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        do { _ = try await client.readQuota(); XCTFail("expected account mismatch rejection") }
        catch CodexClientError.accountMismatch { }
        catch { XCTFail("unexpected error: \(error)") }
        let scope = await client.currentAccountScope()
        XCTAssertNil(scope)
        await client.disconnect()
    }
    private func fixture(timeout: TimeInterval, answerQuota: Bool, differentAccount: Bool = false) throws -> (CodexClient, URL) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let script = directory.appendingPathComponent("server.sh")
        let identity = differentAccount ? "\"accountId\":\"different\"," : ""
        let quota = answerQuota ? "printf '{\"id\":%s,\"result\":{\(identity)\"rateLimits\":{\"primary\":{\"usedPercent\":25,\"windowDurationMins\":300}}}}\\n' \"$id\"" : ":"
        let body = #"""
        while IFS= read -r line; do
          id=$(printf '%s' "$line" | sed -n 's/.*"id":\([0-9]*\).*/\1/p')
          [ -n "$id" ] || continue
          case "$line" in
            *initialize*) printf '{"id":%s,"result":{}}\n' "$id" ;;
            *account/read*) printf '{"id":%s,"result":{"account":{"type":"chatgpt","planType":"pro"},"workspaceRouting":{"chatgptAccountId":"fixture","backendOrigin":"test"}}}\n' "$id" ;;
            *account/rateLimits/read*) \#(quota) ;;
          esac
        done
        """#
        try Data(body.utf8).write(to: script)
        return (CodexClient(executable: URL(fileURLWithPath: "/bin/sh"), home: directory, arguments: [script.path], timeout: timeout), directory)
    }
}

