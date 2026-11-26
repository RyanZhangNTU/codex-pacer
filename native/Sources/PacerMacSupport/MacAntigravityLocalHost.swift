import Darwin
import Foundation
import PacerCore
import Security

package struct MacAntigravityLocalHost: AntigravityLocalHost {
    package init() {}

    package func serverIdentity(hub: URL, pid: Int32, httpPort: UInt16) -> String? {
        var file = stat(), info = proc_bsdinfo()
        let size = Int32(MemoryLayout.size(ofValue: info))
        guard lstat(hub.path, &file) == 0, file.st_uid == geteuid(), (file.st_mode & S_IFMT) == S_IFREG,
              proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size, info.pbi_uid == geteuid() else { return nil }
        var path = [CChar](repeating: 0, count: 4096)
        guard proc_pidpath(pid, &path, UInt32(path.count)) > 0 else { return nil }
        let executable = URL(fileURLWithPath: String(cString: path))
        guard executable.lastPathComponent.hasPrefix("language_server"),
              executable.pathComponents.contains("Antigravity.app"),
              trustedServer(pid), ownsListener(pid, port: httpPort) else { return nil }
        return "\(pid):\(info.pbi_start_tvsec):\(info.pbi_start_tvusec)"
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
        let session = URLSession(configuration: config, delegate: LocalOnlyDelegate(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        var post = URLRequest(url: url); post.httpMethod = "POST"; post.httpBody = request.body
        post.allHTTPHeaderFields = request.headers; post.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        let (bytes, response) = try await session.bytes(for: post)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        guard http.statusCode == 200 else { return (http.statusCode, Data()) }
        guard http.expectedContentLength <= request.maximumBytes,
              (http.value(forHTTPHeaderField: "Content-Encoding") ?? "identity").lowercased() == "identity" else {
            throw AntigravityLocalClient.Failure.oversized
        }
        var data = Data()
        for try await byte in bytes {
            guard data.count < request.maximumBytes else { throw AntigravityLocalClient.Failure.oversized }
            data.append(byte)
        }
        return (200, data)
    }

    private final class LocalOnlyDelegate: NSObject, URLSessionTaskDelegate {
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
        func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge,
                        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
            completionHandler(.cancelAuthenticationChallenge, nil)
        }
    }
}
