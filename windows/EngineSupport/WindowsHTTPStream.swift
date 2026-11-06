#if os(Windows)
import Foundation
import FoundationNetworking
import CWindowsSupport

/// One GET response read through WinHTTP.
///
/// FoundationNetworking on Windows keeps a socket's write-readiness source
/// after libcurl stops asking for it, so a URLSession request busy-loops a
/// worker thread for as long as its response is open. This transport waits on
/// events instead. One thread opens, reads and closes it; `cancel()` is safe
/// from any thread.
final class WindowsHTTPStream: @unchecked Sendable {
    struct Target: Equatable, Sendable {
        var host: String, port: UInt16, secure: Bool, path: String
    }
    enum Failure: Error, Equatable { case failed, timedOut, cancelled }

    /// Where an https URL connects; nil for any other URL.
    static func httpsTarget(_ url: URL) -> Target? {
        guard url.scheme?.lowercased() == "https", let host = url.host, !host.isEmpty, url.user == nil, url.password == nil,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        let port = url.port ?? 443
        guard (1...65535).contains(port) else { return nil }
        let path = components.percentEncodedPath.isEmpty ? "/" : components.percentEncodedPath
        return .init(host: host, port: UInt16(port), secure: true, path: path + (components.percentEncodedQuery.map { "?" + $0 } ?? ""))
    }

    /// A request's agent and remaining headers; WinHTTP sends the agent given
    /// when its session opens. Nil when a header could start another line.
    static func fields(of request: URLRequest) -> (agent: String, headers: [(name: String, value: String)])? {
        let fields = (request.allHTTPHeaderFields ?? [:]).sorted { $0.key < $1.key }
        let agent = fields.last { $0.key.lowercased() == "user-agent" }?.value ?? "CodexPacer"
        let headers = fields.filter { $0.key.lowercased() != "user-agent" }.map { (name: $0.key, value: $0.value) }
        guard headerBlock(headers) != nil, valid(agent) else { return nil }
        return (agent, headers)
    }

    private let lock = NSLock()
    private var handle: UnsafeMutableRawPointer?

    init?() {
        guard let handle = pacer_http_stream_create() else { return nil }
        self.handle = handle
    }
    deinit { close() }

    /// Waits for the response headers and returns the status code.
    func open(_ target: Target, headers: [(name: String, value: String)], agent: String, proxy: String?,
              timeout: TimeInterval) -> Result<Int, Failure> {
        guard let handle = current(), let header = Self.headerBlock(headers), Self.valid(agent), !target.host.isEmpty,
              Self.valid(target.host), target.port > 0, target.path.hasPrefix("/"), Self.valid(target.path),
              proxy.map(Self.valid) != false else { return .failure(.failed) }
        var status: UInt32 = 0
        let host = Array(target.host.utf16) + [0], path = Array(target.path.utf16) + [0], name = Array(agent.utf16) + [0]
        let result: Int32
        if let proxy {
            result = pacer_http_stream_open(handle, host, target.port, target.secure ? 1 : 0, path, header, name,
                                            Array(proxy.utf16) + [0], Self.milliseconds(timeout), &status)
        } else {
            result = pacer_http_stream_open(handle, host, target.port, target.secure ? 1 : 0, path, header, name, nil,
                                            Self.milliseconds(timeout), &status)
        }
        return result == 0 ? .success(Int(status)) : .failure(Self.failure(Int64(result)))
    }

    func header(_ name: String) -> String? {
        guard let handle = current(), Self.valid(name), !name.isEmpty else { return nil }
        var value = [UInt16](repeating: 0, count: 1024)
        let count = pacer_http_stream_header(handle, Array(name.utf16) + [0], &value, value.count)
        guard count >= 0, Int(count) < value.count else { return nil }
        return String(decoding: value.prefix(Int(count)), as: UTF16.self)
    }

