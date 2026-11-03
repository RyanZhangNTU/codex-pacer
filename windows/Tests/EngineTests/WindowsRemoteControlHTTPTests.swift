@testable import PacerEngineSupport
#if os(Windows)
import Foundation
import FoundationNetworking
import XCTest
@testable import PacerCore

private final class RemoteHTTPRequests: @unchecked Sendable {
    private let lock = NSLock()
    private var ids: Set<String> = []
    func record(_ id: String) { lock.lock(); ids.insert(id); lock.unlock() }
    func has(_ id: String) -> Bool { lock.lock(); defer { lock.unlock() }; return ids.contains(id) }
}
private final class RemoteHTTPProtocol: URLProtocol {
    static let requests = RemoteHTTPRequests()
    override class func canInit(with request: URLRequest) -> Bool { request.value(forHTTPHeaderField: "X-Fixture") != nil }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}
    override func startLoading() {
        Self.requests.record(request.value(forHTTPHeaderField: "X-Fixture")!)
        let mode = request.value(forHTTPHeaderField: "X-Mode") ?? "ok"
        if mode == "wait" { return }
        let code = Int(mode) ?? 200
        var headers = ["Content-Type": "application/json", "Set-Cookie": "private=fixture"]
        if mode == "length" { headers["Content-Length"] = String(WindowsRemoteControlHTTP.maximumBytes + 1) }
        if code == 302 { headers["Location"] = "https://outside.invalid/private" }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: code, httpVersion: nil, headerFields: headers)!, cacheStoragePolicy: .notAllowed)
        if mode == "chunks" {
            for _ in 0..<9 { client?.urlProtocol(self, didLoad: Data(repeating: 32, count: 65536)) }
        } else { client?.urlProtocol(self, didLoad: Data("{\"items\":[]}".utf8)) }
        client?.urlProtocolDidFinishLoading(self)
    }
}
final class WindowsRemoteControlHTTPTests: XCTestCase {
    private func fixture(_ mode: String) -> (URLRequest, URLSessionConfiguration) {
        var request = URLRequest(url: URL(string: "https://chatgpt.com/backend-api/codex/remote/control/clients/fixture/environments")!)
        request.httpMethod = "GET"
        request.setValue(UUID().uuidString, forHTTPHeaderField: "X-Fixture"); request.setValue(mode, forHTTPHeaderField: "X-Mode")
        let configuration = URLSessionConfiguration.ephemeral; configuration.protocolClasses = [RemoteHTTPProtocol.self]
        return (request, configuration)
    }
    func testProductionSessionDoesNotPersistCookiesCredentialsOrCache() async throws {
        let (request, configuration) = fixture("ok")
        let data = try await WindowsRemoteControlHTTP.fetch(request, configuration: configuration)
        XCTAssertEqual(data, Data("{\"items\":[]}".utf8))
        XCTAssertNil(configuration.httpCookieStorage); XCTAssertNil(configuration.urlCache); XCTAssertNil(configuration.urlCredentialStorage)
        XCTAssertFalse(configuration.httpShouldSetCookies); XCTAssertEqual(configuration.requestCachePolicy, .reloadIgnoringLocalCacheData)
        XCTAssertEqual(configuration.timeoutIntervalForRequest, 8); XCTAssertEqual(configuration.timeoutIntervalForResource, 10)
    }
    func testStatusRedirectAndBothDeclaredAndStreamingSizeLimitsFailClosed() async throws {
        for mode in ["401", "403", "429", "302", "length", "chunks"] {
            let (request, configuration) = fixture(mode)
            do { _ = try await WindowsRemoteControlHTTP.fetch(request, configuration: configuration); XCTFail("Unsafe response accepted: " + mode) }
            catch RemoteControlCatalog.CatalogError.status(let status) { XCTAssertEqual(status, Int(mode)) }
            catch { XCTAssertTrue(mode == "length" || mode == "chunks", "An HTTP status must remain classifiable") }
        }
    }
    func testCancellationClosesPendingReadAndOriginValidationRunsBeforeIO() async throws {
        let (request, configuration) = fixture("wait"), id = request.value(forHTTPHeaderField: "X-Fixture")!
        let task = Task { try await WindowsRemoteControlHTTP.fetch(request, configuration: configuration) }
        let end = Date().addingTimeInterval(3)
        while !RemoteHTTPProtocol.requests.has(id), Date() < end { try await Task.sleep(nanoseconds: 5_000_000) }
        XCTAssertTrue(RemoteHTTPProtocol.requests.has(id)); task.cancel()
        do { _ = try await task.value; XCTFail("Cancelled reads must finish") } catch is CancellationError { } catch { XCTFail("Unexpected cancellation result") }
        for value in ["http://chatgpt.com/", "https://chatgpt.com.evil.invalid/", "https://user@chatgpt.com/", "https://chatgpt.com:444/", "https://chatgpt.com/#fragment"] {
            var invalid = request; invalid.url = URL(string: value); invalid.setValue(UUID().uuidString, forHTTPHeaderField: "X-Fixture")
            do { _ = try await WindowsRemoteControlHTTP.fetch(invalid, configuration: configuration); XCTFail("Untrusted origin reached IO") } catch { }
            XCTAssertFalse(RemoteHTTPProtocol.requests.has(invalid.value(forHTTPHeaderField: "X-Fixture")!))
        }
    }
}
#endif
