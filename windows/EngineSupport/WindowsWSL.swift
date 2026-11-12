import Foundation
import PacerCore
import CWindowsSupport

enum WindowsWSLAvailability: String, Codable, Sendable {
    case checking, available, unavailable, failed
}

struct WindowsWSLProfile: Codable, Equatable, Sendable {
    var distro: String = ""
    let user: String, uid: UInt32, home: String, identity: String
    let codexHome: String, claudeHome: String
    var codexIdentity: String?, claudeIdentity: String?
    var id: String { ConnectionSource.wslPrefix + CompletionDismissalStore.digest([distro.lowercased(), user, String(uid), home, identity]) }
    var valid: Bool {
        Self.validDistro(distro) && !user.isEmpty && user.utf8.count <= 128 && !user.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) &&
            !user.contains(where: { $0.isWhitespace || $0 == "/" || $0 == "\\" }) &&
            [home, codexHome, claudeHome].allSatisfy(Self.validPath) && [identity, codexIdentity, claudeIdentity].compactMap { $0 }.allSatisfy {
                !$0.isEmpty && $0.utf8.count <= 128 && $0.allSatisfy { $0.isNumber || $0 == ":" }
            }
    }
    static func validDistro(_ name: String) -> Bool {
        !name.isEmpty && name.utf8.count <= 256 && name.first != "-" && !name.unicodeScalars.contains {
            CharacterSet.controlCharacters.contains($0) || "/\\:;\"".unicodeScalars.contains($0)
        }
    }
    static func validPath(_ path: String) -> Bool {
        path.hasPrefix("/") && !path.hasPrefix("//") && path.utf8.count <= 4096 && !path.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) } &&
            !path.contains("\\") && !path.split(separator: "/").contains(where: { $0 == "." || $0 == ".." })
    }
    func root(_ provider: AgentProvider) -> String { provider == .codex ? codexHome : claudeHome }
    func rootIdentity(_ provider: AgentProvider) -> String? { provider == .codex ? codexIdentity : claudeIdentity }
    func target(_ provider: AgentProvider) -> RemoteActivityTarget? {
        guard provider != .deepseek, valid, let stamp = rootIdentity(provider) else { return nil }
        return .init(id: id, name: "WSL · " + distro, alias: "wsl-" + provider.rawValue + "-" +
            String(CompletionDismissalStore.digest([id, root(provider), stamp]).prefix(32)), home: root(provider))
    }
    func route(_ provider: AgentProvider) -> Data? {
        guard target(provider) != nil else { return nil }
        return try? JSONSerialization.data(withJSONObject: ["uid": uid, "user": user, "home": home, "identity": identity,
            "provider": provider.rawValue, "root": root(provider), "rootIdentity": rootIdentity(provider)!])
    }
    /// UNC conversion always requires the selected distro. A Windows drive or
    /// a similarly named distro can never turn into this source's Linux home.
    static func linuxPath(_ path: String, distro: String) -> String? {
        if validPath(path) { return path }
        let parts = path.replacingOccurrences(of: "\\", with: "/").split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard path.hasPrefix("\\\\") || path.hasPrefix("//"), parts.count >= 3,
              ["wsl$", "wsl.localhost"].contains(parts[0].lowercased()), parts[1].caseInsensitiveCompare(distro) == .orderedSame else { return nil }
        let result = "/" + parts.dropFirst(2).joined(separator: "/")
        return validPath(result) ? result : nil
    }
}

