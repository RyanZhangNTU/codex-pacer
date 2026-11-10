import Foundation

/// The expanded panel's blocks, top to bottom. Presentation only: removing a
/// block never stops its collector. Without a saved layout the blocks follow
/// the enabled services, exactly as the panel looked before it had blocks; the
/// first edit saves the blocks as they then appeared.
public struct ExpandedPanelLayout: Equatable, Codable, Sendable {
    public enum Block: String, CaseIterable, Codable, Sendable, Identifiable {
        case tasks, codex, claude, deepseek, deepseekSpend, deepseekWeek
        public var id: String { rawValue }
        public var label: String { L10n.text("panel.block." + rawValue) }
        public var detail: String { L10n.text("panel.block_detail." + rawValue) }
        /// The service a block reads; a disabled service hides its blocks but keeps their places.
        public var provider: AgentProvider? {
            switch self {
            case .tasks: nil
            case .codex: .codex
            case .claude: .claude
            case .deepseek, .deepseekSpend, .deepseekWeek: .deepseek
            }
        }
        /// Adjacent quota blocks share one row when the panel pairs them.
        public var isQuota: Bool { self == .codex || self == .claude || self == .deepseek }
        public var group: Group { self == .tasks ? .tasks : isQuota ? .quota : .deepseek }
        public var symbol: String {
            switch self {
            case .tasks: "text.alignleft"
            case .codex: "chevron.left.forwardslash.chevron.right"
            case .claude: "asterisk"
            case .deepseek: "water.waves"
            case .deepseekSpend: "chart.pie"
            case .deepseekWeek: "chart.xyaxis.line"
            }
        }
        public func isAvailable(for providers: Set<AgentProvider>) -> Bool { provider.map(providers.contains) ?? true }
        /// Earlier names map to their blocks; unknown names are dropped.
        fileprivate static func saved(_ value: String) -> Self? { Self(rawValue: value) }
    }
    /// How the settings page's library groups the blocks.
    public enum Group: String, CaseIterable, Sendable {
        case tasks, quota, deepseek
        public var label: String { L10n.text("panel.group." + rawValue) }
        public var blocks: [Block] { Block.allCases.filter { $0.group == self } }
    }

    public static let defaultsKey = "expandedPanelLayout"
    public static let version = 1
    /// Larger saved or requested text is damaged.
    public static let byteLimit = 2048
    public var blocks: [Block]

    public init(blocks: [Block]) {
        var seen: Set<Block> = []
        self.blocks = blocks.filter { seen.insert($0).inserted }
    }

    /// The panel before blocks: tasks, then every quota, then DeepSeek's spend
    /// and week when DeepSeek is the only service and its content was Detailed.
    public static func automatic(providers: Set<AgentProvider>, deepseekDetailed: Bool) -> Self {
        var blocks: [Block] = [.tasks, .codex, .claude, .deepseek]
        if deepseekDetailed, providers == [.deepseek] { blocks += [.deepseekSpend, .deepseekWeek] }
        return Self(blocks: blocks)
    }

    /// The saved layout, or the automatic one when none is saved or it is damaged.
    public static func resolved(saved: Self?, providers: Set<AgentProvider>, deepseekDetailed: Bool) -> Self {
        saved ?? automatic(providers: providers, deepseekDetailed: deepseekDetailed)
    }

    public func visibleBlocks(providers: Set<AgentProvider>) -> [Block] { blocks.filter { $0.isAvailable(for: providers) } }

    /// Whether removing the block would leave nothing to show for these services.
    public func isLastVisible(_ block: Block, providers: Set<AgentProvider>) -> Bool {
        let visible = visibleBlocks(providers: providers)
        return visible == [block]
    }

    /// Adds a block at its usual place among the others, or removes it. The
    /// last block the services can show stays, so the panel keeps its actions.
    public mutating func toggle(_ block: Block, providers: Set<AgentProvider>) {
        if blocks.contains(block) {
            guard !isLastVisible(block, providers: providers) else { return }
            blocks.removeAll { $0 == block }
        } else {
            let order = Block.allCases
            let rank = order.firstIndex(of: block) ?? order.count
            let index = blocks.firstIndex { (order.firstIndex(of: $0) ?? order.count) > rank } ?? blocks.count
            blocks.insert(block, at: index)
        }
    }

    /// Moves a block before another, or to the end.
    public mutating func move(_ block: Block, before: Block?) {
        guard block != before, blocks.contains(block) else { return }
        blocks.removeAll { $0 == block }
        let index = before.flatMap { blocks.firstIndex(of: $0) } ?? blocks.count
        blocks.insert(block, at: index)
    }

