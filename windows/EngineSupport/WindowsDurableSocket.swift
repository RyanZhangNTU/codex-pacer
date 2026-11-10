#if os(Windows)
import Foundation
import FoundationNetworking
import PacerCore

/// A serial worker owns the WinHTTP handles. Cancellation wakes the native
/// wait before the worker releases them, including during the upgrade.
final class WindowsDurableSocket: DurableCatalogSocket, @unchecked Sendable {
    private static let host = "codex-cloud-backend.chatgpt.com"
    private static let limit = 4 * 1024 * 1024
    private let worker = DispatchQueue(label: "pacer.durable-socket", qos: .utility)
    private let stream: WindowsHTTPStream
    private let target: WindowsHTTPStream.Target
    private let agent: String
    private let route: WindowsHTTPProxy.Route
    private var headers: [(name: String, value: String)]?
    private var relay: WindowsProxyRelay?

    convenience init(_ request: URLRequest) throws {
        guard request.url?.absoluteString == "wss://\(Self.host)/", let fields = WindowsHTTPStream.fields(of: request) else {
            throw WindowsHTTPStream.Failure.failed
        }
        try self.init(target: .init(host: Self.host, port: 443, secure: true, path: "/"),
            headers: fields.headers, agent: fields.agent, route: WindowsHTTPProxy.forHTTPS(host: Self.host).get())
    }

    init(target: WindowsHTTPStream.Target, headers: [(name: String, value: String)] = [],
         agent: String = "CodexPacer", route: WindowsHTTPProxy.Route = .winHTTP(nil)) throws {
        guard let stream = WindowsHTTPStream() else { throw WindowsHTTPStream.Failure.failed }
        self.stream = stream; self.target = target; self.headers = headers; self.agent = agent; self.route = route
    }

    func send(_ bytes: Data) async throws {
        try await perform {
            if let headers = self.headers {
                self.headers = nil
                let proxy: String?
                switch self.route {
                case .winHTTP(let address): proxy = address
                case .relay(let upstream):
                    guard let relay = WindowsProxyRelay(upstream, target: self.target, timeout: 8) else { throw WindowsHTTPStream.Failure.failed }
                    self.relay = relay; proxy = relay.address
                case .urlSession: throw WindowsHTTPStream.Failure.failed
                }
                _ = try self.stream.open(self.target, headers: headers, agent: self.agent, proxy: proxy, timeout: 8, webSocket: true).get()
            }
            try self.stream.sendSocket(bytes, timeout: 8)
        }
    }

    func receive() async throws -> Data {
        try await perform {
            var bytes = [UInt8](repeating: 0, count: 16 * 1024), result = Data()
            // The RPC timer also bounds a peer that keeps sending fragments.
            for _ in 0..<4096 {
                let chunk = try self.stream.readSocket(into: &bytes, timeout: 8)
                guard result.count + chunk.count <= Self.limit else { throw WindowsHTTPStream.Failure.failed }
                result.append(contentsOf: bytes.prefix(chunk.count))
                if chunk.complete { return result }
            }
            throw WindowsHTTPStream.Failure.failed
        }
    }

    func close() {
        stream.cancel()
        worker.async {
            self.headers = nil
            self.stream.close()
            self.relay?.close(); self.relay = nil
        }
    }

    private func perform<T: Sendable>(_ operation: @escaping @Sendable () throws -> T) async throws -> T {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                worker.async { continuation.resume(with: Result(catching: operation)) }
            }
        } onCancel: { close() }
    }
}
#endif
