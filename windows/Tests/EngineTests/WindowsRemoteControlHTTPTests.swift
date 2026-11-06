@testable import PacerEngineSupport
#if os(Windows)
import Foundation
import FoundationNetworking
import XCTest
@testable import PacerCore

final class WindowsRemoteControlHTTPTests: XCTestCase {
    private static let path = "/backend-api/codex/remote/control/clients/fixture/environments"

    /// The production catalog client, with only its connection redirected to `server`.
    private func fixture() throws -> (LoopbackHTTPServer, WindowsHTTPClient, URLRequest) {
        let server = try LoopbackHTTPServer(), port = server.port
        var options = WindowsRemoteControlHTTP.catalog.options
        options.proxy = { _ in .success(.winHTTP(nil)) }
        options.target = { url in
            let components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
            return .init(host: "127.0.0.1", port: port, secure: false, path: components.percentEncodedPath)
        }
        var request = URLRequest(url: URL(string: "https://chatgpt.com" + Self.path)!)
        request.httpMethod = "GET"
        return (server, WindowsHTTPClient(options), request)
    }
    private func until(_ condition: () -> Bool) async throws {
        if try await TestWait.until(condition) { return }
        XCTFail("The loopback WinHTTP read did not finish its bounded operation")
        throw URLError(.timedOut)
    }
    private func serve(_ server: LoopbackHTTPServer, _ mode: String) async throws {
        try await until { server.opened }
        if mode == "wait" { return }
        let code = Int(mode) ?? 200
        var headers = ["Set-Cookie": "private=fixture"]
        if mode == "length" { headers["Content-Length"] = String(WindowsRemoteControlHTTP.maximumBytes + 1) }
        if code == 302 { headers["Location"] = "https://outside.invalid/private" }
        server.respond(code, mime: "application/json", headers: headers)
        if mode == "chunks" {
            for _ in 0..<9 { guard server.send(Data(repeating: 32, count: 65536)) else { break } }
        } else { server.send("{\"items\":[]}") }
        server.finish()
    }

    func testProductionClientKeepsNoCookiesAndUsesItsBounds() async throws {
        let limits = WindowsRemoteControlHTTP.catalog.options
        XCTAssertEqual(limits.idleTimeout, 8); XCTAssertEqual(limits.totalTimeout, 10)
        XCTAssertEqual(limits.maximumBytes, WindowsRemoteControlHTTP.maximumBytes)
        XCTAssertTrue(limits.readsBody(200)); XCTAssertFalse(limits.readsBody(401))
        let (server, client, request) = try fixture(); defer { server.stop() }
        for _ in 0..<2 {
            let count = server.requests.count
            let task = Task { try await WindowsRemoteControlHTTP.fetch(request, client: client) }
            try await until { server.requests.count == count + 1 }
            try await serve(server, "ok")
            let data = try await task.value
            XCTAssertEqual(data, Data("{\"items\":[]}".utf8))
        }
        for head in server.requests {
            XCTAssertTrue(head.hasPrefix("GET \(Self.path) HTTP/1.1\r\n"))
            XCTAssertFalse(head.lowercased().contains("\r\ncookie:"), "A response cookie is never sent back")
        }
    }

    func testStatusRedirectAndBothDeclaredAndStreamingSizeLimitsFailClosed() async throws {
        for mode in ["401", "403", "429", "302", "length", "chunks"] {
            let (server, client, request) = try fixture(); defer { server.stop() }
            let task = Task { try await WindowsRemoteControlHTTP.fetch(request, client: client) }
            try await serve(server, mode)
            do { _ = try await task.value; XCTFail("Unsafe response accepted: " + mode) }
            catch RemoteControlCatalog.CatalogError.status(let status) { XCTAssertEqual(status, Int(mode)) }
            catch { XCTAssertTrue(mode == "length" || mode == "chunks", "An HTTP status must remain classifiable") }
            try await until { server.closed }
            XCTAssertEqual(server.requests.count, 1, "Redirects are never followed")
        }
    }

    func testCancellationClosesPendingReadAndOriginValidationRunsBeforeIO() async throws {
        let (server, client, request) = try fixture(); defer { server.stop() }
        let task = Task { try await WindowsRemoteControlHTTP.fetch(request, client: client) }
        try await serve(server, "wait"); task.cancel()
        do { _ = try await task.value; XCTFail("Cancelled reads must finish") } catch is CancellationError { } catch { XCTFail("Unexpected cancellation result") }
        try await until { server.closed }
        let (unused, unusedClient, _) = try fixture(); defer { unused.stop() }
        for value in ["http://chatgpt.com/", "https://chatgpt.com.evil.invalid/", "https://user@chatgpt.com/", "https://chatgpt.com:444/", "https://chatgpt.com/#fragment"] {
            var invalid = request; invalid.url = URL(string: value)
            do { _ = try await WindowsRemoteControlHTTP.fetch(invalid, client: unusedClient); XCTFail("Untrusted origin reached IO") } catch { }
        }
        var claude = URLRequest(url: URL(string: "https://api.anthropic.com/api/oauth/usage?extra=1")!); claude.httpMethod = "GET"
        do { _ = try await WindowsRemoteControlHTTP.claudeQuota(claude, client: unusedClient); XCTFail("Untrusted usage path reached IO") } catch { }
        XCTAssertFalse(unused.opened)
    }
}
#endif