    /// Moves a block past `offset` blocks the services can show; hidden blocks keep their places.
    public mutating func shift(_ block: Block, by offset: Int, providers: Set<AgentProvider>) {
        guard let index = blocks.firstIndex(of: block) else { return }
        let positions = blocks.indices.filter { blocks[$0].isAvailable(for: providers) }
        guard let position = positions.firstIndex(of: index) else { return }
        let target = positions[min(positions.count - 1, max(0, position + offset))]
        guard target != index else { return }
        blocks.remove(at: index); blocks.insert(block, at: target)
    }

    private enum CodingKeys: String, CodingKey { case version, blocks }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let schema = try values.decode(Int.self, forKey: .version)
        guard schema == Self.version else {
            throw DecodingError.dataCorruptedError(forKey: .version, in: values, debugDescription: "Unsupported panel layout")
        }
        self.init(blocks: try values.decode([String].self, forKey: .blocks).compactMap(Block.saved))
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(Self.version, forKey: .version)
        try values.encode(blocks.map(\.rawValue), forKey: .blocks)
    }

    /// Missing, damaged, oversized or newer text reads as no saved layout.
    public static func decode(_ json: String?) -> Self? {
        guard let json, json.utf8.count <= byteLimit, let data = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(Self.self, from: data)
    }

    /// The layout as sorted JSON, the form both hosts store and send.
    public var json: String {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return (try? encoder.encode(self)).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
    }

    public static func load(from defaults: UserDefaults = .standard) -> Self? {
        guard let data = defaults.data(forKey: defaultsKey), data.count <= byteLimit else { return nil }
        return try? JSONDecoder().decode(Self.self, from: data)
    }

    public func save(to defaults: UserDefaults = .standard) {
        defaults.set(Data(json.utf8), forKey: Self.defaultsKey)
    }

    /// Restoring the automatic layout forgets the saved one.
    public static func clear(from defaults: UserDefaults = .standard) { defaults.removeObject(forKey: defaultsKey) }
}

/// Choices that change how the expanded panel's blocks draw. Each field
/// decodes on its own: a missing or unknown value falls back to its default,
/// so a damaged or newer preference never resets the other choices. Every
/// choice is edited in the Expanded Panel page's selected-block card.
public struct ExpandedPanelOptions: Codable, Equatable, Sendable {
    public enum RowStyle: String, Codable, CaseIterable, Sendable { case twoLine, oneLine }
    /// What a task row shows besides its name and state. A hidden field stays
    /// in the row's accessibility text.
    public enum RowField: String, Codable, CaseIterable, Sendable {
        case rate, turnTime, model, source, subagents, cost
        public var label: String { L10n.text("panel.field." + rawValue) }
        /// The one-line row keeps only the trailing readings of line one.
        public var showsInOneLine: Bool { self == .rate || self == .turnTime }
    }
    /// Which windows one service's quota draws.
    public enum Periods: String, Codable, CaseIterable, Sendable { case both, weekly, fiveHour }
    /// Adjacent quota blocks share a row, or each takes its own with details.
    public enum Arrange: String, Codable, CaseIterable, Sendable { case pair, stack }
    /// The budget dial needs a budget; without one the day dial shows either way.
    public enum DeepSeekDial: String, Codable, CaseIterable, Sendable { case budget, day }
    /// Header buttons besides the app buttons, whose switch keeps its own key.
    /// An unchecked action moves into the More menu.
    public enum HeaderAction: String, Codable, CaseIterable, Sendable { case markRead, pin, settings }

    public static let defaultsKey = "expandedPanelOptions"
    public static let version = 1
    /// Larger saved or requested text is damaged.
    public static let byteLimit = 4096
    public static let pageSizes: ClosedRange<Int> = 3...6
    /// Named tasks in the spend bar before the rest join "Others".
    public static let spendTaskChoices = [2, 4]

    public var pageSize = 3
    public var rowStyle: RowStyle = .twoLine
    public var rowFields: Set<RowField> = Set(RowField.allCases)
    public var codexPeriods: Periods = .both
    public var claudePeriods: Periods = .both
    public var quotaArrange: Arrange = .pair
    /// Pace, reset and forecast beside a service that has a row to itself.
    public var quotaDetails = true
    /// The white tick that marks how much of each window's time remains.
    public var paceTick = true
    public var deepseekDial: DeepSeekDial = .budget
    /// The chip under DeepSeek's dial during peak-price hours.
    public var deepseekPeak = true
    public var spendTasks = 2
    /// Spend the account was charged with no task on this computer, hatched.
    public var spendElsewhere = true
    /// The week chart's dashed line: the daily budget, or the daily average.
    public var weekLine = true
    public var headerActions: Set<HeaderAction> = Set(HeaderAction.allCases)

