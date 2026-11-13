import Foundation

/// How the expanded panel's blocks become sections, shared by both hosts.
/// Rules: the first section carries the panel's actions in its header;
/// adjacent quota blocks share one section when paired; DeepSeek's spend and
/// week continue a DeepSeek section without a hairline; a lone DeepSeek dial
/// showing the day draws today's spend in its own column when the spend
/// block follows it, as the panel did before blocks.
public enum ExpandedPanelPresentation {
    public struct Section: Codable, Equatable, Sendable, Identifiable {
        public enum Kind: String, Codable, Sendable { case tasks, quota, deepseekSpend, deepseekWeek }
        public let kind: Kind
        /// The quota section's services in layout order; DeepSeek for its own blocks.
        public let providers: [AgentProvider]
        /// The panel's buttons sit in this section's header.
        public internal(set) var actions: Bool
        /// Continues the section above with a gap instead of a hairline.
        public let joined: Bool
        /// A lone DeepSeek day dial draws today's spend in its column.
        public internal(set) var spendBeside: Bool
        public var id: String { ([kind.rawValue] + providers.map(\.rawValue)).joined(separator: ":") }
        /// Spend and week draw their own title unless they carry the actions.
        public var showsHeader: Bool { kind == .tasks || kind == .quota || actions }

        public init(kind: Kind, providers: [AgentProvider] = [], actions: Bool = false, joined: Bool = false, spendBeside: Bool = false) {
            self.kind = kind; self.providers = providers; self.actions = actions; self.joined = joined; self.spendBeside = spendBeside
        }
    }

    public static func sections(layout: ExpandedPanelLayout, providers: Set<AgentProvider>, options: ExpandedPanelOptions,
                                budgetDial: Bool) -> [Section] {
        var visible = layout.visibleBlocks(providers: providers)
        // A panel always keeps somewhere for its actions.
        if visible.isEmpty { visible = [.tasks] }
        var result: [Section] = []
        var index = 0
        while index < visible.count {
            let block = visible[index]; index += 1
            switch block {
            case .tasks:
                result.append(Section(kind: .tasks))
            case .codex, .claude, .deepseek, .workbuddy:
                var group = [block.provider ?? .codex]
                if options.quotaArrange == .pair {
                    while index < visible.count, visible[index].isQuota, let provider = visible[index].provider {
                        group.append(provider); index += 1
                    }
                }
                result.append(Section(kind: .quota, providers: group))
            case .deepseekSpend, .deepseekWeek:
                let previous = result.last
                if block == .deepseekSpend, !budgetDial, let previous, previous.kind == .quota,
                   previous.providers == [.deepseek], !previous.spendBeside {
                    result[result.count - 1].spendBeside = true
                    continue
                }
                let joined = previous.map {
                    $0.kind == .quota ? $0.providers.contains(.deepseek) : $0.kind == .deepseekSpend || $0.kind == .deepseekWeek
                } ?? false
                result.append(Section(kind: block == .deepseekSpend ? .deepseekSpend : .deepseekWeek, providers: [.deepseek], joined: joined))
            }
        }
        if !result.isEmpty { result[0].actions = true }
        return result
    }

    /// A quota section's title and the service it names when it holds one.
    public struct Header: Codable, Equatable, Sendable {
        public let title: String
        public let detail: String?
        public let provider: AgentProvider?
    }

    public static func header(_ section: Section, budgetDial: Bool) -> Header {
        switch section.kind {
        case .tasks: return Header(title: L10n.text("layout.group.tasks"), detail: nil, provider: nil)
        case .deepseekSpend: return Header(title: L10n.text("deepseek.where"), detail: nil, provider: nil)
        case .deepseekWeek: return Header(title: L10n.text("deepseek.week_title"), detail: nil, provider: nil)
        case .quota:
            let single = section.providers.count == 1 ? section.providers.first : nil
            let hasBalance = section.providers.contains { provider in
                provider == .deepseek || HarnessRegistry.descriptor(for: provider)?.reportsAccountCredits == true
            }
            let key = single == .deepseek ? (budgetDial ? "layout.group.budget" : "layout.group.balance")
                : hasBalance ? "layout.group.quota_balance" : "layout.group.quota"
            return Header(title: L10n.text(key), detail: single?.displayName, provider: single)
        }
    }

    /// The window one service's ring draws, and whether the 5-hour arc joins it.
    public struct Gauge: Codable, Equatable, Sendable {
        public let provider: AgentProvider
        public let period: QuotaDashboardPresentation.Period
        public let split: Bool
        public init(provider: AgentProvider, period: QuotaDashboardPresentation.Period, split: Bool) {
            self.provider = provider; self.period = period; self.split = split
        }
    }

    /// Both windows split the ring when the account reports 5 hours. Five
    /// hours alone falls back to the week for an account without that window.
    public static func gauge(provider: AgentProvider, snapshot: QuotaSnapshot?, periods: ExpandedPanelOptions.Periods) -> Gauge {
        let fiveHour = QuotaDashboardPresentation.window(provider: provider, snapshot: snapshot, period: .fiveHour) != nil
        let weekly = QuotaDashboardPresentation.window(provider: provider, snapshot: snapshot, period: .weekly) != nil
        switch periods {
        case .both: return Gauge(provider: provider, period: .weekly, split: fiveHour)
        case .weekly: return Gauge(provider: provider, period: .weekly, split: false)
        case .fiveHour: return Gauge(provider: provider, period: fiveHour || !weekly ? .fiveHour : .weekly, split: false)
        }
    }