final class WindowsWSLRegistry: @unchecked Sendable {
    private let lock = NSLock()
    private var revision: UInt64 = 0
    private var profiles: [WindowsWSLProfile] = []
    private var active: Set<String> = []
    private var installed: [String]?
    private var probeAfter: [String: Date] = [:]
    private var helpers: [String: UUID] = [:]
    var installations: [String]? { lock.lock(); defer { lock.unlock() }; return installed }
    func begin() -> UInt64 { lock.lock(); defer { lock.unlock() }; revision &+= 1; return revision }
    @discardableResult func accept(_ values: [WindowsWSLProfile], installed: Set<String>, ticket: UInt64) -> Bool {
        lock.lock(); defer { lock.unlock() }; guard revision == ticket else { return false }
        profiles.removeAll { !installed.contains($0.distro.lowercased()) }
        for value in values where value.valid {
            profiles.removeAll { $0.distro.caseInsensitiveCompare(value.distro) == .orderedSame }
            profiles.append(value)
        }
        active = Set(values.filter(\.valid).map(\.id)); return true
    }
    func suspend(ticket: UInt64? = nil) {
        lock.lock(); defer { lock.unlock() }
        guard ticket == nil || ticket == revision else { return }
        revision &+= 1; active = []; helpers.removeAll(); probeAfter.removeAll()
    }
    @discardableResult func rememberInstalled(_ values: [String], ticket: UInt64) -> Bool {
        lock.lock(); defer { lock.unlock() }; guard revision == ticket else { return false }
        installed = values
        let wanted = Set(values.map { $0.lowercased() })
        profiles.removeAll { !wanted.contains($0.distro.lowercased()) }
        active.formIntersection(profiles.map(\.id))
        return true
    }
    func dueForProbe(_ distro: String, at now: Date, force: Bool, ticket: UInt64) -> Bool {
        lock.lock(); defer { lock.unlock() }
        let name = distro.lowercased()
        guard revision == ticket, force || (probeAfter[name] ?? .distantPast) <= now else { return false }
        probeAfter[name] = now.addingTimeInterval(300)
        return true
    }
    func noteRunning(_ values: Set<String>, ticket: UInt64) {
        lock.lock(); defer { lock.unlock() }; guard revision == ticket else { return }
        probeAfter = probeAfter.filter { values.contains($0.key) }
        active.formIntersection(profiles.filter { values.contains($0.distro.lowercased()) }.map(\.id))
    }
    func beginHelper(_ profile: WindowsWSLProfile, provider: AgentProvider) -> UUID? {
        lock.lock(); defer { lock.unlock() }
        guard active.contains(profile.id), profiles.contains(profile) else { return nil }
        let id = UUID()
        helpers[provider.rawValue + profile.id] = id
        return id
    }
    func endHelper(_ profile: WindowsWSLProfile, provider: AgentProvider, id: UUID) -> Bool {
        lock.lock(); defer { lock.unlock() }
        let key = provider.rawValue + profile.id
        guard helpers[key] == id else { return false }
        helpers[key] = nil
        guard profiles.contains(profile), active.remove(profile.id) != nil else { return false }
        revision &+= 1
        probeAfter[profile.distro.lowercased()] = nil
        return true
    }
    func snapshot() -> (profiles: [WindowsWSLProfile], active: Set<String>) {
        lock.lock(); defer { lock.unlock() }; return (profiles, active)
    }
    func profile(id: String, provider: AgentProvider, activeOnly: Bool = true) -> WindowsWSLProfile? {
        lock.lock(); defer { lock.unlock() }
        return profiles.first { $0.id == id && (!activeOnly || active.contains(id)) && $0.target(provider) != nil }
    }
    func arguments(_ target: RemoteActivityTarget) -> [String]? {
        for provider in [AgentProvider.codex, .claude] {
            if let profile = profile(id: target.id, provider: provider), profile.target(provider) == target {
                return ["--pacer-wsl", provider.rawValue, target.id]
            }
        }
        return nil
    }
    func targets(_ provider: AgentProvider) -> [RemoteActivityTarget] {
        let current = snapshot()
        return current.profiles.filter { current.active.contains($0.id) }.compactMap { $0.target(provider) }.prefix(8).map { $0 }
    }
}

