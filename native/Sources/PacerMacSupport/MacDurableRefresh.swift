import Darwin
import Foundation

/// A local plugin write needs a new Desktop executor registration. Persist a
/// single pending request across app restarts; a busy or unfamiliar executor
/// can satisfy it by reconnecting through Desktop's normal lifecycle.
actor MacDurableRefresh {
    static let shared = MacDurableRefresh()
    private struct Request: Codable, Equatable {
        let generation: UUID
        let writtenAt: Date
        let enabled: Bool?
        var signalled: Bool
    }
    private struct Quiet {
        let generation: UUID
        let executor: MacDurableExecutor
        let since: Date
    }
    private var configuring: Set<URL> = []
    private var quiet: [URL: Quiet] = [:]

    func begin(home: URL) {
        configuring.insert(home)
        quiet.removeValue(forKey: home)
    }

    func interrupt(home: URL) {
        quiet.removeValue(forKey: home.standardizedFileURL)
    }

    func finish(home: URL, changed: Bool, enabled: Bool) -> Bool {
        defer { configuring.remove(home) }
        guard changed else { return true }
        do {
            try write(Request(generation: UUID(), writtenAt: Date(), enabled: enabled, signalled: false), home: home)
            return true
        } catch { return false }
    }

    func observe(home: URL, executor: MacDurableExecutor, catalogIdle: Bool,
                 verifiedReportTurnStartedAt: Date? = nil) {
        let home = home.standardizedFileURL
        guard !configuring.contains(home), var request = read(home: home) else {
            quiet.removeValue(forKey: home)
            return
        }
        // A verified Mac receipt from a new turn can settle an install
        // after Desktop updates capabilities without a new executor PID.
        let adoptedInPlace = request.enabled != false &&
            verifiedReportTurnStartedAt.map { $0 > request.writtenAt } == true
        if executor.startedAt > request.writtenAt || adoptedInPlace {
            quiet.removeValue(forKey: home)
            if let path = try? marker(home: home) { try? MacClaudeHookStorage().remove(path) }
            return
        }
        guard !request.signalled, catalogIdle, MacDurableExecutor.children(of: executor.pid)?.isEmpty == true,
              let bundle = Bundle(url: executor.application),
              bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String == "25894",
              bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String == "26.1103.60933" else {
            quiet.removeValue(forKey: home)
            return
        }
        let now = Date()
        guard let observation = quiet[home], observation.executor == executor, observation.generation == request.generation else {
            quiet[home] = Quiet(generation: request.generation, executor: executor, since: now)
            return
        }
        guard now.timeIntervalSince(observation.since) >= 12,
              MacDurableExecutor.isSignedCodex(executor.application), MacDurableExecutor.find(peer: executor.desktopPID) == executor,
              MacDurableExecutor.children(of: executor.pid)?.isEmpty == true, read(home: home) == request else { return }
        // This Desktop build's bundled exec-server handles SIGTERM with a
        // graceful drain. Desktop owns the replacement and registers roots
        // before spawning it. Never escalate a signal or retry this request.
        request.signalled = true
        guard (try? write(request, home: home)) != nil else { return }
        _ = Darwin.kill(executor.pid, SIGTERM)
        quiet.removeValue(forKey: home)
    }

    private func marker(home: URL) throws -> URL {
        let root = home.appendingPathComponent("pacer/codex-progress", isDirectory: true)
        let path = root.appendingPathComponent("executor-refresh.json")
        let storage = MacClaudeHookStorage()
        for url in [home, home.appendingPathComponent("pacer"), root, path] { try storage.validate(url) }
        return path
    }

    private func read(home: URL) -> Request? {
        guard let path = try? marker(home: home), let bytes = try? MacClaudeHookStorage().read(path), bytes.count <= 512 else { return nil }
        return try? JSONDecoder().decode(Request.self, from: bytes)
    }

    private func write(_ request: Request, home: URL) throws {
        try MacClaudeHookStorage().replace(marker(home: home), with: JSONEncoder().encode(request), permissions: 0o600)
    }
}
