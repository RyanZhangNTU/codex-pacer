@testable import PacerEngineSupport
#if os(Windows)
import Foundation
import FoundationNetworking
import XCTest
@testable import PacerCore

final class WindowsClaudeUsageHTTPTests: XCTestCase {
    private static let path = "/api/oauth/usage"

    /// The production usage client, with only its connection redirected to `server`.
    private func fixture() throws -> (LoopbackHTTPServer, WindowsHTTPClient, URLRequest) {
        let server = try LoopbackHTTPServer(), port = server.port
        var options = WindowsClaudeUsageHTTP.usage.options
        options.proxy = { _ in .success(.winHTTP(nil)) }
        options.target = { url in
            let components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
            return .init(host: "127.0.0.1", port: port, secure: false, path: components.percentEncodedPath)
        }
        var request = URLRequest(url: URL(string: "https://api.anthropic.com" + Self.path)!)
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
        if mode == "length" { headers["Content-Length"] = String(WindowsClaudeUsageHTTP.maximumBytes + 1) }
        if code == 302 { headers["Location"] = "https://outside.invalid/private" }
        server.respond(code, mime: "application/json", headers: headers)
        if mode == "chunks" {
            for _ in 0...(WindowsClaudeUsageHTTP.maximumBytes / 65536) { guard server.send(Data(repeating: 32, count: 65536)) else { break } }
        } else { server.send("{\"five_hour\":null}") }
        server.finish()
    }

    func testProductionClientKeepsNoCookiesAndUsesItsBounds() async throws {
        let limits = WindowsClaudeUsageHTTP.usage.options
        XCTAssertEqual(limits.idleTimeout, ProviderQuotaRefreshPolicy.replyTimeout)
        XCTAssertEqual(limits.totalTimeout, ProviderQuotaRefreshPolicy.replyTimeout + 3)
        XCTAssertEqual(limits.maximumBytes, WindowsClaudeUsageHTTP.maximumBytes)
        let (server, client, request) = try fixture(); defer { server.stop() }
        for _ in 0..<2 {
            let count = server.requests.count
            let task = Task { try await WindowsClaudeUsageHTTP.claudeQuota(request, client: client) }
            try await until { server.requests.count == count + 1 }
            try await serve(server, "ok")
            let (data, response) = try await task.value
            XCTAssertEqual(response.statusCode, 200)
            XCTAssertEqual(data, Data("{\"five_hour\":null}".utf8))
        }
        for head in server.requests {
            XCTAssertTrue(head.hasPrefix("GET \(Self.path) HTTP/1.1\r\n"))
            XCTAssertFalse(head.lowercased().contains("\r\ncookie:"), "A response cookie is never sent back")
        }
    }

    func testRedirectIsNotFollowedAndBothDeclaredAndStreamingSizeLimitsFailClosed() async throws {
        for mode in ["401", "429", "302", "length", "chunks"] {
            let (server, client, request) = try fixture(); defer { server.stop() }
            let task = Task { try await WindowsClaudeUsageHTTP.claudeQuota(request, client: client) }
            try await serve(server, mode)
            do {
                let (_, response) = try await task.value
                XCTAssertEqual(response.statusCode, Int(mode), "Only a status reply may complete: " + mode)
            } catch { XCTAssertTrue(mode == "length" || mode == "chunks", "An HTTP status must remain classifiable") }
            try await until { server.closed }
            XCTAssertEqual(server.requests.count, 1, "Redirects are never followed")
        }
    }

    func testCancellationClosesPendingReadAndOriginValidationRunsBeforeIO() async throws {
        let (server, client, request) = try fixture(); defer { server.stop() }
        let task = Task { try await WindowsClaudeUsageHTTP.claudeQuota(request, client: client) }
        try await serve(server, "wait"); task.cancel()
        do { _ = try await task.value; XCTFail("Cancelled reads must finish") } catch is CancellationError { } catch { XCTFail("Unexpected cancellation result") }
        try await until { server.closed }
        let (unused, unusedClient, _) = try fixture(); defer { unused.stop() }
        for value in ["http://api.anthropic.com/api/oauth/usage", "https://api.anthropic.com.evil.invalid/api/oauth/usage",
                      "https://user@api.anthropic.com/api/oauth/usage", "https://api.anthropic.com:444/api/oauth/usage",
                      "https://api.anthropic.com/api/oauth/usage#fragment", "https://api.anthropic.com/api/oauth/usage?extra=1"] {
            var invalid = request; invalid.url = URL(string: value)
            do { _ = try await WindowsClaudeUsageHTTP.claudeQuota(invalid, client: unusedClient); XCTFail("Untrusted origin reached IO") } catch { }
        }
        XCTAssertFalse(unused.opened)
    }
}
#endif
