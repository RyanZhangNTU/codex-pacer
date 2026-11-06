@testable import PacerEngineSupport
#if os(Windows)
import Foundation
import FoundationNetworking
import WinSDK
import XCTest
@testable import PacerCore

private final class RelayLines: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Data] = [], ended = false
    var lines: [Data] { lock.withLock { values } }
    var finished: Bool { lock.withLock { ended } }
    func append(_ value: Data) { lock.withLock { values.append(value) } }
    func finish() { lock.withLock { ended = true } }
}

/// WinHTTP reaches SOCKS and authenticated proxies through `WindowsProxyRelay`.
/// The loopback server plays the proxy and then serves the tunnelled request.
final class WindowsProxyRelayTests: XCTestCase {
    private static let path = "/v1/code/fixture?page=1"
    private typealias Upstream = WindowsHTTPProxy.Upstream

    private func client(_ upstream: Upstream, host: String = "pacer-fixture.invalid") -> WindowsHTTPClient {
        var options = WindowsHTTPClient.Options(idleTimeout: 5, totalTimeout: 20, maximumBytes: 4096)
        options.proxy = { _ in .success(.relay(upstream)) }
        options.target = { _ in .init(host: host, port: 80, secure: false, path: Self.path) }
        return WindowsHTTPClient(options)
    }
    private let request = URLRequest(url: URL(string: "https://claude.ai" + path)!)
    private func until(_ condition: () -> Bool) async throws {
        if try await TestWait.until(condition) { return }
        XCTFail("The relayed request did not finish its bounded operation")
        throw URLError(.timedOut)
    }
    private func processorSeconds() -> TimeInterval {
        var creation = FILETIME(), exit = FILETIME(), kernel = FILETIME(), user = FILETIME()
        guard GetProcessTimes(GetCurrentProcess(), &creation, &exit, &kernel, &user) else { return .infinity }
        func seconds(_ time: FILETIME) -> TimeInterval { TimeInterval(UInt64(time.dwHighDateTime) << 32 | UInt64(time.dwLowDateTime)) / 10_000_000 }
        return seconds(kernel) + seconds(user)
    }
    /// One relayed GET; returns the body.
    private func read(_ client: WindowsHTTPClient, from server: LoopbackHTTPServer) async throws -> Data {
        let task = Task { try await client.data(for: request) }
        try await until { server.opened }
        server.respond(200, mime: "application/json", headers: ["Content-Length": "2"]); server.send("{}")
        return try await task.value.0
    }

    func testSocks5hCredentialsCarryRequestsInOriginForm() async throws {
        let server = try LoopbackHTTPServer(proxy: .socks5(credentials: true)); defer { server.stop() }
        let upstream = Upstream(kind: .socks5h, host: "127.0.0.1", port: server.port, username: "fixture", password: "p@ss:word")
        let data = try await read(client(upstream), from: server)
        XCTAssertEqual(data, Data("{}".utf8))
        XCTAssertEqual(server.proxyRequests, [.init(version: 5, methods: [0, 2], username: "fixture", password: "p@ss:word",
                                                    destination: "pacer-fixture.invalid", port: 80, authorization: nil)])
        let head = try XCTUnwrap(server.requests.first)
        XCTAssertTrue(head.hasPrefix("GET \(Self.path) HTTP/1.1\r\n"), "The relay forwards origin form")
        XCTAssertFalse(head.lowercased().contains("\r\nproxy-"), "Proxy headers stay with the relay")
    }

    func testSocks4aSocks5AndAuthenticatedHTTPUpstreams() async throws {
        let socks4 = try LoopbackHTTPServer(proxy: .socks4); defer { socks4.stop() }
        _ = try await read(client(Upstream(kind: .socks4a, host: "127.0.0.1", port: socks4.port, username: "fixture", password: "")), from: socks4)
        XCTAssertEqual(socks4.proxyRequests.map(\.destination), ["pacer-fixture.invalid"])
        XCTAssertEqual(socks4.proxyRequests.map(\.username), ["fixture"])

        // Plain SOCKS5 resolves locally, as libcurl does, and sends an address.
        // WinHTTP bypasses proxies for loopback names, so the target is a
        // documentation address that only the proxy fixture ever answers for.
        let socks5 = try LoopbackHTTPServer(proxy: .socks5(credentials: false)); defer { socks5.stop() }
        _ = try await read(client(Upstream(kind: .socks5, host: "127.0.0.1", port: socks5.port, username: nil, password: nil), host: "198.51.100.7"), from: socks5)
        XCTAssertEqual(socks5.proxyRequests.map(\.methods), [[0]])
        XCTAssertEqual(socks5.proxyRequests.map(\.destination), ["198.51.100.7"])

        let http = try LoopbackHTTPServer(proxy: .httpConnect); defer { http.stop() }
        _ = try await read(client(Upstream(kind: .http, host: "127.0.0.1", port: http.port, username: "user", password: "fixture")), from: http)
        XCTAssertEqual(http.proxyRequests, [.init(version: 1, username: nil, password: nil, destination: "pacer-fixture.invalid",
                                                  port: 80, authorization: "Basic dXNlcjpmaXh0dXJl")])
    }