struct WindowsWSLServices: Sendable {
    typealias Capture = @Sendable (URL, [String], TimeInterval, Int) async -> Data?
    typealias Start = @Sendable (ChildProcessRequest, Data, @escaping @Sendable (Data) async -> Void,
                                @escaping @Sendable () async -> Void) throws -> any ChildProcessConnection
    typealias Disconnect = @Sendable (AgentProvider, String) async -> Void
    let executable: URL
    let registry: WindowsWSLRegistry
    let capture: Capture
    let start: Start
    let registrationPresence: @Sendable () -> Int32
    let watchRegistrations: @Sendable (@escaping @Sendable (Bool) -> Void) -> (any ActivityFileWatch)?
    init(executable: URL? = nil, registry: WindowsWSLRegistry = WindowsWSLRegistry(),
         capture: @escaping Capture = { await WindowsSubprocess.capture(executable: $0, arguments: $1, timeout: $2, limit: $3,
             environment: WindowsWSLInvocation.environment(ProcessInfo.processInfo.environment)) },
         start: @escaping Start = { try WindowsHelperProcess($0, initialInput: $1, privateErrors: true, output: $2, ended: $3) },
         registrationPresence: @escaping @Sendable () -> Int32 = { pacer_wsl_registration_presence() },
         watchRegistrations: @escaping @Sendable (@escaping @Sendable (Bool) -> Void) -> (any ActivityFileWatch)? = { WindowsWSLRegistrationWatch.start($0) }) {
        let system = ProcessInfo.processInfo.environment["SystemRoot"] ?? "C:/Windows"
        self.executable = executable ?? URL(fileURLWithPath: system).appendingPathComponent("System32/wsl.exe")
        self.registry = registry; self.capture = capture; self.start = start
        self.registrationPresence = registrationPresence; self.watchRegistrations = watchRegistrations
    }
    static func script(_ name: String) -> String? {
        guard let url = Bundle.module.resourceURL?.appendingPathComponent("WSL/" + name + ".py"),
              let text = try? String(contentsOf: url, encoding: .utf8), !text.isEmpty else { return nil }
        if ["bootstrap", "setup", "console", "read-quota-files"].contains(name), let identity = script("identity") {
            return identity + "\n" + text
        }
        return text
    }
    static func distributions(_ bytes: Data) -> [String]? {
        guard bytes.count <= 65536 else { return nil }
        let utf16 = bytes.starts(with: [255, 254]) || bytes.filter { $0 == 0 }.count > bytes.count / 8
        guard let text = String(data: bytes, encoding: utf16 ? .utf16LittleEndian : .utf8) else { return nil }
        let values = text.replacingOccurrences(of: "\u{feff}", with: "").split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
        guard values.count <= 32, values.allSatisfy(WindowsWSLProfile.validDistro), Set(values.map { $0.lowercased() }).count == values.count else { return nil }
        return values
    }
    func installedDistributions() async -> [String]? {
        if let data = await capture(executable, ["--list", "--quiet"], 4, 65536), let values = Self.distributions(data) { return values }
        return registrationPresence() == 0 ? [] : nil
    }
    @discardableResult func discover(checkInstalled: Bool = true, monitoring: Bool = true, forceProfiles: Bool = true,
                                     providers: Set<AgentProvider> = [.codex, .claude], at now: Date = Date()) async -> WindowsWSLAvailability? {
        guard !Task.isCancelled else { return nil }
        let ticket = registry.begin()
        var installed = registry.installations
        if checkInstalled || installed == nil { installed = await installedDistributions() }
        guard !Task.isCancelled else { return nil }
        guard let initial = installed else { return .failed }
        guard registry.rememberInstalled(initial, ticket: ticket) else { return nil }
        if initial.isEmpty { return .unavailable }
        guard monitoring else { return .available }
        guard let runningBytes = await capture(executable, ["--list", "--running", "--quiet"], 4, 65536),
              let running = Self.distributions(runningBytes), let script = Self.script("discover") else { return .failed }
        guard !Task.isCancelled else { return nil }
        let runningNames = Set(running.map { $0.lowercased() })
        var names = Set(initial.map { $0.lowercased() })
        if !checkInstalled && !runningNames.isSubset(of: names), let current = await installedDistributions() {
            guard !Task.isCancelled, registry.rememberInstalled(current, ticket: ticket) else { return nil }
            installed = current
            names = Set(current.map { $0.lowercased() })
        }
        if names.isEmpty { return .unavailable }
        registry.noteRunning(runningNames, ticket: ticket)
        let previous = registry.snapshot()
        var values: [WindowsWSLProfile] = []
        for distro in (installed ?? []).filter({ runningNames.contains($0.lowercased()) }).prefix(8) {
            guard !Task.isCancelled else { return nil }
            let existing = previous.profiles.first { $0.distro.caseInsensitiveCompare(distro) == .orderedSame && previous.active.contains($0.id) }
            let connected = existing.map { profile in providers.contains { profile.target($0) != nil } } == true
            if (!forceProfiles && connected) || !registry.dueForProbe(distro, at: now, force: forceProfiles, ticket: ticket) {
                if let existing { values.append(existing) }
                continue
            }
            let args = ["--distribution", distro, "--exec", "/usr/bin/python3", "-I", "-c", script]
            if let data = await capture(executable, args, 5, 16384), var profile = try? JSONDecoder().decode(WindowsWSLProfile.self, from: data) {
                profile.distro = distro; if profile.valid { values.append(profile) }
            }
        }
        guard !Task.isCancelled else { return nil }
        return registry.accept(values, installed: names, ticket: ticket) ? .available : nil
    }
    func launcher(base: any HelperProcessLauncher = WindowsHelperProcessLauncher(),
                  disconnected: Disconnect? = nil) -> any HelperProcessLauncher {
        WindowsWSLHelperLauncher(services: self, base: base, disconnected: disconnected)
    }
    func setupArguments(_ target: RemoteActivityTarget, requireHome: Bool = true, progressRing: Bool = false, automatic: Bool = false) throws -> [String] {
        guard let profile = registry.profile(id: target.id, provider: .claude), profile.target(.claude) == target,
              let arguments = registry.arguments(target) else { throw ClaudeRemoteSetup.Failure.invalidTarget }
        return arguments + [try ClaudeRemoteSetup.command(home: profile.claudeHome, requireHome: requireHome, progressRing: progressRing, automatic: automatic)]
    }
}

