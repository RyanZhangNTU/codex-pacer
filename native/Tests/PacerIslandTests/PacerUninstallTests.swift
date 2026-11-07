import Foundation
import XCTest
@testable import PacerCore
@testable import PacerIsland

final class PacerUninstallTests: XCTestCase {
    private final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private var items: [String] = []
        func add(_ item: String) { lock.lock(); items.append(item); lock.unlock() }
        var values: [String] { lock.lock(); defer { lock.unlock() }; return items.sorted() }
    }

    private struct Fixture: Error {}

    private func root() throws -> URL {
        let root = URL(fileURLWithPath: "/private/tmp/pacer-uninstall-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    /// The selected, environment and default homes are each visited once,
    /// and every recorded host is included even when it is no longer listed.
    func testPlanVisitsEachHomeOnceAndEveryRecordedHost() {
        let user = URL(fileURLWithPath: "/private/tmp/pacer-uninstall-user")
        let known = RemoteActivityTarget(id: "remote-ssh-discovered:box", name: "Box", alias: "box", home: "~/.claude", sshPort: 2222)
        let plan = PacerUninstall.plan(claudeHome: user.appendingPathComponent("custom-claude"), codexHome: user.appendingPathComponent(".codex"),
            codexExecutable: "/opt/codex", configuredHosts: ["zeta", "box"], knownTargets: [known],
            environment: ["CLAUDE_CONFIG_DIR": user.path + "/nested/../custom-claude", "CODEX_HOME": ""], userHome: user)
        XCTAssertEqual(plan.claudeHomes.map(\.path), [user.path + "/custom-claude", user.path + "/.claude"])
        XCTAssertEqual(plan.codexHomes.map(\.path), [user.path + "/.codex"])
        XCTAssertEqual(plan.hosts, [known, RemoteActivityTarget(id: "ssh:zeta", name: "zeta", alias: "zeta", home: "~/.claude")])
        XCTAssertEqual(plan.codexExecutable, "/opt/codex")

        let other = PacerUninstall.plan(claudeHome: user.appendingPathComponent(".claude"), codexHome: user.appendingPathComponent("work-codex"),
            codexExecutable: "", configuredHosts: [], knownTargets: [known],
            environment: ["CODEX_HOME": user.path + "/env-codex"], userHome: user)
        XCTAssertEqual(other.claudeHomes.map(\.path), [user.path + "/.claude"])
        XCTAssertEqual(other.codexHomes.map(\.path), [user.path + "/work-codex", user.path + "/env-codex", user.path + "/.codex"])
        XCTAssertTrue(other.hosts.isEmpty, "A listed host Pacer never set up is not contacted")
    }

    /// Every place is tried, a failure anywhere is reported by place, a host
    /// is forgotten only once removed, and a retry visits only the leftovers.
    func testRemovalReportsLeftoversAndRetriesOnlyThem() async {
        let homes = (1...4).map { URL(fileURLWithPath: "/private/tmp/pacer-uninstall-home-\($0)") }
        let up = RemoteActivityTarget(id: "ssh:up", name: "Up", alias: "up", home: "~/.claude")
        let down = RemoteActivityTarget(id: "ssh:down", name: "Down", alias: "down", home: "~/.claude")
        let plan = PacerUninstall.Plan(claudeHomes: [homes[0], homes[1]], codexHomes: [homes[2], homes[3]],
                                       codexExecutable: "/opt/codex", hosts: [up, down])
        let visited = Recorder(), forgotten = Recorder()
        let failing: Set<String> = [homes[1].path, homes[3].path, "down"]
        let services = PacerUninstall.Services(
            removeClaude: { home in visited.add("claude " + home.path); if failing.contains(home.path) { throw Fixture() } },
            removeCodex: { home, executable in visited.add("codex \(home.path) \(executable)"); return !failing.contains(home.path) },
            removeHost: { target in visited.add("host " + target.alias); if failing.contains(target.alias) { throw Fixture() } },
            forgetHost: { alias in forgotten.add(alias) })

        let leftovers = await PacerUninstall.removeConfiguration(plan, services: services)
        XCTAssertEqual(Set(leftovers), [.claude(homes[1]), .codex(homes[3]), .host(alias: "down", name: "Down")])
        XCTAssertEqual(visited.values, ["claude " + homes[0].path, "claude " + homes[1].path,
            "codex \(homes[2].path) /opt/codex", "codex \(homes[3].path) /opt/codex", "host down", "host up"])
        XCTAssertEqual(forgotten.values, ["up"])
        XCTAssertEqual(Set(leftovers.map(\.label)).count, 3)
        XCTAssertTrue(leftovers.contains { $0.label.contains("Down") })

        let retry = PacerUninstall.plan(plan, retrying: leftovers)
        XCTAssertEqual(retry.claudeHomes, [homes[1]])
        XCTAssertEqual(retry.codexHomes, [homes[3]])
        XCTAssertEqual(retry.hosts, [down])
        XCTAssertEqual(retry.codexExecutable, "/opt/codex")
        let emptyRetry = PacerUninstall.plan(plan, retrying: [])
        XCTAssertTrue(emptyRetry.claudeHomes.isEmpty && emptyRetry.codexHomes.isEmpty && emptyRetry.hosts.isEmpty)
    }

    /// Pacer's folders go only from homes whose entries were removed, and a
    /// Claude folder stays while settings still name it.
    func testOwnedFoldersSkipLeftoversAndReferencedHooks() throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let referenced = root.appendingPathComponent("referenced"), clean = root.appendingPathComponent("clean")
        let failed = root.appendingPathComponent("failed"), missing = root.appendingPathComponent("missing")
        let codex = root.appendingPathComponent("codex"), codexFailed = root.appendingPathComponent("codex-failed")
        for home in [referenced, clean, failed] { try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true) }
        let hook = referenced.appendingPathComponent("pacer/hook.py").path
        try Data(#"{"statusLine":{"type":"command","command":"python3 -S '\#(hook)' statusline"}}"#.utf8)
            .write(to: referenced.appendingPathComponent("settings.json"))
        try Data(#"{"custom":true}"#.utf8).write(to: clean.appendingPathComponent("settings.json"))
        let plan = PacerUninstall.Plan(claudeHomes: [referenced, clean, failed, missing], codexHomes: [codex, codexFailed],
                                       codexExecutable: "", hosts: [])
        let folders = PacerUninstall.ownedFolders(plan: plan, leftovers: [.claude(failed), .codex(codexFailed)])
        XCTAssertEqual(folders.map(\.path), [clean.appendingPathComponent("pacer").path, missing.appendingPathComponent("pacer").path,
                                            codex.appendingPathComponent("pacer/codex-progress").path])
    }
}
