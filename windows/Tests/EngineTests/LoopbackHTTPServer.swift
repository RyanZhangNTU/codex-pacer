@testable import PacerEngineSupport
#if os(Windows)
import Foundation
import FoundationNetworking
import WinSDK

/// A loopback HTTP/1.1 server for one connection at a time. It records request
/// heads and notices when the client closes its connection. As a proxy
/// fixture it first completes a SOCKS or HTTP CONNECT handshake on the same
/// connection, records it, and then serves the tunnelled request itself.
final class LoopbackHTTPServer: @unchecked Sendable {
    enum ProxyMode: Sendable { case socks4, socks5(credentials: Bool, refuse: Bool = false), httpConnect }
    struct ProxyRequest: Equatable, Sendable {
        var version: UInt8, methods: [UInt8] = [], username: String?, password: String?
        var destination: String, port: UInt16, authorization: String?
    }
    private let lock = NSLock()
    private let listener: SOCKET
    let port: UInt16
    private let proxy: ProxyMode?
    private var client: SOCKET = INVALID_SOCKET
    private var heads: [String] = []
    private var tunnels: [ProxyRequest] = []
    private var closedValue = false

    init(proxy: ProxyMode? = nil) throws {
        self.proxy = proxy
        var data = WSADATA()
        guard WSAStartup(0x0202, &data) == 0 else { throw URLError(.cannotConnectToHost) }
        let socket = WinSDK.socket(AF_INET, SOCK_STREAM, IPPROTO_TCP.rawValue)
        guard socket != INVALID_SOCKET else { throw URLError(.cannotConnectToHost) }
        var address = sockaddr_in()
        address.sin_family = ADDRESS_FAMILY(AF_INET)
        address.sin_addr.S_un.S_addr = UInt32(0x0100_007F) // 127.0.0.1 in network order
        var length = Int32(MemoryLayout<sockaddr_in>.size)
        let bound = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(socket, $0, length) == 0 && listen(socket, 4) == 0 && getsockname(socket, $0, &length) == 0
            }
        }
        guard bound else { closesocket(socket); throw URLError(.cannotConnectToHost) }
        listener = socket; port = UInt16(bigEndian: address.sin_port)
        Thread { [weak self, socket] in
            while true {
                let client = accept(socket, nil, nil)
                guard client != INVALID_SOCKET else { return }
                guard let self else { closesocket(client); return }
                self.serve(client)
            }
        }.start()
    }

    private func exact(_ socket: SOCKET, _ count: Int) -> [UInt8]? {
        var bytes = [UInt8](repeating: 0, count: count), offset = 0
        while offset < count {
            let received = bytes.withUnsafeMutableBufferPointer {
                recv(socket, UnsafeMutableRawPointer($0.baseAddress!.advanced(by: offset)).assumingMemoryBound(to: CChar.self), Int32(count - offset), 0)
            }
            guard received > 0 else { return nil }
            offset += Int(received)
        }
        return bytes
    }
    private func line(_ socket: SOCKET) -> String? {
        var bytes: [UInt8] = []
        while bytes.count < 8192, bytes.suffix(4) != [13, 10, 13, 10] {
            guard let byte = exact(socket, 1) else { return nil }
            bytes += byte
        }
        return String(decoding: bytes, as: UTF8.self)
    }
    private func reply(_ socket: SOCKET, _ bytes: [UInt8]) {
        _ = bytes.withUnsafeBufferPointer { WinSDK.send(socket, UnsafeRawPointer($0.baseAddress!).assumingMemoryBound(to: CChar.self), Int32($0.count), 0) }
    }
    /// The proxy side of the handshake; false closes the connection.
    private func handshake(_ socket: SOCKET, _ mode: ProxyMode) -> Bool {
        var request: ProxyRequest
        switch mode {
        case .socks4:
            guard let fixed = exact(socket, 8), fixed[0] == 4, fixed[1] == 1 else { return false }
            func string() -> String? {
                var bytes: [UInt8] = []
                while let byte = exact(socket, 1), byte[0] != 0 { bytes += byte; if bytes.count > 255 { return nil } }
                return String(decoding: bytes, as: UTF8.self)
            }
            guard let user = string() else { return false }
            var destination = fixed[4...7].map(String.init).joined(separator: ".")
            if fixed[4...6] == [0, 0, 0], fixed[7] != 0 { guard let host = string() else { return false }; destination = host }
            request = .init(version: 4, username: user.isEmpty ? nil : user, password: nil, destination: destination,
                            port: UInt16(fixed[2]) << 8 | UInt16(fixed[3]), authorization: nil)
            reply(socket, [0, 0x5A, 0, 0, 0, 0, 0, 0])
        case .socks5(let credentials, let refuse):
            guard let greeting = exact(socket, 2), greeting[0] == 5, let methods = exact(socket, Int(greeting[1])) else { return false }
            var username: String?, password: String?
            if credentials {
                guard methods.contains(2) else { reply(socket, [5, 0xFF]); return false }
                reply(socket, [5, 2])
                guard let version = exact(socket, 2), version[0] == 1, let user = exact(socket, Int(version[1])),
                      let length = exact(socket, 1), let secret = exact(socket, Int(length[0])) else { return false }
                username = String(decoding: user, as: UTF8.self); password = String(decoding: secret, as: UTF8.self)
                reply(socket, [1, 0])
            } else {
                guard methods.contains(0) else { reply(socket, [5, 0xFF]); return false }
                reply(socket, [5, 0])
            }
            guard let fixed = exact(socket, 4), fixed[0] == 5, fixed[1] == 1 else { return false }
            let destination: String
            switch fixed[3] {
            case 1: guard let address = exact(socket, 4) else { return false }; destination = address.map(String.init).joined(separator: ".")
            case 4: guard let address = exact(socket, 16) else { return false }; destination = "ipv6:" + address.map { String($0, radix: 16) }.joined(separator: ".")
            case 3: guard let length = exact(socket, 1), let host = exact(socket, Int(length[0])) else { return false }; destination = String(decoding: host, as: UTF8.self)
            default: return false
            }
            guard let port = exact(socket, 2) else { return false }
            request = .init(version: 5, methods: methods, username: username, password: password, destination: destination,
                            port: UInt16(port[0]) << 8 | UInt16(port[1]), authorization: nil)
            reply(socket, [5, refuse ? 5 : 0, 0, 1, 0, 0, 0, 0, 0, 0])
            if refuse { lock.withLock { tunnels.append(request) }; return false }
        case .httpConnect:
            guard let head = line(socket), head.hasPrefix("CONNECT ") else { return false }
            let target = head.dropFirst(8).prefix { $0 != " " }
            let authorization = head.components(separatedBy: "\r\n").first { $0.lowercased().hasPrefix("proxy-authorization:") }
                .map { String($0.dropFirst("proxy-authorization:".count)).trimmingCharacters(in: .whitespaces) }
            let colon = target.lastIndex(of: ":") ?? target.endIndex
            request = .init(version: 1, username: nil, password: nil, destination: String(target[..<colon]),
                            port: colon < target.endIndex ? UInt16(target[target.index(after: colon)...]) ?? 0 : 0,
                            authorization: authorization)
            reply(socket, Array("HTTP/1.1 200 Connection established\r\n\r\n".utf8))
        }
        lock.withLock { tunnels.append(request) }
        return true
    }
    var proxyRequests: [ProxyRequest] { lock.withLock { tunnels } }

    private func serve(_ socket: SOCKET) {
        if let proxy, !handshake(socket, proxy) { closesocket(socket); return }
        var head: [UInt8] = [], chunk = [UInt8](repeating: 0, count: 4096)
        while !head.isEmpty ? !String(decoding: head, as: UTF8.self).contains("\r\n\r\n") : true {
            let count = recv(socket, &chunk, Int32(chunk.count), 0)
            guard count > 0, head.count < 65_536 else { closesocket(socket); return }
            head += chunk[..<Int(count)]
        }
        lock.lock(); client = socket; closedValue = false; heads.append(String(decoding: head, as: UTF8.self)); lock.unlock()
        Thread { [weak self] in
            var rest = [UInt8](repeating: 0, count: 256)
            while recv(socket, &rest, Int32(rest.count), 0) > 0 {}
            guard let self else { return }
            self.lock.lock(); if self.client == socket { self.closedValue = true }; self.lock.unlock()
        }.start()
    }

    var requests: [String] { lock.lock(); defer { lock.unlock() }; return heads }
    var opened: Bool { !requests.isEmpty }
    var closed: Bool { lock.lock(); defer { lock.unlock() }; return closedValue }

    @discardableResult
    func send(_ data: Data) -> Bool {
        lock.lock(); let socket = client; lock.unlock()
        var offset = 0
        while offset < data.count {
            let sent = data.withUnsafeBytes {
                WinSDK.send(socket, $0.baseAddress!.advanced(by: offset).assumingMemoryBound(to: CChar.self), Int32(min(65_536, data.count - offset)), 0)
            }
            guard sent > 0 else { return false }
            offset += Int(sent)
        }
        return true
    }
    func send(_ text: String) { send(Data(text.utf8)) }
    func respond(_ code: Int = 200, mime: String = "text/event-stream", headers: [String: String] = [:]) {
        let fields = headers.map { "\($0.key): \($0.value)\r\n" }.joined()
        send("HTTP/1.1 \(code) Fixture\r\nContent-Type: \(mime)\r\n\(fields)Connection: close\r\n\r\n")
    }
    /// Ends the body: without a length, the response ends with the connection.
    func finish() { lock.lock(); let socket = client; lock.unlock(); shutdown(socket, SD_SEND) }
    func stop() {
        closesocket(listener)
        lock.lock(); let socket = client; client = INVALID_SOCKET; lock.unlock()
        if socket != INVALID_SOCKET { closesocket(socket) }
    }
}
#endif