    /// The parts of today's spend bar with the panel's choices applied.
    public static func distribution(_ wallet: DeepSeekWallet, options: ExpandedPanelOptions, hideProjects: Bool = false,
                                    wording: DeepSeekSoloPresentation.Wording = .init(),
                                    taskTitle: (String) -> String = { _ in L10n.text("deepseek.task_untitled") }) -> DeepSeekSoloPresentation.Distribution? {
        DeepSeekSoloPresentation.distribution(wallet, hideProjects: hideProjects, wording: wording, taskTitle: taskTitle,
            tasks: options.spendTasks, elsewhere: options.spendElsewhere)
    }

    // MARK: - Settings page

    /// One edit from the settings page. `toggle` adds or removes `block`,
    /// `shift` moves it by `offset` among the shown blocks, `move` puts it
    /// before `before` (or last), and `restore` returns to the automatic layout.
    public struct Action: Codable, Equatable, Sendable {
        public let kind: String
        public let block: String?
        public let before: String?
        public let offset: Int?
        public init(kind: String, block: String? = nil, before: String? = nil, offset: Int? = nil) {
            self.kind = kind; self.block = block; self.before = before; self.offset = offset
        }
    }

    public struct Request: Codable, Equatable, Sendable {
        /// The saved `ExpandedPanelLayout` JSON; nil or damaged text is the automatic layout.
        public var layout: String?
        public var options: String?
        public var providers: [AgentProvider]
        /// DeepSeek's former Content choice was Detailed (the default).
        public var deepseekDetailed: Bool
        /// A DeepSeek budget is set, so the budget dial can show.
        public var hasBudget: Bool
        public var language: String
        public var action: Action?
        public init(layout: String? = nil, options: String? = nil, providers: [AgentProvider], deepseekDetailed: Bool = true,
                    hasBudget: Bool = false, language: String = L10n.language.rawValue, action: Action? = nil) {
            self.layout = layout; self.options = options; self.providers = providers; self.deepseekDetailed = deepseekDetailed
            self.hasBudget = hasBudget; self.language = language; self.action = action
        }
    }

    public struct Block: Codable, Equatable, Sendable {
        public let id: String, label: String, detail: String, symbol: String, group: String
        /// Its service is enabled.
        public let available: Bool
        /// It is in the layout, shown or kept for when its service returns.
        public let placed: Bool
        /// Removing it would leave the panel empty.
        public let locked: Bool
    }

    public struct Group: Codable, Equatable, Sendable { public let id: String, label: String; public let blocks: [String] }

    public struct Output: Codable, Equatable, Sendable {
        public let version: Int
        /// The layout to save after the action; nil means the automatic layout (nothing saved).
        public let layoutJSON: String?
        /// Every placed block in order, including those of disabled services.
        public let blocks: [String]
        /// The blocks the panel shows now, in order.
        public let visible: [String]
        public let catalog: [Block]
        public let groups: [Group]
        public let sections: [Section]
        public let options: ExpandedPanelOptions
    }

    /// Labels follow the request's language, as the collapsed bar's projection does.
    public static func project(_ request: Request) -> Output? {
        guard let language = AppLanguage(rawValue: request.language), request.providers.count <= HarnessRegistry.descriptors.count,
              Set(request.providers).count == request.providers.count,
              request.layout.map({ $0.utf8.count <= ExpandedPanelLayout.byteLimit }) ?? true,
              request.options.map({ $0.utf8.count <= ExpandedPanelOptions.byteLimit }) ?? true else { return nil }
        let providers = Set(request.providers)
        let options = ExpandedPanelOptions.decode(request.options)
        let saved = ExpandedPanelLayout.decode(request.layout)
        var layout = ExpandedPanelLayout.resolved(saved: saved, providers: providers, deepseekDetailed: request.deepseekDetailed)
        var persisted = saved
        if let action = request.action {
            if action.kind == "restore" {
                persisted = nil
                layout = .automatic(providers: providers, deepseekDetailed: request.deepseekDetailed)
            } else {
                guard let raw = action.block, let block = ExpandedPanelLayout.Block(rawValue: raw) else { return nil }
                switch action.kind {
                case "toggle": layout.toggle(block, providers: providers)
                case "shift":
                    guard let offset = action.offset, (-10...10).contains(offset) else { return nil }
                    layout.shift(block, by: offset, providers: providers)
                case "move":
                    let before = action.before.flatMap(ExpandedPanelLayout.Block.init(rawValue:))
                    guard action.before == nil || before != nil else { return nil }
                    layout.move(block, before: before)
                default: return nil
                }
                persisted = layout
            }
        }
        let budgetDial = options.showsBudgetDial(hasBudget: request.hasBudget)
        let catalog = ExpandedPanelLayout.Block.allCases.map { block in
            Block(id: block.rawValue, label: block.label(in: language), detail: block.detail(in: language), symbol: block.symbol, group: block.group.rawValue,
                available: block.isAvailable(for: providers), placed: layout.blocks.contains(block),
                locked: layout.isLastVisible(block, providers: providers))
        }
        return Output(version: 1, layoutJSON: persisted?.json, blocks: layout.blocks.map(\.rawValue),
            visible: layout.visibleBlocks(providers: providers).map(\.rawValue), catalog: catalog,
            groups: ExpandedPanelLayout.Group.allCases.map { Group(id: $0.rawValue, label: $0.label(in: language), blocks: $0.blocks.map(\.rawValue)) },
            sections: sections(layout: layout, providers: providers, options: options, budgetDial: budgetDial), options: options)
    }
}