private struct WindowsWSLHelperLauncher: HelperProcessLauncher {
    let services: WindowsWSLServices
    let base: any HelperProcessLauncher
    let disconnected: WindowsWSLServices.Disconnect?
    func launch(_ request: ChildProcessRequest, output: @escaping @Sendable (Data) async -> Void,
                ended: @escaping @Sendable () async -> Void) throws -> any ChildProcessConnection {
        guard request.arguments.first == "--pacer-wsl" else { return try base.launch(request, output: output, ended: ended) }
        guard request.arguments.count == 4, let provider = AgentProvider(rawValue: request.arguments[1]),
              let profile = services.registry.profile(id: request.arguments[2], provider: provider),
              let invocation = WindowsWSLInvocation(profile: profile, provider: provider, command: request.arguments[3]) else { throw CodexClientError.invalidResponse }
        let wrapped = ChildProcessRequest(executable: services.executable, arguments: invocation.arguments, environment: WindowsWSLInvocation.environment(request.environment))
        guard let id = services.registry.beginHelper(profile, provider: provider) else { throw CodexClientError.disconnected }
        do {
            return try services.start(wrapped, invocation.input, { bytes in
                guard services.registry.profile(id: profile.id, provider: provider)?.target(provider) == profile.target(provider) else { return }
                await output(bytes)
            }, {
                let invalidated = disconnected != nil && services.registry.endHelper(profile, provider: provider, id: id)
                await ended()
                if invalidated { await disconnected?(provider, profile.id) }
            })
        } catch {
            if let disconnected, services.registry.endHelper(profile, provider: provider, id: id) {
                Task { await disconnected(provider, profile.id) }
            }
            throw error
        }
    }
}

struct WindowsWSLInvocation {
    let arguments: [String], input: Data
    init?(profile: WindowsWSLProfile, provider: AgentProvider, command: String, setup: Bool = false) {
        guard let route = profile.route(provider), let bootstrap = WindowsWSLServices.script(setup ? "setup" : "bootstrap"),
              !command.isEmpty, !command.contains("\0"), command.utf8.count <= 1024 * 1024 else { return nil }
        arguments = ["--distribution", profile.distro, "--user", profile.user, "--exec", "/usr/bin/python3", "-I", "-u", "-c", bootstrap, route.base64EncodedString()]
        input = Data((String(command.utf8.count) + "\n" + command).utf8)
    }
    static func environment(_ values: [String: String]) -> [String: String] {
        values.filter { !["wslenv", "codex_home", "claude_config_dir", "claude_code_oauth_token", "openai_api_key", "anthropic_api_key"].contains($0.key.lowercased()) }
    }
}
