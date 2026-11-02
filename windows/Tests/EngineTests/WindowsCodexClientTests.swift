#if os(Windows)
import Foundation
import WinSDK
import XCTest
@testable import PacerCore

final class WindowsCodexClientTests: XCTestCase {
    private let script = #"""
import json,os,pathlib,subprocess,sys,time
root=pathlib.Path(sys.argv[1]);mode=sys.argv[2]
assert os.path.normcase(os.environ['CODEX_HOME'])==os.path.normcase(str(root))
with (root/'pids').open('a') as file:file.write(str(os.getpid())+'\n')
if mode in ('descendant','exit'):
    child=subprocess.Popen([sys.executable,'-c','import time;time.sleep(60)'],stdin=subprocess.DEVNULL,creationflags=subprocess.CREATE_NO_WINDOW)
    with (root/'pids').open('a') as file:file.write(str(child.pid)+'\n')
if mode=='exit':
    sys.stderr.buffer.write(b'x'*200000+b'\nfixture exit email=private@fixture.invalid access_token=sk-proj-ABCDEFGHIJKLMN\n');sys.stderr.buffer.flush();sys.exit(7)
if mode=='malformed':
    sys.stdout.buffer.write(b'not JSON\n');sys.stdout.buffer.flush();time.sleep(10);sys.exit(0)
if mode=='oversize':
    sys.stdout.buffer.write(b'x'*(4*1024*1024+1));sys.stdout.buffer.flush();time.sleep(10);sys.exit(0)
def send(value):
    data=(json.dumps(value,ensure_ascii=False,separators=(',',':'))+'\n').encode('utf-8')
    if mode=='fragmented':
        for byte in data:sys.stdout.buffer.write(bytes([byte]));sys.stdout.buffer.flush()
    else:sys.stdout.buffer.write(data);sys.stdout.buffer.flush()
for line in sys.stdin.buffer:
    message=json.loads(line)
    with (root/'calls.jsonl').open('a',encoding='utf-8') as file:file.write(json.dumps(message)+'\n')
    method=message.get('method')
    assert method in ('initialize','initialized','account/read','account/rateLimits/read'),method
    if 'id' not in message:continue
    identifier=message['id']
    if method=='initialize':send({'id':identifier,'result':{}})
    elif method=='account/read':
        assert message['params']=={'refreshToken':False}
        account=None if mode=='signedout' else {'type':'apiKey' if mode=='apikey' else 'chatgpt','planType':'pro'}
        send({'id':identifier,'result':{'account':account,'workspaceRouting':{'chatgptAccountId':'fixture','backendOrigin':'https://example.invalid'}}})
    elif method=='account/rateLimits/read':
        if mode in ('hung','descendant'):continue
        if mode=='legacy' and 'params' in message:
            send({'id':identifier,'error':{'code':-32600,'message':'invalid type: map, expected unit'}});continue
        if mode=='error':
            send({'id':identifier,'error':{'code':401,'message':'email=private@fixture.invalid access_token=sk-proj-ABCDEFGHIJKLMN'}});continue
        send({'id':identifier,'result':{'fixture':'中文','accountId':'different' if mode=='mismatch' else 'fixture',
             'rateLimits':{'primary':{'usedPercent':25,'windowDurationMins':300}}}})
"""#
    private func fixture(_ mode: String, timeout: TimeInterval = 3) throws -> (CodexClient, URL) {
        let path = try XCTUnwrap(ProcessInfo.processInfo.environment["PACER_TEST_PYTHON"])
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("pacer-rpc-" + UUID().uuidString + "-中文 space")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let home = WindowsCodexExecutableDiscovery.path(directory)
        return (CodexClient(executable: URL(fileURLWithPath: path), home: directory,
            arguments: ["-u", "-c", script, home, mode], timeout: timeout), directory)
    }
    private func calls(_ root: URL) throws -> [[String: Any]] {
        let file = root.appendingPathComponent("calls.jsonl")
        guard FileManager.default.fileExists(atPath: file.path) else { return [] }
        return try Data(contentsOf: file).split(separator: 10).map { try XCTUnwrap(JSONSerialization.jsonObject(with: Data($0)) as? [String: Any]) }
    }
    func testFragmentedUnicodeRepliesReuseOneReadOnlyConnectionAndCoalesceRefreshes() async throws {
        let (client, root) = try fixture("fragmented")
        defer { try? FileManager.default.removeItem(at: root) }
        async let first = client.readQuota()
        async let second = client.readQuota()
        let result = try await [first, second]
        XCTAssertEqual(result[0], result[1]); XCTAssertEqual(result[0].windows.first?.remainingPercent, 75)
        let repeated = try await client.readQuota()
        XCTAssertEqual(repeated.windows.first?.remainingPercent, 75)
        let trace = try calls(root)
        XCTAssertEqual(trace.filter { $0["method"] as? String == "initialize" }.count, 1)
        XCTAssertEqual(trace.filter { $0["method"] as? String == "account/rateLimits/read" }.count, 2)
        let scope = await client.currentAccountScope()
        XCTAssertEqual(scope?.count, 64)
        await client.shutdown()
    }
    func testLegacyFallbackIsOncePerConnectionAndResetsAfterDisconnect() async throws {
        let (client, root) = try fixture("legacy")
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try await client.readQuota(); _ = try await client.readQuota()
        var requests = try calls(root).filter { $0["method"] as? String == "account/rateLimits/read" }
        XCTAssertEqual(requests.count, 3)
        XCTAssertNotNil(requests[0]["params"]); XCTAssertNil(requests[1]["params"]); XCTAssertNil(requests[2]["params"])
        let legacy = await client.usesLegacyRateLimitRequest(); XCTAssertTrue(legacy)
        await client.disconnect()
        _ = try await client.readQuota()
        requests = try calls(root).filter { $0["method"] as? String == "account/rateLimits/read" }
        XCTAssertEqual(requests.count, 5); XCTAssertNotNil(requests[3]["params"]); XCTAssertNil(requests[4]["params"])
        await client.shutdown()
    }
    func testAccountMismatchRejectsQuotaAndClearsItsScope() async throws {
        let (client, root) = try fixture("mismatch")
        defer { try? FileManager.default.removeItem(at: root) }
        do { _ = try await client.readQuota(); XCTFail("A mismatched account must not publish quota") }
        catch CodexClientError.accountMismatch {} catch { XCTFail("Unexpected error: \(error)") }
        let scope = await client.currentAccountScope(); XCTAssertNil(scope)
        await client.shutdown()
    }
    func testSignedOutAndUnsupportedAccountsNeverRequestQuota() async throws {
        for mode in ["signedout", "apikey"] {
            let (client, root) = try fixture(mode)
            defer { try? FileManager.default.removeItem(at: root) }
            do { _ = try await client.readQuota(); XCTFail("An unsupported account must stop before quota") }
            catch CodexClientError.notLoggedIn { XCTAssertEqual(mode, "signedout") }
            catch CodexClientError.unsupportedAccount(_) { XCTAssertEqual(mode, "apikey") }
            catch { XCTFail("Unexpected error: \(error)") }
            XCTAssertFalse(try calls(root).contains { $0["method"] as? String == "account/rateLimits/read" })
            await client.shutdown()
        }
    }
    func testServerFailurePreservesMethodAndCodeAndRedactsPrivateFields() async throws {
        let (client, root) = try fixture("error")
        defer { try? FileManager.default.removeItem(at: root) }
        do { _ = try await client.readQuota(); XCTFail("Expected a server error") }
        catch CodexClientError.server(let method, let code, let message) {
            XCTAssertEqual(method, "account/rateLimits/read"); XCTAssertEqual(code, 401)
            XCTAssertFalse(message.contains("private@fixture.invalid")); XCTAssertFalse(message.contains("sk-proj-ABCDEFGHIJKLMN"))
        } catch { XCTFail("Unexpected error: \(error)") }
        await client.shutdown()
    }
    func testEarlyExitDrainsLargeStderrAndRetainsExitStatusWithoutPrivateFields() async throws {
        let (client, root) = try fixture("exit")
        defer { try? FileManager.default.removeItem(at: root) }
        do { _ = try await client.readQuota(); XCTFail("Expected the child's failure") }
        catch CodexClientError.processExited(let status, let detail) {
            XCTAssertEqual(status, 7); XCTAssertTrue(detail.contains("fixture exit")); XCTAssertLessThan(detail.count, 1700)
            XCTAssertFalse(detail.contains("private@fixture.invalid")); XCTAssertFalse(detail.contains("sk-proj-ABCDEFGHIJKLMN"))
        } catch { XCTFail("Unexpected error: \(error)") }
        await client.shutdown()
        try await assertStopped(root, expectedCount: 2)
    }
    func testMalformedAndOversizedOutputAreProtocolFailures() async throws {
        for mode in ["malformed", "oversize"] {
            let (client, root) = try fixture(mode)
            defer { try? FileManager.default.removeItem(at: root) }
            do { _ = try await client.readQuota(); XCTFail("Invalid output must close the connection") }
            catch CodexClientError.invalidReply(let method, _) { XCTAssertEqual(method, "initialize") }
            catch { XCTFail("Unexpected \(mode) error: \(error)") }
            await client.shutdown()
        }
    }
    func testTimeoutReconnectsAndStopsOnlyItsOwnedProcessTrees() async throws {
        let (client, root) = try fixture("descendant", timeout: 1)
        let (other, otherRoot) = try fixture("fragmented")
        defer { try? FileManager.default.removeItem(at: root); try? FileManager.default.removeItem(at: otherRoot) }
        _ = try await other.readQuota()
        for _ in 0..<2 {
            do { _ = try await client.readQuota(); XCTFail("Expected a bounded timeout") }
            catch CodexClientError.timeout(let method, _) { XCTAssertEqual(method, "account/rateLimits/read") }
            catch { XCTFail("Unexpected error: \(error)") }
        }
        await client.shutdown()
        try await assertStopped(root, expectedCount: 4)
        _ = try await other.readQuota()
        XCTAssertEqual(try calls(otherRoot).filter { $0["method"] as? String == "initialize" }.count, 1,
            "Unrelated connections must keep their original helper")
        await other.shutdown()
        try await assertStopped(otherRoot, expectedCount: 1)
    }
    func testShutdownCancelsInFlightQuotaAndWaitsForItsHelperToExit() async throws {
        let (client, root) = try fixture("hung", timeout: 30)
        defer { try? FileManager.default.removeItem(at: root) }
        let reading = Task { try await client.readQuota() }
        for _ in 0..<200 {
            if try calls(root).contains(where: { $0["method"] as? String == "account/rateLimits/read" }) { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertTrue(try calls(root).contains { $0["method"] as? String == "account/rateLimits/read" })
        let started = ProcessInfo.processInfo.systemUptime
        await client.shutdown()
        if case .success = await reading.result { XCTFail("A shutdown cannot return a pending quota reading") }
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - started, 2)
        try await assertStopped(root, expectedCount: 1)
    }
    private func assertStopped(_ root: URL, expectedCount: Int, file: StaticString = #filePath, line: UInt = #line) async throws {
        let pids = try String(contentsOf: root.appendingPathComponent("pids"), encoding: .utf8)
            .split(whereSeparator: \.isNewline).map { try XCTUnwrap(DWORD($0)) }
        XCTAssertEqual(pids.count, expectedCount, file: file, line: line)
        for pid in pids {
            for _ in 0..<100 where running(pid) { try await Task.sleep(nanoseconds: 20_000_000) }
            XCTAssertFalse(running(pid), "The client must release its helpers and their descendants", file: file, line: line)
        }
    }
    private func running(_ pid: DWORD) -> Bool {
        guard let handle = OpenProcess(DWORD(PROCESS_QUERY_LIMITED_INFORMATION), false, pid) else { return false }
        defer { CloseHandle(handle) }
        var code: DWORD = 0
        return GetExitCodeProcess(handle, &code) && code == DWORD(STILL_ACTIVE)
    }
}
#endif
