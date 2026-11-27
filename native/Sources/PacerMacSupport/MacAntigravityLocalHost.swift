import Darwin
import Foundation
import PacerCore
import Security

package struct MacAntigravityLocalHost: AntigravityLocalHost {
    package init() {}

    package func hubChangeTime(_ hub: URL) -> UInt64? {
        var file = stat()
        guard lstat(hub.path, &file) == 0 else { return nil }
        return UInt64(file.st_ctimespec.tv_sec) &* 1_000_000_000 &+ UInt64(file.st_ctimespec.tv_nsec)
    }

    private func processInfo(_ pid: Int32) -> proc_bsdinfo? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout.size(ofValue: info))
        return proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size ? info : nil
    }

    private func identity(_ pid: Int32, _ info: proc_bsdinfo) -> String {
        "\(pid):\(info.pbi_start_tvsec):\(info.pbi_start_tvusec)"
    }

    package func processIdentity(pid: Int32) -> String? {
        processInfo(pid).map { identity(pid, $0) }
    }

    package func serverIdentity(hub: URL, pid: Int32, httpPort: UInt16) -> String? {
        var file = stat()
        guard lstat(hub.path, &file) == 0, file.st_uid == geteuid(), (file.st_mode & S_IFMT) == S_IFREG,
              let info = processInfo(pid), info.pbi_uid == geteuid() else { return nil }
        var path = [CChar](repeating: 0, count: 4096)
        guard proc_pidpath(pid, &path, UInt32(path.count)) > 0 else { return nil }
        let executable = URL(fileURLWithPath: String(cString: path))
        guard executable.lastPathComponent.hasPrefix("language_server"),
              executable.pathComponents.contains("Antigravity.app"),
              trustedServer(pid), ownsListener(pid, port: httpPort) else { return nil }
        return identity(pid, info)
    }

    private func trustedServer(_ pid: Int32) -> Bool {
        var code: SecCode?, requirement: SecRequirement?
        let attributes = [kSecGuestAttributePid as String: NSNumber(value: pid)]
        guard SecCodeCopyGuestWithAttributes(nil, attributes as CFDictionary, [], &code) == errSecSuccess, let code,
              SecRequirementCreateWithString("anchor apple generic and certificate leaf[subject.OU] = \"EQHXZ8M8AV\"" as CFString,
                                             [], &requirement) == errSecSuccess, let requirement else { return false }
        return SecCodeCheckValidity(code, [], requirement) == errSecSuccess
    }

    private func ownsListener(_ pid: Int32, port: UInt16) -> Bool {
        let needed = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        let stride = MemoryLayout<proc_fdinfo>.stride
        guard needed > 0, Int(needed) <= 8192 * stride else { return false }
        var fds = [proc_fdinfo](repeating: .init(), count: Int(needed) / stride + 16)
        let bytes = fds.withUnsafeMutableBytes { proc_pidinfo(pid, PROC_PIDLISTFDS, 0, $0.baseAddress, Int32($0.count)) }
        guard bytes > 0 else { return false }
        for fd in fds.prefix(Int(bytes) / stride) where fd.proc_fdtype == PROX_FDTYPE_SOCKET {
            var socket = socket_fdinfo()
            let size = Int32(MemoryLayout.size(ofValue: socket))
            guard proc_pidfdinfo(pid, fd.proc_fd, PROC_PIDFDSOCKETINFO, &socket, size) == size,
                  socket.psi.soi_kind == SOCKINFO_TCP, socket.psi.soi_family == AF_INET else { continue }
            let tcp = socket.psi.soi_proto.pri_tcp
            if tcp.tcpsi_state == TSI_S_LISTEN, UInt16(truncatingIfNeeded: tcp.tcpsi_ini.insi_lport).bigEndian == port,
               tcp.tcpsi_ini.insi_laddr.ina_46.i46a_addr4.s_addr == inet_addr("127.0.0.1") { return true }
        }
        return false
    }

    package func post(_ request: AntigravityLocalRequest) async throws -> (Int, Data) {
        guard let url = URL(string: "http://127.0.0.1:\(request.port)\(request.path)") else { throw URLError(.badURL) }
        let config = URLSessionConfiguration.ephemeral
        config.urlCache = nil; config.httpCookieStorage = nil; config.urlCredentialStorage = nil
        config.httpShouldSetCookies = false; config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.connectionProxyDictionary = ["HTTPEnable": 0, "HTTPSEnable": 0, "SOCKSEnable": 0, "ProxyAutoConfigEnable": 0,
                                            "ProxyAutoDiscoveryEnable": 0]
        config.timeoutIntervalForRequest = 2; config.timeoutIntervalForResource = 2
        var post = URLRequest(url: url); post.httpMethod = "POST"; post.httpBody = request.body
        post.allHTTPHeaderFields = request.headers; post.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        return try await Self.read(post, configuration: config, maximumBytes: request.maximumBytes)
    }

    static func read(_ post: URLRequest, configuration: URLSessionConfiguration, maximumBytes: Int) async throws -> (Int, Data) {
        let (responses, completion) = AsyncThrowingStream<(Int, Data), Error>.makeStream()
        let delegate = LocalOnlyDelegate(maximumBytes: maximumBytes, completion: completion)
        let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let task = session.dataTask(with: post)
        try Task.checkCancellation()
        task.resume()
        var iterator = responses.makeAsyncIterator()
        guard let response = try await iterator.next() else { throw CancellationError() }
        return response
    }

    // One request per session. Its serial delegate queue owns the buffer and
    // delivers just one bounded result to the waiting task.
    private final class LocalOnlyDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
        let maximumBytes: Int
        let completion: AsyncThrowingStream<(Int, Data), Error>.Continuation
        private var data = Data()
        private var result: Result<(Int, Data), Error>?
        init(maximumBytes: Int, completion: AsyncThrowingStream<(Int, Data), Error>.Continuation) {
            self.maximumBytes = maximumBytes
            self.completion = completion
        }

        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
            if let http = response as? HTTPURLResponse {
                if http.statusCode != 200 {
                    result = .success((http.statusCode, Data()))
                } else if http.expectedContentLength > maximumBytes ||
                    (http.value(forHTTPHeaderField: "Content-Encoding") ?? "identity").lowercased() != "identity" {
                    result = .failure(AntigravityLocalClient.Failure.oversized)
                }
            } else { result = .failure(URLError(.badServerResponse)) }
            completionHandler(result == nil ? .allow : .cancel)
        }
        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive chunk: Data) {
            guard result == nil else { return }
            guard chunk.count <= maximumBytes - data.count else {
                result = .failure(AntigravityLocalClient.Failure.oversized)
                dataTask.cancel()
                return
            }
            data.append(chunk)
        }
        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
            switch result ?? error.map({ .failure($0) }) ?? .success((200, data)) {
            case .success(let response): completion.yield(response); completion.finish()
            case .failure(let error): completion.finish(throwing: error)
            }
        }
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
        func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge,
                        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
            completionHandler(.cancelAuthenticationChallenge, nil)
        }
    }
}
