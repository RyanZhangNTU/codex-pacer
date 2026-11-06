@testable import PacerEngineSupport
#if os(Windows)
import Foundation
import FoundationNetworking
import WinSDK

/// A loopback HTTP/1.1 server for one connection at a time. It records request
/// heads and notices when the client closes its connection.
final class LoopbackHTTPServer: @unchecked Sendable {
    private let lock = NSLock()
    private let listener: SOCKET
    let port: UInt16
    private var client: SOCKET = INVALID_SOCKET
    private var heads: [String] = []
    private var closedValue = false

    init() throws {
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

    private func serve(_ socket: SOCKET) {
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
