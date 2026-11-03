import Foundation
import FoundationNetworking
import PacerCore

private struct WindowsWSLQuotaFile: Decodable, Sendable, Equatable {
    let data: String
    let stamp: [UInt64]
}
private struct WindowsWSLQuotaFiles: PlatformFileSystem {
    let root: URL
    let values: [String: WindowsWSLQuotaFile]
    func entries(in directory: URL) throws -> [URL] { [] }
    func replace(_ url: URL, with data: Data) -> Bool { false }
    private func item(_ url: URL) -> WindowsWSLQuotaFile? {
        let directory = url.deletingLastPathComponent().standardizedFileURL.path
        guard directory == root.standardizedFileURL.path || directory == root.appendingPathComponent(".claude").standardizedFileURL.path else { return nil }
        return values[url.lastPathComponent]
    }
    func metadata(_ url: URL, followingSymbolicLinks: Bool) -> PlatformFileMetadata? {
        guard let value = item(url), value.stamp.count == 5 else { return nil }
        return .init(identity: value.stamp.prefix(2).map(String.init).joined(separator: ":"), size: value.stamp[2],
            modified: Date(timeIntervalSince1970: Double(value.stamp[3]) / 1_000_000_000), created: nil, isRegularFile: true)
    }
    func read(_ url: URL, offset: UInt64, maximumBytes: Int) throws -> Data {
        guard offset <= UInt64(Int.max), let value = item(url), let data = Data(base64Encoded: value.data), data.count <= 2 * 1024 * 1024 else {
            throw ClaudeQuotaError.invalidReply
        }
        return Data(data.dropFirst(Int(offset)).prefix(maximumBytes))
    }
}

extension WindowsWSLServices {
    func validate(_ profile: WindowsWSLProfile, provider: AgentProvider) async -> Bool {
        guard let route = profile.route(provider), let script = Self.script("identity") else { return false }
        let args = ["--distribution", profile.distro, "--user", profile.user, "--exec", "/usr/bin/python3", "-I", "-c",
                    script + "\nchecked_route(sys.argv[1]); print('verified')", route.base64EncodedString()]
        return await capture(executable, args, 3, 32).map { String(decoding: $0, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) == "verified" } ?? false
    }
    func readQuota(profile: WindowsWSLProfile, provider: AgentProvider,
                   transport: @escaping ClaudeQuotaClient.Transport = { try await WindowsRemoteControlHTTP.claudeQuota($0) }) async throws -> QuotaSnapshot {
        guard registry.profile(id: profile.id, provider: provider) == profile else { throw ClaudeQuotaError.accountChanged }
        let before = try await quotaFiles(profile, provider: provider)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("pacer-wsl-identity/" + profile.id.dropFirst(4))
        let files = WindowsWSLQuotaFiles(root: root, values: before)
        let value: QuotaSnapshot
        if provider == .codex {
            let client = CodexClient(executable: executable, home: root, timeout: 2,
                processes: WindowsWSLQuotaLauncher(services: self, profile: profile), executables: WindowsExecutablePlatform(), files: files)
            value = try await withTaskCancellationHandler {
                do { let value = try await client.readQuota(); await client.shutdown(); return value }
                catch { await client.shutdown(); throw error }
            } onCancel: { Task { await client.shutdown() } }
        } else if provider == .claude {
            let home = root.appendingPathComponent(".claude")
            let credential = try ClaudeCredentialStore.read(userHome: root, home: home, environment: [:], files: files)
            let identity = ClaudeCredentialStore.identity(userHome: root, home: home, files: files)
            let client = ClaudeQuotaClient(statusLineURL: root.appendingPathComponent("no-statusline"), files: files,
                credentialProvider: { credential }, identityProvider: { identity.map { ($0.scope, $0.organizationID) } },
                transport: transport, now: { Date() })
            do { value = try await client.readQuota(); await client.shutdown() }
            catch { await client.shutdown(); throw error }
        } else { throw ClaudeQuotaError.unavailable }
        let after = try await quotaFiles(profile, provider: provider)
        guard before == after, registry.profile(id: profile.id, provider: provider) == profile, !Task.isCancelled else { throw ClaudeQuotaError.accountChanged }
        return value
    }
    private func quotaFiles(_ profile: WindowsWSLProfile, provider: AgentProvider) async throws -> [String: WindowsWSLQuotaFile] {
        guard let route = profile.route(provider), let script = Self.script("read-quota-files"),
              let data = await capture(executable, ["--distribution", profile.distro, "--user", profile.user, "--exec", "/usr/bin/python3", "-I", "-c", script,
                  route.base64EncodedString()], 3, 128 * 1024), data.count <= 128 * 1024,
              let values = try? JSONDecoder().decode([String: WindowsWSLQuotaFile].self, from: data),
              Set(values.keys).isSubset(of: provider == .codex ? ["auth.json"] : [".credentials.json", ".claude.json"]),
              values.values.allSatisfy({ $0.stamp.count == 5 && $0.data.utf8.count <= 65536 }) else { throw ClaudeQuotaError.unavailable }
        return values
    }
}

private struct WindowsWSLQuotaLauncher: ChildProcessLauncher {
    let services: WindowsWSLServices, profile: WindowsWSLProfile
    func launch(_ request: ChildProcessRequest, output: @escaping @Sendable (Data) -> Void,
                ended: @escaping @Sendable () -> Void) throws -> any ChildProcessConnection {
        guard services.registry.profile(id: profile.id, provider: .codex) == profile,
              let invocation = WindowsWSLInvocation(profile: profile, provider: .codex,
                command: "exec codex -s read-only -a never app-server --listen stdio://") else { throw CodexClientError.invalidResponse }
        return try services.start(.init(executable: services.executable, arguments: invocation.arguments,
            environment: WindowsWSLInvocation.environment(request.environment)), invocation.input, { output($0) }, { ended() })
    }
}
