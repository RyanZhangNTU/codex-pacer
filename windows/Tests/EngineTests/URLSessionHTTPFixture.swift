#if os(Windows)
import Foundation
import FoundationNetworking

/// Intercepts only requests registered by a test, without changing proxy
/// environment variables or connecting to a provider account.
final class URLSessionHTTPFixture: @unchecked Sendable {
    private let lock = NSLock()
    private let id = UUID().uuidString
    private var transport: FixtureURLProtocol?
    private var requestsValue: [URLRequest] = []
    private var stoppedValue = false

    init() { FixtureURLProtocol.registry.put(id, self) }
    func close() { FixtureURLProtocol.registry.put(id, nil); lock.lock(); transport = nil; lock.unlock() }
    var requests: [URLRequest] { lock.lock(); defer { lock.unlock() }; return requestsValue }
    var opened: Bool { !requests.isEmpty }
    var stopped: Bool { lock.lock(); defer { lock.unlock() }; return stoppedValue }

    func request(_ url: URL) -> URLRequest {
        var request = URLRequest(url: url)
        request.setValue(id, forHTTPHeaderField: "X-Pacer-HTTP-Fixture")
        return request
    }
    func configuration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [FixtureURLProtocol.self]
        return configuration
    }
    fileprivate func open(_ transport: FixtureURLProtocol) {
        lock.lock(); self.transport = transport; stoppedValue = false; requestsValue.append(transport.request); lock.unlock()
    }
    fileprivate func stop(_ transport: FixtureURLProtocol) {
        lock.lock()
        if self.transport === transport { self.transport = nil; stoppedValue = true }
        lock.unlock()
    }
    private func current() -> FixtureURLProtocol? { lock.lock(); defer { lock.unlock() }; return transport }
    func respond(_ code: Int = 200, mime: String = "application/json", headers: [String: String] = [:]) {
        guard let transport = current() else { return }
        let response = HTTPURLResponse(url: transport.request.url!, statusCode: code, httpVersion: "HTTP/1.1",
                                      headerFields: headers.merging(["Content-Type": mime]) { first, _ in first })!
        transport.client?.urlProtocol(transport, didReceive: response, cacheStoragePolicy: .notAllowed)
    }
    func send(_ bytes: Data) { guard let transport = current() else { return }; transport.client?.urlProtocol(transport, didLoad: bytes) }
    func finish() { guard let transport = current() else { return }; transport.client?.urlProtocolDidFinishLoading(transport) }
}

fileprivate final class FixtureRegistry: @unchecked Sendable {
    private let lock = NSLock()
    private var fixtures: [String: URLSessionHTTPFixture] = [:]
    func put(_ id: String, _ fixture: URLSessionHTTPFixture?) { lock.lock(); fixtures[id] = fixture; lock.unlock() }
    func get(_ id: String) -> URLSessionHTTPFixture? { lock.lock(); defer { lock.unlock() }; return fixtures[id] }
}
fileprivate final class FixtureURLProtocol: URLProtocol {
    static let registry = FixtureRegistry()
    override class func canInit(with request: URLRequest) -> Bool { registry.get(request.value(forHTTPHeaderField: "X-Pacer-HTTP-Fixture") ?? "") != nil }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() { Self.registry.get(request.value(forHTTPHeaderField: "X-Pacer-HTTP-Fixture") ?? "")?.open(self) }
    override func stopLoading() { Self.registry.get(request.value(forHTTPHeaderField: "X-Pacer-HTTP-Fixture") ?? "")?.stop(self) }
}
#endif
