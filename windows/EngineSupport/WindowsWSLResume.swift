import Foundation
import PacerCore

struct WindowsWSLResume: Codable, Equatable, Sendable {
    let profile: WindowsWSLProfile
    let provider: AgentProvider
    let session: String
    var arguments: [String]? {
        guard session.utf8.count == 36, let uuid = UUID(uuidString: session),
              let route = profile.route(provider), let console = WindowsWSLServices.script("console") else { return nil }
        var values = ["--distribution", profile.distro, "--user", profile.user, "--exec", "/usr/bin/python3", "-I", "-c", console,
                      route.base64EncodedString(), uuid.uuidString.lowercased()]
        if provider == .claude {
            guard let command = ClaudeRemoteResume.command(sessionID: session) else { return nil }
            values.append(Data(command.utf8).base64EncodedString())
        }
        return values
    }
    var token: String? { arguments == nil ? nil : (try? JSONEncoder().encode(self))?.base64EncodedString() }
    static func decode(_ token: String) -> Self? {
        guard token.utf8.count <= 16000, let data = Data(base64Encoded: token),
              let value = try? JSONDecoder().decode(Self.self, from: data), value.arguments != nil else { return nil }
        return value
    }
    static func run(_ token: String) {
        guard let value = decode(token), let arguments = value.arguments else { return }
        let services = WindowsWSLServices(), child = Process()
        child.executableURL = services.executable; child.arguments = arguments
        child.environment = WindowsWSLInvocation.environment(ProcessInfo.processInfo.environment)
        // A user-owned console has an interactive lifetime, separate from the
        // stdio engine and its bounded shutdown. Never run this during discovery.
        do { try child.run(); child.waitUntilExit() } catch { }
    }
}
