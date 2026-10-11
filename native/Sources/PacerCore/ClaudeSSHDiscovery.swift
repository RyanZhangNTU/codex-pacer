import Foundation
import CryptoKit

/// Reads the host lists managed by Codex and Claude. Route lookup uses `ssh -G`
/// only; discovery never authenticates, reads keys or writes either client's files.
public actor ClaudeSSHDiscovery {
    public static let shared = ClaudeSSHDiscovery()
    private struct Configuration: Sendable {
        let id: String
        let name: String
        let host: String
        let port: Int?
        let identity: String?
    }
    private let files = FileSignatureCache<[Configuration]>()
    private struct RouteKey: Hashable { let host: String; let port: Int?; let userHome: String }
    private struct CachedRoute { let route: ClaudeSSHRoute?; let at: Date; let signature: String }
    private var routes: [RouteKey: CachedRoute] = [:]
    private let resolve: @Sendable (String, Int?) async -> ClaudeSSHRoute?

    public init() { resolve = { await ClaudeSSHRouteResolver.resolve(host: $0, port: $1) } }
    init(resolve: @escaping @Sendable (String, Int?) async -> ClaudeSSHRoute?) { self.resolve = resolve }

    public func configured(codexHome: URL, claudeHome: URL, userHome: URL) async -> [RemoteActivityTarget] {
        let codex = RemoteActivityTarget.claudeCodexTargets(home: codexHome)
        let desktopFile = userHome.appendingPathComponent("Library/Application Support/Claude/ssh_configs.json")
        let settingsFile = claudeHome.appendingPathComponent("settings.json")
        let desktop = configurations(desktopFile, field: "configs")
        let settings = configurations(settingsFile, field: "sshConfigs")
        // Claude's user settings override a Desktop entry with the same ID.
        let overridden = Set(settings.map(\.id))
        let saved = (settings + desktop.filter { !overridden.contains($0.id) }).prefix(32)
        let signature = sshSignature(userHome: userHome)
        var result: [RemoteActivityTarget] = [], keys: [String: Int] = [:]
        for target in codex {
            let key = await routeKey(host: target.alias, port: nil, userHome: userHome, signature: signature)
            guard !Task.isCancelled else { return [] }
            if keys[key] == nil { keys[key] = result.count; result.append(target) }
        }
        for config in saved {
            let key = await routeKey(host: config.host, port: config.port, userHome: userHome, signature: signature)
            guard !Task.isCancelled else { return [] }
            if let index = keys[key] {
                // Preserve the existing Codex source identity and its SSH alias.
                // Claude's explicit key still applies to Claude collection.
                if result[index].sshIdentityFile == nil { result[index].sshIdentityFile = config.identity }
                continue
            }
            guard result.count < 8 else { continue }
            let simple = config.port == nil && config.identity == nil &&
                config.host.range(of: #"^[A-Za-z0-9][A-Za-z0-9._-]{0,128}\z"#, options: .regularExpression) != nil
            let alias = simple ? config.host : "claude-" + digest(key)
            keys[key] = result.count
            result.append(.init(id: "remote-ssh-discovered:" + alias, name: config.name, alias: alias, home: "~/.claude",
                sshDestination: simple ? nil : config.host, sshPort: config.port, sshIdentityFile: config.identity))
        }
        return result
    }

    private func configurations(_ file: URL, field: String) -> [Configuration] {
        files.value(for: file) {
            guard let values = try? file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]),
                  values.isRegularFile == true, values.isSymbolicLink != true,
                  let size = values.fileSize, size <= 2 * 1024 * 1024,
                  let data = try? Data(contentsOf: file), data.count <= 2 * 1024 * 1024,
                  let root = try? JSONFieldView.document(data),
                  let rows = try? root.fields([field])[field]?.elements(maximumCount: 256) else { return [] }
            return rows.prefix(64).compactMap { row in
                guard let fields = try? row.fields(["id", "name", "sshHost", "sshPort", "sshIdentityFile"]),
                      let host = fields["sshHost"]?.string(), ClaudeSSHRouteResolver.validDestination(host) else { return nil }
                let port: Int?
                if let value = fields["sshPort"], !value.isNull {
                    guard let number = value.integer(), (1...65535).contains(number) else { return nil }
                    port = number
                } else { port = nil }
                let identity: String?
                if let value = fields["sshIdentityFile"], !value.isNull {
                    guard let path = value.string(), RemoteActivityTarget.validIdentityFile(path) else { return nil }
                    identity = path
                } else { identity = nil }
                let id = fields["id"]?.string() ?? host + ":" + String(port ?? 22)
                guard id.utf8.count <= 256 else { return nil }
                let name = fields["name"]?.string().flatMap { value -> String? in
                    let name = value.trimmingCharacters(in: .whitespacesAndNewlines)
                    return !name.isEmpty && name.utf8.count <= 256 &&
                        !name.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) } ? name : nil
                } ?? host
                return Configuration(id: id, name: name, host: host, port: port, identity: identity)
            }
        }
    }

    private func routeKey(host: String, port: Int?, userHome: URL, signature: String) async -> String {
        let key = RouteKey(host: host, port: port, userHome: userHome.path), now = Date()
        let route: ClaudeSSHRoute?
        if let cached = routes[key], cached.signature == signature, now.timeIntervalSince(cached.at) < 300 {
            route = cached.route
        } else {
            route = await resolve(host, port)
            guard !Task.isCancelled else { return "" }
            if routes.count >= 64 { routes.removeAll() }
            routes[key] = .init(route: route, at: now, signature: signature)
        }
        if let route { return [route.hostname, route.user, String(route.port)].joined(separator: "\u{0}") }
        // A safe saved host still appears as retrying if its SSH config is broken.
        return [host, String(port ?? 22)].joined(separator: "\u{0}")
    }
    private func digest(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).prefix(12).map { String(format: "%02x", $0) }.joined()
    }
    private func sshSignature(userHome: URL) -> String {
        [userHome.appendingPathComponent(".ssh/config"), URL(fileURLWithPath: "/etc/ssh/ssh_config")].map {
            let attributes = try? FileManager.default.attributesOfItem(atPath: $0.path)
            return "\(attributes?[.modificationDate] ?? ""):\(attributes?[.size] ?? ""):\(attributes?[.systemFileNumber] ?? "")"
        }.joined(separator: "|")
    }
}