    /// The point of the relay: an idle message stream through a SOCKS proxy
    /// must wait for data without using the processor.
    func testRelayedIdleStreamWaitsWithoutUsingTheProcessor() async throws {
        let server = try LoopbackHTTPServer(proxy: .socks5(credentials: false)); defer { server.stop() }
        var options = WindowsClaudeCloudStream.Options()
        options.idleTimeout = 30
        let port = server.port
        options.proxy = { _ in .success(.relay(.init(kind: .socks5h, host: "127.0.0.1", port: port, username: nil, password: nil))) }
        options.target = { _ in .init(host: "pacer-fixture.invalid", port: 80, secure: false, path: "/v1/code/channels/chan_fixture1/messages/stream") }
        let stream = WindowsClaudeCloudStream.lines(options)(URLRequest(url: URL(string: "https://claude.ai/v1/code/channels/chan_fixture1/messages/stream")!))
        let result = RelayLines()
        let task = Task { do { for try await line in stream { result.append(line) } } catch {}; result.finish() }
        defer { task.cancel() }
        try await until { server.opened }
        server.respond(); server.send(": keepalive\nevent: ready\n")
        try await until { result.lines.count == 2 }
        let start = processorSeconds(), clock = ProcessInfo.processInfo.systemUptime
        try await Task.sleep(nanoseconds: 3_000_000_000)
        let used = processorSeconds() - start, elapsed = ProcessInfo.processInfo.systemUptime - clock
        XCTAssertLessThan(used, 0.1 * elapsed, "An idle relayed stream used \(used) s of CPU in \(elapsed) s")
        server.send("data: after idle\n")
        try await until { result.lines.count == 3 }
        task.cancel()
        try await until { server.closed && result.finished }
    }

    func testRelayRefusesOtherTargetsAndFailedProxiesNeverConnectDirectly() async throws {
        let server = try LoopbackHTTPServer(proxy: .socks5(credentials: false)); defer { server.stop() }
        let relay = try XCTUnwrap(WindowsProxyRelay(.init(kind: .socks5h, host: "127.0.0.1", port: server.port, username: nil, password: nil),
                                                    target: .init(host: "claude.ai", port: 443, secure: true, path: "/"), timeout: 5))
        defer { relay.close() }
        for line in ["CONNECT outside.invalid:443 HTTP/1.1", "CONNECT claude.ai:444 HTTP/1.1", "GET http://outside.invalid/ HTTP/1.1",
                     "POST /v1 HTTP/1.1"] {
            let reply = try exchange(relay.address, line + "\r\nHost: fixture\r\n\r\n")
            XCTAssertTrue(reply.hasPrefix("HTTP/1.1 403") || reply.hasPrefix("HTTP/1.1 405"), line + ": " + reply)
        }
        XCTAssertTrue(server.proxyRequests.isEmpty, "A refused target never reaches the upstream proxy")

        // A refused tunnel is a connection failure, never a response.
        let refusing = try LoopbackHTTPServer(proxy: .socks5(credentials: false, refuse: true)); defer { refusing.stop() }
        do { _ = try await client(Upstream(kind: .socks5h, host: "127.0.0.1", port: refusing.port, username: nil, password: nil)).data(for: request); XCTFail("A refused tunnel must fail") }
        catch is URLError { }
        XCTAssertFalse(refusing.proxyRequests.isEmpty); XCTAssertTrue(refusing.requests.isEmpty)

        // Nothing listens on the closed proxy port; the request fails instead of going direct.
        let closed = try LoopbackHTTPServer(); let unused = closed.port; closed.stop()
        do { _ = try await client(Upstream(kind: .socks5, host: "127.0.0.1", port: unused, username: nil, password: nil)).data(for: request); XCTFail("An unreachable proxy must fail") }
        catch is URLError { }
    }

    /// Sends one request head to the relay and returns its reply.
    private func exchange(_ address: String, _ text: String) throws -> String {
        let port = try XCTUnwrap(UInt16(address.split(separator: ":").last ?? ""))
        let socket = WinSDK.socket(AF_INET, SOCK_STREAM, IPPROTO_TCP.rawValue)
        guard socket != INVALID_SOCKET else { throw URLError(.cannotConnectToHost) }
        defer { closesocket(socket) }
        var timeout = DWORD(5000)
        _ = withUnsafeBytes(of: &timeout) { setsockopt(socket, SOL_SOCKET, SO_RCVTIMEO, $0.baseAddress!.assumingMemoryBound(to: CChar.self), Int32($0.count)) }
        var address = sockaddr_in()
        address.sin_family = ADDRESS_FAMILY(AF_INET); address.sin_port = port.bigEndian
        address.sin_addr.S_un.S_addr = UInt32(0x0100_007F)
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(socket, $0, Int32(MemoryLayout<sockaddr_in>.size)) == 0 }
        }
        guard connected else { throw URLError(.cannotConnectToHost) }
        let bytes = Array(text.utf8)
        _ = bytes.withUnsafeBufferPointer { WinSDK.send(socket, UnsafeRawPointer($0.baseAddress!).assumingMemoryBound(to: CChar.self), Int32($0.count), 0) }
        var reply = [UInt8](repeating: 0, count: 512)
        let count = reply.withUnsafeMutableBufferPointer { recv(socket, UnsafeMutableRawPointer($0.baseAddress!).assumingMemoryBound(to: CChar.self), Int32($0.count), 0) }
        return count > 0 ? String(decoding: reply.prefix(Int(count)), as: UTF8.self) : ""
    }
}
#endif