    public init() {}

    public func periods(for provider: AgentProvider) -> Periods {
        switch provider {
        case .codex: codexPeriods
        case .claude: claudePeriods
        default: .both
        }
    }

    public mutating func setPeriods(_ value: Periods, for provider: AgentProvider) {
        if provider == .codex { codexPeriods = value } else if provider == .claude { claudePeriods = value }
    }

    /// Whether a row draws the field in the chosen style.
    public func shows(_ field: RowField) -> Bool {
        rowFields.contains(field) && (rowStyle == .twoLine || field.showsInOneLine)
    }

    /// The budget dial shows when chosen and a budget exists.
    public func showsBudgetDial(hasBudget: Bool) -> Bool { hasBudget && deepseekDial == .budget }

    private enum CodingKeys: String, CodingKey {
        case version, pageSize, rowStyle, rowFields, codexPeriods, claudePeriods, quotaArrange, quotaDetails, paceTick,
             deepseekDial, deepseekPeak, spendTasks, spendElsewhere, weekLine, headerActions
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        func field<T: Decodable>(_ key: CodingKeys, _ fallback: T) -> T {
            (try? values.decodeIfPresent(T.self, forKey: key)) ?? fallback
        }
        func set<T: RawRepresentable & Hashable>(_ key: CodingKeys, _ fallback: Set<T>) -> Set<T> where T.RawValue == String {
            guard let names = try? values.decodeIfPresent([String].self, forKey: key) else { return fallback }
            return Set(names.compactMap(T.init(rawValue:)))
        }
        let defaults = Self()
        let size = field(.pageSize, defaults.pageSize)
        pageSize = Self.pageSizes.contains(size) ? size : defaults.pageSize
        rowStyle = field(.rowStyle, defaults.rowStyle)
        rowFields = set(.rowFields, defaults.rowFields)
        codexPeriods = field(.codexPeriods, defaults.codexPeriods)
        claudePeriods = field(.claudePeriods, defaults.claudePeriods)
        quotaArrange = field(.quotaArrange, defaults.quotaArrange)
        quotaDetails = field(.quotaDetails, defaults.quotaDetails)
        paceTick = field(.paceTick, defaults.paceTick)
        deepseekDial = field(.deepseekDial, defaults.deepseekDial)
        deepseekPeak = field(.deepseekPeak, defaults.deepseekPeak)
        let tasks = field(.spendTasks, defaults.spendTasks)
        spendTasks = Self.spendTaskChoices.contains(tasks) ? tasks : defaults.spendTasks
        spendElsewhere = field(.spendElsewhere, defaults.spendElsewhere)
        weekLine = field(.weekLine, defaults.weekLine)
        headerActions = set(.headerActions, defaults.headerActions)
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(Self.version, forKey: .version)
        try values.encode(pageSize, forKey: .pageSize)
        try values.encode(rowStyle, forKey: .rowStyle)
        try values.encode(RowField.allCases.filter(rowFields.contains), forKey: .rowFields)
        try values.encode(codexPeriods, forKey: .codexPeriods)
        try values.encode(claudePeriods, forKey: .claudePeriods)
        try values.encode(quotaArrange, forKey: .quotaArrange)
        try values.encode(quotaDetails, forKey: .quotaDetails)
        try values.encode(paceTick, forKey: .paceTick)
        try values.encode(deepseekDial, forKey: .deepseekDial)
        try values.encode(deepseekPeak, forKey: .deepseekPeak)
        try values.encode(spendTasks, forKey: .spendTasks)
        try values.encode(spendElsewhere, forKey: .spendElsewhere)
        try values.encode(weekLine, forKey: .weekLine)
        try values.encode(HeaderAction.allCases.filter(headerActions.contains), forKey: .headerActions)
    }

    /// Text that is missing, damaged or oversized reads as the defaults.
    public static func decode(_ json: String?) -> Self {
        guard let json, json.utf8.count <= byteLimit, let data = json.data(using: .utf8),
              let value = try? JSONDecoder().decode(Self.self, from: data) else { return Self() }
        return value
    }

    /// The saved choices as sorted JSON, the form both hosts store and send.
    public var json: String {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return (try? encoder.encode(self)).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
    }

    /// Damaged or oversized data reads as the defaults, and nothing is written.
    public static func load(from defaults: UserDefaults = .standard) -> Self {
        guard let data = defaults.data(forKey: defaultsKey), data.count <= byteLimit,
              let value = try? JSONDecoder().decode(Self.self, from: data) else { return Self() }
        return value
    }

    public func save(to defaults: UserDefaults = .standard) {
        defaults.set(Data(json.utf8), forKey: Self.defaultsKey)
    }
}
