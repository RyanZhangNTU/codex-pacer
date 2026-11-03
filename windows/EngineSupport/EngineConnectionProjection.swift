import Foundation
import PacerCore

/// Windows supplies transport and installer facts; Core owns the page rules.
enum EngineConnectionProjection {
    static func make(enabled: Set<AgentProvider>, statuses: [AgentProvider: [String: RuntimeStreamStatus]],
                     targets: [RemoteActivityTarget], setups: [EngineClaudeRemoteSetup],
                     profiles: [WindowsWSLProfile], activeWSL: Set<String>, canRetrySetup: Bool) -> ConnectionPagePresentation {
        let ssh = targets.filter { $0.id.hasPrefix(ConnectionSource.sshPrefix) }
        let rows = Dictionary(setups.map { ($0.sourceID, $0) }, uniquingKeysWith: { _, last in last })
        let configured = Set(ssh.filter { rows[$0.id]?.configured == true }.map(\.alias))
        let configuring = Set(ssh.filter { rows[$0.id]?.inFlight == true }.map(\.alias))
        let failed = Set(ssh.filter { rows[$0.id]?.message != nil }.map(\.alias))
        let wslSetup = rows.filter { $0.key.hasPrefix(ConnectionSource.wslPrefix) }.mapValues { row in
            row.inFlight ? ConnectionPagePresentation.Setup.configuring : row.message != nil ? .failed : .configured
        }
        let quotas = Set(profiles.filter { activeWSL.contains($0.id) }.flatMap { profile in
            [AgentProvider.codex, .claude].compactMap { provider in
                profile.target(provider).map { _ in provider.rawValue + ":" + profile.id }
            }
        })
        return .init(enabledProviders: AgentProvider.allCases.filter { enabled.contains($0) }, statuses: statuses,
            claudeAliases: ssh.map(\.alias), configured: configured, configuring: configuring, failed: failed,
            names: Dictionary(ssh.map { ($0.alias, $0.name) }, uniquingKeysWith: { first, _ in first }),
            setup: wslSetup, canRetrySetup: canRetrySetup, quotaSources: quotas, transportProblemsFirst: true)
    }
}
