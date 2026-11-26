import AppKit
import Foundation
import PacerCore
import Security

/// Use a matching signed bundle directly rather than the system's default handler.
@MainActor package enum MacLocalHarnessApplication {
    package static func find(provider: AgentProvider, destination: URL) -> URL? {
        guard let definition = HarnessRegistry.localHarnesses.first(where: { $0.descriptor.id == provider }),
              let scheme = definition.conversationScheme, destination.scheme == scheme, destination.host == "chat",
              let session = UUID(uuidString: String(destination.path.dropFirst())),
              destination.absoluteString == scheme + "://chat/" + session.uuidString.lowercased() else { return nil }
        return candidates(for: definition).first { Self.isTrusted($0, definition: definition) }
    }

    package static func find(provider: AgentProvider) async -> URL? {
        guard let definition = HarnessRegistry.localHarnesses.first(where: { $0.descriptor.id == provider }) else { return nil }
        let locations = candidates(for: definition)
        return await Task.detached(priority: .utility) { locations.first { Self.isTrusted($0, definition: definition) } }.value
    }

    /// Opens the app on its connectors, where the user trusts Pacer's tool.
    package static func openProgressConnectors(provider: AgentProvider) async -> Bool {
        guard let definition = HarnessRegistry.localHarnesses.first(where: { $0.descriptor.id == provider }),
              let scheme = definition.conversationScheme, let path = definition.connectorsPath,
              let destination = URL(string: scheme + "://" + path), let application = await find(provider: provider) else { return false }
        return await open([destination], with: application)
    }

    /// Whether the module's app runs, and since when its earliest copy
    /// started; nil when that cannot be told. The app reads Pacer's tool only as it starts.
    package static func presence(provider: AgentProvider) -> HarnessProgressGuide.AppPresence? {
        guard let definition = HarnessRegistry.localHarnesses.first(where: { $0.descriptor.id == provider }),
              !definition.macBundleIdentifiers.isEmpty else { return nil }
        let running = NSWorkspace.shared.runningApplications.filter {
            $0.bundleIdentifier.map(definition.macBundleIdentifiers.contains) == true && !$0.isTerminated
        }
        guard !running.isEmpty else { return .notRunning }
        return running.compactMap(\.launchDate).min().map { .running(since: $0) }
    }

    /// The module's running app, the frontmost copy first.
    package static func running(provider: AgentProvider) -> NSRunningApplication? {
        let apps = runningAll(provider: provider)
        return apps.first(where: \.isActive) ?? apps.first
    }

    /// Every running copy of the module's app.
    package static func runningAll(provider: AgentProvider) -> [NSRunningApplication] {
        guard let definition = HarnessRegistry.localHarnesses.first(where: { $0.descriptor.id == provider }) else { return [] }
        return NSWorkspace.shared.runningApplications.filter {
            $0.bundleIdentifier.map(definition.macBundleIdentifiers.contains) == true && !$0.isTerminated
        }
    }

    /// Opens the app itself, so it makes its settings folder.
    package static func openApplication(provider: AgentProvider) async -> Bool {
        guard let application = await find(provider: provider) else { return false }
        return await open([], with: application)
    }

    private static func open(_ urls: [URL], with application: URL) async -> Bool {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        return await withCheckedContinuation { continuation in
            let done: @Sendable (NSRunningApplication?, (any Error)?) -> Void = { _, error in continuation.resume(returning: error == nil) }
            if urls.isEmpty { NSWorkspace.shared.openApplication(at: application, configuration: configuration, completionHandler: done) }
            else { NSWorkspace.shared.open(urls, withApplicationAt: application, configuration: configuration, completionHandler: done) }
        }
    }

    private static func candidates(for definition: LocalHarnessDefinition) -> [URL] {
        let workspace = NSWorkspace.shared
        let apps = definition.macBundleIdentifiers.sorted().compactMap { workspace.urlForApplication(withBundleIdentifier: $0) }
        let locations = definition.macApplicationNames.flatMap { name in
            [URL(fileURLWithPath: "/Applications/\(name).app"),
             FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications/\(name).app")]
        }
        return apps + locations
    }

    private nonisolated static func isTrusted(_ url: URL, definition: LocalHarnessDefinition) -> Bool {
        // An edition whose bundle ID is not known yet is trusted by its name,
        // its own URL scheme and its publisher's signature alone.
        let pinned = !definition.macBundleIdentifiers.isEmpty
        guard let bundle = Bundle(url: url), let identifier = bundle.bundleIdentifier,
              !pinned || definition.macBundleIdentifiers.contains(identifier) else { return false }
        if let scheme = definition.conversationScheme {
            guard let types = bundle.object(forInfoDictionaryKey: "CFBundleURLTypes") as? [[String: Any]],
                  types.contains(where: { ($0["CFBundleURLSchemes"] as? [String])?.contains(scheme) == true }) else { return false }
        } else if !pinned { return false }
        var code: SecStaticCode?, requirement: SecRequirement?
        let publisher: String
        if let team = definition.macTeamIdentifier { publisher = "certificate leaf[subject.OU] = \"" + team + "\"" }
        else if let organization = definition.macSigningOrganization { publisher = "certificate leaf[subject.O] = \"" + organization + "\"" }
        else { return false }
        let expression = (pinned ? "identifier \"" + identifier + "\" and " : "") + "anchor apple generic and " + publisher
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess, let code,
              SecRequirementCreateWithString(expression as CFString, [], &requirement) == errSecSuccess, let requirement else { return false }
        return SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSBasicValidateOnly), requirement) == errSecSuccess
    }
}
