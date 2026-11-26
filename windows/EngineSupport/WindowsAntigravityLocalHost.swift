import CWindowsSupport
import Foundation
import PacerCore
import WinSDK

struct WindowsAntigravityLocalHost: AntigravityLocalHost {
    let maximumHubDirectoryEntries = 4096
    var hubCandidateLimit: AntigravityHubCandidateLimit { .newest(32) }
    var server: @Sendable () -> URL? = {
        WindowsAntigravityInstallation.shared.resolve()?.deletingLastPathComponent()
            .appendingPathComponent(WindowsAntigravityInstallation.serverPath)
    }

    static func ownedHub(_ hub: URL) -> Bool {
        let handle = CreateFileW(WindowsFiles.wide(hub), DWORD(READ_CONTROL | FILE_READ_ATTRIBUTES),
            DWORD(FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE), nil, DWORD(OPEN_EXISTING),
            DWORD(FILE_FLAG_OPEN_REPARSE_POINT), nil)
        guard handle != INVALID_HANDLE_VALUE else { return false }
        defer { CloseHandle(handle) }
        var info = BY_HANDLE_FILE_INFORMATION(), owner: PSID?, descriptor: PSECURITY_DESCRIPTOR?
        guard GetFileType(handle) == FILE_TYPE_DISK, GetFileInformationByHandle(handle, &info),
              info.nNumberOfLinks == 1, info.dwFileAttributes & DWORD(FILE_ATTRIBUTE_DIRECTORY | FILE_ATTRIBUTE_REPARSE_POINT) == 0,
              GetSecurityInfo(handle, SE_FILE_OBJECT, DWORD(OWNER_SECURITY_INFORMATION), &owner, nil, nil, nil, &descriptor) == ERROR_SUCCESS
        else { return false }
        defer { if let descriptor { _ = LocalFree(descriptor) } }
        guard let owner else { return false }
        // As for other profile files: the current user, or Administrators only
        // while Pacer itself runs elevated, which is how an elevated process
        // owns the files it creates.
        return (try? WindowsLocalProfileOwner.validate(owner)) != nil
    }

    func serverIdentity(hub: URL, pid: Int32, httpPort: UInt16) -> String? {
        guard pid > 1, httpPort != 0, Self.ownedHub(hub) else { return nil }
        var process = pacer_process_identity()
        var image = [UInt16](repeating: 0, count: 32768)
        let id = UInt32(pid)
        guard pacer_process_image(id, 0, &process, &image, image.count) != 0, let expected = server() else { return nil }
        let actual = URL(fileURLWithPath: String(decoding: image.prefix { $0 != 0 }, as: UTF16.self))
        let actualPath = Array(WindowsCodexExecutableDiscovery.path(actual.standardizedFileURL).utf16) + [0]
        let serverPath = Array(WindowsCodexExecutableDiscovery.path(expected.standardizedFileURL).utf16) + [0]
        guard CompareStringOrdinal(actualPath, -1, serverPath, -1, true) == CSTR_EQUAL,
              pacer_loopback_listener(id, httpPort) != 0, pacer_process_alive(id, process.started) != 0 else { return nil }
        return "\(pid):\(process.started)"
    }

    func post(_ request: AntigravityLocalRequest) async throws -> (Int, Data) {
        let deadline = GetTickCount64() + 2000
        guard let stream = WindowsHTTPStream() else { throw URLError(.cannotConnectToHost) }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let started = WindowsThread.start(name: "Antigravity quota and activity") {
                    defer { stream.close() }
                    do {
                        let response = try Self.read(request, stream: stream, deadline: deadline)
                        guard GetTickCount64() < deadline else { throw WindowsHTTPStream.Failure.timedOut }
                        continuation.resume(returning: response)
                    } catch {
                        if GetTickCount64() >= deadline || (error as? WindowsHTTPStream.Failure) == .timedOut {
                            continuation.resume(throwing: URLError(.timedOut))
                        } else {
                            continuation.resume(throwing: error)
                        }
                    }
                }
                if !started { continuation.resume(throwing: URLError(.cannotConnectToHost)) }
            }
        } onCancel: { stream.cancel() }
    }

    private static func read(_ request: AntigravityLocalRequest, stream: WindowsHTTPStream, deadline: UInt64) throws -> (Int, Data) {
        var fields = request.headers
        fields["Accept-Encoding"] = "identity"
        let status = try stream.openLocalPost(port: request.port, path: request.path, headers: fields, body: request.body, deadline: deadline)
        guard status == 200 else { return (status, Data()) }
        guard let headers = stream.headers() else { throw URLError(.badServerResponse) }
        for (name, value) in headers {
            if name.lowercased() == "content-length", UInt64(value).map({ $0 <= request.maximumBytes }) != true {
                throw AntigravityLocalClient.Failure.oversized
            }
            if name.lowercased() == "content-encoding", value.lowercased() != "identity" { throw AntigravityLocalClient.Failure.oversized }
        }
        var data = Data(), buffer = [UInt8](repeating: 0, count: 16384)
        while true {
            let now = GetTickCount64()
            guard now < deadline else { throw WindowsHTTPStream.Failure.timedOut }
            let count = try stream.read(into: &buffer, timeout: TimeInterval(deadline - now) / 1000).get()
            if count == 0 { return (status, data) }
            guard count <= request.maximumBytes - data.count else { throw AntigravityLocalClient.Failure.oversized }
            data.append(contentsOf: buffer.prefix(count))
        }
    }
}
