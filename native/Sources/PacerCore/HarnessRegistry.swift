import Foundation

/// How a module shows what is left to spend. Each kind keeps its own units.
public enum HarnessBalanceKind: String, Codable, Sendable {
    /// Rate-limit windows with a reset, read as remaining percent.
    case quotaWindows
    /// A prepaid currency balance with optional budgets.
    case wallet
    /// Account credits from the service's bill, with an optional plan cycle.
    case accountCredits
}

/// A module's colors. The icon keeps the brand color whatever the accent.
public struct HarnessBrand: Equatable, Sendable {
    public struct RGB: Equatable, Sendable {
        public let red: UInt8, green: UInt8, blue: UInt8
        public init(_ hex: UInt32) {
            red = UInt8((hex >> 16) & 0xff); green = UInt8((hex >> 8) & 0xff); blue = UInt8(hex & 0xff)
        }
        public var hex: String { String(format: "#%02X%02X%02X", red, green, blue) }
    }
    /// The brand color on the dark island.
    public let dark: RGB
    /// One shade darker, for light glass.
    public let light: RGB
    /// Under a single accent color, how far this module's shade lifts toward
    /// white on the dark island, and its luminance on light glass. The values
    /// keep every module apart from the others.
    public let accentLift: Double
    public let accentLuminance: Double

    /// Gray, for test fixtures. Registered modules choose their own colors.
    public static let neutral = HarnessBrand(dark: .init(0xA1A1A6), light: .init(0x5A5A60), accentLift: 0.3, accentLuminance: 0.1)
}

public struct HarnessDescriptor: Sendable {
    public let id: AgentProvider
    public let name: String
    public let symbol: String
    public let defaultMode: ProviderModuleMode
    public let brand: HarnessBrand
    /// Where to get the app, for the module library.
    public let website: URL?
    public let balance: HarnessBalanceKind?
    public let hasRateDisplay: Bool
    public let hasTaskProgress: Bool
    public let reportsSessionUsage: Bool
    public let progressConnector: Bool
    /// The account sign-in and bill, for account credits.
    public let accountCredits: HarnessAccountCreditsDefinition?

    /// Quota windows or a wallet: the dials and bar values that predate account credits.
    public var hasQuotaDisplay: Bool { balance == .quotaWindows || balance == .wallet }
    public var hasQuotaWindows: Bool { balance == .quotaWindows }
    public var reportsAccountCredits: Bool { balance == .accountCredits }

    package init(id: AgentProvider, name: String, symbol: String, defaultMode: ProviderModuleMode = .automatic,
                 brand: HarnessBrand = .neutral, website: URL? = nil, balance: HarnessBalanceKind? = nil,
                 hasRateDisplay: Bool = false, hasTaskProgress: Bool = false, reportsSessionUsage: Bool = false,
                 progressConnector: Bool = false, accountCredits: HarnessAccountCreditsDefinition? = nil) {
        self.id = id
        self.name = name
        self.symbol = symbol
        self.defaultMode = defaultMode
        self.brand = brand
        self.website = website
        self.balance = balance
        self.hasRateDisplay = hasRateDisplay
        self.hasTaskProgress = hasTaskProgress
        self.reportsSessionUsage = reportsSessionUsage
        self.progressConnector = progressConnector
        self.accountCredits = accountCredits
    }
}

/// Every module is described here once. Settings, the module library, the
/// collapsed bar, the expanded panel and both hosts read these descriptors;
/// strings follow the key families checked by the registry conformance test.
public enum HarnessRegistry {
    private static let existing: [HarnessDescriptor] = [
        .init(id: .codex, name: "Codex", symbol: "chevron.left.forwardslash.chevron.right",
              brand: .init(dark: .init(0x7DD6C4), light: .init(0x0E8C78), accentLift: 0, accentLuminance: 0.07),
              website: URL(string: "https://openai.com/codex/"), balance: .quotaWindows, hasRateDisplay: true, hasTaskProgress: true),
        .init(id: .claude, name: "Claude", symbol: "asterisk",
              brand: .init(dark: .init(0xF29C6B), light: .init(0xC4581F), accentLift: 0.42, accentLuminance: 0.12),
              website: URL(string: "https://claude.com/product/claude-code"), balance: .quotaWindows, hasRateDisplay: true, hasTaskProgress: true),
        .init(id: .deepseek, name: "DeepSeek", symbol: "water.waves",
              brand: .init(dark: .init(0x7B93FF), light: .init(0x3E5BDB), accentLift: 0.66, accentLuminance: 0.2),
              website: URL(string: "https://www.deepseek.com/"), balance: .wallet, hasRateDisplay: true, hasTaskProgress: true)
    ]

    public static let legacyIDs = existing.map(\.id)
    package static let legacyIDSet = Set(legacyIDs)
    public static let descriptors = existing + localHarnesses.map(\.descriptor)
    package static let ids = descriptors.map(\.id)
    private static let order = Dictionary(uniqueKeysWithValues: ids.enumerated().map { ($0.element, $0.offset) })
    private static let byID = Dictionary(uniqueKeysWithValues: descriptors.map { ($0.id.rawValue, $0) })

    public static func descriptor(for id: AgentProvider) -> HarnessDescriptor? { byID[id.rawValue] }
    package static func registeredID(_ value: String) -> AgentProvider? { byID[value]?.id }
    /// Registered modules with a capability, in registry order.
    public static func ids(where include: (HarnessDescriptor) -> Bool) -> [AgentProvider] { descriptors.filter(include).map(\.id) }

    package static func orderedBefore(_ a: AgentProvider, _ b: AgentProvider) -> Bool {
        let left = order[a] ?? Int.max, right = order[b] ?? Int.max
        return left == right ? a.rawValue < b.rawValue : left < right
    }

    package static let localHarnesses: [LocalHarnessDefinition] = [WorkBuddyHarness.china, WorkBuddyHarness.international, AntigravityHarness.definition]
}
