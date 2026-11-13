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

    package static func openProgressConnectors(provider: AgentProvider) async -> Bool {
        guard provider.rawValue == "workbuddy", let application = await find(provider: provider),
              let destination = URL(string: "workbuddy-ai://connectors") else { return false }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        return await withCheckedContinuation { continuation in
            NSWorkspace.shared.open([destination], withApplicationAt: application, configuration: configuration) { _, error in
                continuation.resume(returning: error == nil)
            }
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
        guard let organization = definition.macSigningOrganization, let scheme = definition.conversationScheme,
              let bundle = Bundle(url: url), let identifier = bundle.bundleIdentifier,
              definition.macBundleIdentifiers.contains(identifier),
              let types = bundle.object(forInfoDictionaryKey: "CFBundleURLTypes") as? [[String: Any]],
              types.contains(where: { ($0["CFBundleURLSchemes"] as? [String])?.contains(scheme) == true }) else { return false }
        var code: SecStaticCode?, requirement: SecRequirement?
        let expression = "identifier \"" + identifier + "\" and anchor apple generic and certificate leaf[subject.O] = \"" + organization + "\""
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess, let code,
              SecRequirementCreateWithString(expression as CFString, [], &requirement) == errSecSuccess, let requirement else { return false }
        return SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSBasicValidateOnly), requirement) == errSecSuccess
    }
}
