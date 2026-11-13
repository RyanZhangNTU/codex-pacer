import Foundation
import PacerCore

/// Windows supplies transport and installer facts; Core owns the page rules.
enum EngineConnectionProjection {
    static func make(enabled: Set<AgentProvider>, statuses: [AgentProvider: [String: RuntimeStreamStatus]],
                     targets: [RemoteActivityTarget], setups: [EngineClaudeRemoteSetup],
                     wsl: WindowsWSLRegistry.Snapshot? = nil, canRetrySetup: Bool) -> ConnectionPagePresentation {
        let ssh = targets.filter { $0.id.hasPrefix(ConnectionSource.sshPrefix) }
        let rows = Dictionary(setups.map { ($0.sourceID, $0) }, uniquingKeysWith: { _, last in last })
        let configured = Set(ssh.filter { rows[$0.id]?.configured == true }.map(\.alias))
        let configuring = Set(ssh.filter { rows[$0.id]?.inFlight == true }.map(\.alias))
        let failed = Set(ssh.filter { rows[$0.id]?.message != nil }.map(\.alias))
        let wslSetup = rows.filter { $0.key.hasPrefix(ConnectionSource.wslPrefix) }.mapValues { row in
            row.inFlight ? ConnectionPagePresentation.Setup.configuring : row.message != nil ? .failed : .configured
        }
        let quotas = Set((wsl?.profiles ?? []).flatMap { profile in
            WindowsWSLProfile.providers.filter { wsl?.permits(profile, for: $0) == true }.map { $0.rawValue + ":" + profile.id }
        })
        return .init(enabledProviders: AgentProvider.allCases.filter { enabled.contains($0) }, statuses: statuses,
            claudeAliases: ssh.map(\.alias), configured: configured, configuring: configuring, failed: failed,
            names: Dictionary(ssh.map { ($0.alias, $0.name) }, uniquingKeysWith: { first, _ in first }),
            setup: wslSetup, canRetrySetup: canRetrySetup, quotaSources: quotas, transportProblemsFirst: true)
    }
}