    /// Every response header; repeated names are joined like URLSession's.
    func headers() -> [String: String]? {
        guard let handle = current() else { return nil }
        var value = [UInt16](repeating: 0, count: 65536)
        let count = pacer_http_stream_raw_headers(handle, &value, value.count)
        guard count >= 0, Int(count) < value.count else { return nil }
        var fields: [String: String] = [:]
        // The first line is the status line.
        for line in String(decoding: value.prefix(Int(count)), as: UTF16.self).components(separatedBy: "\r\n").dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces)
            let field = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty else { continue }
            if let key = fields.keys.first(where: { $0.caseInsensitiveCompare(name) == .orderedSame }) { fields[key]! += ", " + field }
            else { fields[name] = field }
        }
        return fields
    }

    /// Returns the number of bytes read; zero is the end of the response.
    func read(into bytes: inout [UInt8], timeout: TimeInterval) -> Result<Int, Failure> {
        guard let handle = current(), !bytes.isEmpty else { return .failure(.failed) }
        let count = bytes.withUnsafeMutableBufferPointer {
            pacer_http_stream_read(handle, $0.baseAddress!, $0.count, Self.milliseconds(timeout))
        }
        return count >= 0 ? .success(Int(count)) : .failure(Self.failure(count))
    }

    func cancel() {
        lock.lock(); defer { lock.unlock() }
        if let handle { pacer_http_stream_cancel(handle) }
    }

    /// Releases the connection after the owning thread's open and read returned.
    func close() {
        lock.lock(); let handle = self.handle; self.handle = nil; lock.unlock()
        if let handle { pacer_http_stream_close(handle) }
    }

    private func current() -> UnsafeMutableRawPointer? { lock.lock(); defer { lock.unlock() }; return handle }

    private static func failure(_ code: Int64) -> Failure { code == -3 ? .cancelled : code == -2 ? .timedOut : .failed }
    private static func milliseconds(_ timeout: TimeInterval) -> UInt32 { UInt32(min(max(timeout, 0.001), 86_400) * 1000) }
    private static func valid(_ text: String) -> Bool {
        text.utf16.count < 8192 && !text.unicodeScalars.contains { $0.value < 32 || $0.value == 127 }
    }

    /// Request headers as WinHTTP's CRLF-separated block. Names are HTTP
    /// tokens and values cannot start another header or line.
    static func headerBlock(_ headers: [(name: String, value: String)]) -> [UInt16]? {
        let separators = Set(#"()<>@,;:\"/[]?={}"#.utf8)
        var lines: [String] = []
        for (name, value) in headers {
            guard !name.isEmpty, name.utf8.allSatisfy({ (33...126).contains($0) && !separators.contains($0) }),
                  !value.unicodeScalars.contains(where: { ($0.value < 32 && $0.value != 9) || $0.value == 127 }) else { return nil }
            lines.append(name + ": " + value)
        }
        let block = lines.joined(separator: "\r\n")
        guard block.utf16.count < 65_536 else { return nil }
        return Array(block.utf16) + [0]
    }
}

/// The proxy libcurl would use for an https request, so a stream takes the same
/// route as the URLSession reads beside it. A configured proxy is never
/// bypassed: one WinHTTP cannot use fails instead of connecting directly.
enum WindowsHTTPProxy {
    static func forHTTPS(host: String, environment: [String: String] = ProcessInfo.processInfo.environment) -> Result<String?, WindowsHTTPStream.Failure> {
        func value(_ name: String) -> String? {
            // Windows names are case-insensitive; libcurl prefers the lowercase spelling.
            if let exact = environment[name], !exact.isEmpty { return exact }
            return environment.first { $0.key.lowercased() == name && !$0.value.isEmpty }?.value
        }
        guard let configured = value("https_proxy") ?? value("all_proxy") else { return .success(nil) }
        let host = host.lowercased()
        for entry in (value("no_proxy") ?? "").split(separator: ",") {
            var pattern = entry.trimmingCharacters(in: .whitespaces).lowercased()
            if pattern == "*" { return .success(nil) }
            if pattern.hasPrefix(".") { pattern.removeFirst() }
            if !pattern.isEmpty, host == pattern || host.hasSuffix("." + pattern) { return .success(nil) }
        }
        var address = configured.trimmingCharacters(in: .whitespaces)
        if let range = address.range(of: "://") {
            guard address[..<range.lowerBound].lowercased() == "http" else { return .failure(.failed) }
            address = String(address[range.upperBound...])
        }
        if address.hasSuffix("/") { address.removeLast() }
        guard !address.isEmpty, !address.contains("@"), !address.contains("/"),
              !address.unicodeScalars.contains(where: { $0.value <= 32 || $0.value == 127 }) else { return .failure(.failed) }
        let bracketed = address.hasPrefix("[")
        let hasPort = bracketed ? address.contains("]:") : address.contains(":")
        if bracketed, !address.contains("]") { return .failure(.failed) }
        if !bracketed, address.filter({ $0 == ":" }).count > 1 { return .failure(.failed) }
        // libcurl's default proxy port.
        return .success(hasPort ? address : address + ":1080")
    }
}
#endif
