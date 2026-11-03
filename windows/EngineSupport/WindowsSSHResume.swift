import Foundation
import PacerCore
import WinSDK

struct WindowsSSHResume: Codable, Equatable, Sendable {
    let provider: AgentProvider
    let session, alias: String
    let destination: String?
    let port: Int?
    let identity: String?
    init(provider: AgentProvider, session: String, target: RemoteActivityTarget) {
        self.provider = provider; self.session = session; alias = target.alias
        destination = target.sshDestination; port = target.sshPort; identity = target.sshIdentityFile
    }
    var arguments: [String]? {
        guard UUID(uuidString: session) != nil, session.utf8.count == 36,
              let args = WindowsSSHServices.arguments(.init(id: "remote-ssh-discovered:" + alias, name: "", alias: alias,
                home: "", sshDestination: destination, sshPort: port, sshIdentityFile: identity), terminal: true) else { return nil }
        let command: String
        switch provider {
        case .claude:
            guard let resume = ClaudeRemoteResume.command(sessionID: session) else { return nil }
            command = resume
        case .codex: command = "exec codex resume " + session.lowercased()
        case .deepseek: return nil
        }
        return args + [command]
    }
    var token: String? { arguments == nil ? nil : (try? JSONEncoder().encode(self))?.base64EncodedString() }
    static func decode(_ token: String) -> Self? {
        guard token.utf8.count <= 16000, let bytes = Data(base64Encoded: token),
              let value = try? JSONDecoder().decode(Self.self, from: bytes), value.arguments != nil else { return nil }
        return value
    }
}

enum WindowsSSHTerminal {
    /// This mode runs inside a user-owned console, separately from stdio IPC.
    static func run(_ token: String) {
        guard let resume = WindowsSSHResume.decode(token), let args = resume.arguments else { return }
        let executable = WindowsCodexExecutableDiscovery.path(WindowsExecutables.ssh)
        var command = Array(([executable] + args).map(quote).joined(separator: " ").utf16) + [0]
        guard command.count < 32767 else { return }
        var startup = STARTUPINFOW(); startup.cb = DWORD(MemoryLayout<STARTUPINFOW>.size)
        var process = PROCESS_INFORMATION()
        let launched = Array((executable + "\0").utf16).withUnsafeBufferPointer { path in
            CreateProcessW(path.baseAddress, &command, nil, nil, true, 0, nil, nil, &startup, &process)
        }
        guard launched else { return }
        defer { CloseHandle(process.hThread); CloseHandle(process.hProcess) }
        _ = WaitForSingleObject(process.hProcess, INFINITE)
    }
    static func quote(_ value: String) -> String {
        var result = "\"", slashes = 0
        for character in value {
            if character == "\\" { slashes += 1; continue }
            if character == "\"" { result += String(repeating: "\\", count: slashes * 2 + 1) + "\"" }
            else { result += String(repeating: "\\", count: slashes) + String(character) }
            slashes = 0
        }
        return result + String(repeating: "\\", count: slashes * 2) + "\""
    }
}
