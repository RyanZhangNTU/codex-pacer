import Foundation

public struct HarnessDescriptor: Sendable {
    public let id: AgentProvider
    public let name: String
    public let symbol: String
    public let defaultMode: ProviderModuleMode
    public let hasQuotaDisplay: Bool
    public let hasRateDisplay: Bool
    public let hasTaskProgress: Bool
    public let reportsSessionUsage: Bool
    public let reportsAccountCredits: Bool
    public let usageGuide: URL?
    public let progressConnector: Bool

    package init(id: AgentProvider, name: String, symbol: String, defaultMode: ProviderModuleMode = .automatic,
                 hasQuotaDisplay: Bool = false, hasRateDisplay: Bool = false, hasTaskProgress: Bool = false,
                 reportsSessionUsage: Bool = false, reportsAccountCredits: Bool = false,
                 usageGuide: URL? = nil, progressConnector: Bool = false) {
        self.id = id
        self.name = name
        self.symbol = symbol
        self.defaultMode = defaultMode
        self.hasQuotaDisplay = hasQuotaDisplay
        self.hasRateDisplay = hasRateDisplay
        self.hasTaskProgress = hasTaskProgress
        self.reportsSessionUsage = reportsSessionUsage
        self.reportsAccountCredits = reportsAccountCredits
        self.usageGuide = usageGuide
        self.progressConnector = progressConnector
    }
}

public enum HarnessRegistry {
    private static let existing: [HarnessDescriptor] = [
        .init(id: .codex, name: "Codex", symbol: "chevron.left.forwardslash.chevron.right", hasQuotaDisplay: true, hasRateDisplay: true),
        .init(id: .claude, name: "Claude", symbol: "asterisk", hasQuotaDisplay: true, hasRateDisplay: true),
        .init(id: .deepseek, name: "DeepSeek", symbol: "water.waves", hasQuotaDisplay: true, hasRateDisplay: true)
    ]

    public static let legacyIDs = existing.map(\.id)
    package static let legacyIDSet = Set(legacyIDs)
    public static let descriptors = existing + localHarnesses.map(\.descriptor)
    package static let ids = descriptors.map(\.id)
    private static let order = Dictionary(uniqueKeysWithValues: ids.enumerated().map { ($0.element, $0.offset) })
    private static let byID = Dictionary(uniqueKeysWithValues: descriptors.map { ($0.id.rawValue, $0) })

    public static func descriptor(for id: AgentProvider) -> HarnessDescriptor? { byID[id.rawValue] }
    package static func registeredID(_ value: String) -> AgentProvider? { byID[value]?.id }

    package static func orderedBefore(_ a: AgentProvider, _ b: AgentProvider) -> Bool {
        let left = order[a] ?? Int.max, right = order[b] ?? Int.max
        return left == right ? a.rawValue < b.rawValue : left < right
    }

    package static let localHarnesses: [LocalHarnessDefinition] = [WorkBuddyHarness.definition]
}
