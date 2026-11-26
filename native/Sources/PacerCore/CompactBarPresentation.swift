import Foundation

/// Edits use CompactIslandLayout's migration, ordering and provider rules.
/// Platform views arrange the returned components and draw their live values.
public enum CompactBarPresentation {
    /// What the activity badge's core shows while one task runs.
    public enum SingleTask: String, Codable, CaseIterable, Sendable { case stage, count, percent }
    public enum Metric: String, Codable, CaseIterable, Sendable {
        case remaining, pace
        public var labelKey: String {
            switch self { case .remaining: "layout.quota_label"; case .pace: "quota.pace" }
        }
    }
    /// A gauge ring's module, stored by its ID. Any module that shows a
    /// balance can fill a ring; `automatic` lets the bar choose.
    public struct RingChoice: RawRepresentable, Hashable, Codable, Sendable {
        public let rawValue: String
        public init?(rawValue: String) {
            guard rawValue.isEmpty || rawValue == "none" ||
                  AgentProvider(rawValue: rawValue).flatMap(HarnessRegistry.descriptor(for:))?.balance != nil else { return nil }
            self.rawValue = rawValue
        }
        private init(stored: String) { rawValue = stored }
        public static let automatic = Self(stored: ""), none = Self(stored: "none")
        public init(provider: AgentProvider) {
            rawValue = HarnessRegistry.descriptor(for: provider)?.balance == nil ? "none" : provider.rawValue
        }
        public var provider: AgentProvider? { AgentProvider(rawValue: rawValue) }
        public static var allCases: [Self] { [.automatic, .none] + HarnessRegistry.ids(where: { $0.balance != nil }).map(Self.init(provider:)) }
    }
    /// Remaining quota at or below this many percent is low, as in the expanded panel.
    public static let lowQuota = 15.0
    public static func rateIsVisible(context: CompactBarContext, attached: Bool, strip: Bool, showsStatus: Bool, language: AppLanguage) -> Bool {
        !showsStatus || strip || !attached || language != .english || !context.attention
    }
    public struct Options: Codable, Equatable, Sendable {
        public var singleTask: SingleTask
        public var metric: Metric
        public var codexWindow: String
        public var antigravityWindow: String?
        public var claudeWindow: String
        public var rings: [RingChoice]
        public init(singleTask: SingleTask = .stage, metric: Metric = .remaining, codexWindow: String = "auto",
                    claudeWindow: String = "auto", antigravityWindow: String? = nil, rings: [RingChoice] = [.automatic, .automatic]) {
            self.antigravityWindow = antigravityWindow
            self.singleTask = singleTask; self.metric = metric; self.codexWindow = codexWindow; self.claudeWindow = claudeWindow; self.rings = rings
        }
        func window(for provider: AgentProvider) -> String {
            if provider == .antigravity { return antigravityWindow ?? "auto" }
            return provider == .codex ? codexWindow : claudeWindow
        }
        public var valid: Bool {
            rings.count == 2 &&
                [codexWindow, claudeWindow, antigravityWindow ?? "auto"].allSatisfy { $0.utf8.count <= 1024 && !$0.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) } }
        }
        private enum CodingKeys: String, CodingKey { case singleTask, metric, codexWindow, claudeWindow, antigravityWindow, rings }
        public init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            singleTask = try values.decode(SingleTask.self, forKey: .singleTask)
            metric = try values.decode(Metric.self, forKey: .metric)
            codexWindow = try values.decode(String.self, forKey: .codexWindow)
            claudeWindow = try values.decode(String.self, forKey: .claudeWindow)
            antigravityWindow = try values.decodeIfPresent(String.self, forKey: .antigravityWindow)
            // A ring saved by a version with another module draws nothing here
            // instead of invalidating the whole bar; a malformed value still does.
            rings = try values.decode([String].self, forKey: .rings).map { value in
                if let choice = RingChoice(rawValue: value) { return choice }
                guard value.range(of: #"^[a-z][a-z0-9-]{0,47}\z"#, options: .regularExpression) != nil else {
                    throw DecodingError.dataCorruptedError(forKey: .rings, in: values, debugDescription: "Malformed ring")
                }
                return .none
            }
        }
    }
    public struct Action: Codable, Equatable, Sendable {
        public let kind: String
        public let component: String?
        public let lane: String?
        public let before: String?
        public let offset: Int?
        public init(kind: String, component: String? = nil, lane: String? = nil, before: String? = nil, offset: Int? = nil) {
            self.kind = kind; self.component = component; self.lane = lane; self.before = before; self.offset = offset
        }
    }
    public struct Request: Codable, Equatable, Sendable {
        public var layout: String?
        public var warnings: [String]?
        public var language: String
        public var providers: [AgentProvider]
        public var options: Options
        public var action: Action?
        public var context: CompactBarContext?
        public var attached: Bool
        public var strip: Bool
        /// `CompactComponentOptions` as JSON. Unknown or missing choices fall
        /// back one by one, so only oversized text rejects the request.
        public var componentOptions: String?
        /// A `CompactBarSize` raw value; an unknown one draws the standard size.
        public var size: String?
        public init(layout: String? = nil, warnings: [String]? = nil,
                    language: String = L10n.language.rawValue, providers: [AgentProvider], options: Options = .init(),
                    action: Action? = nil, context: CompactBarContext? = nil, attached: Bool = false, strip: Bool = false,
                    componentOptions: String? = nil, size: String? = nil) {
            self.layout = layout; self.warnings = warnings; self.language = language; self.providers = providers; self.options = options
            self.action = action; self.context = context; self.attached = attached; self.strip = strip
            self.componentOptions = componentOptions; self.size = size
        }
    }
    public struct Entry: Codable, Equatable, Sendable {
        public let provider: AgentProvider
        public let text: String, stripText: String
        /// What `stripText` counts, drawn under it in the strip: `%`, `¥`, `k`.
        public let stripUnit: String?
        public let dimmed: Bool
        /// The percent behind the text, when it has one.
        public let value: Double?
        /// Remaining quota at or below `lowQuota` with the low color chosen.
        public let low: Bool?
        public init(provider: AgentProvider, text: String, stripText: String, stripUnit: String? = nil, dimmed: Bool,
                    value: Double? = nil, low: Bool? = nil) {
            self.provider = provider; self.text = text; self.stripText = stripText; self.stripUnit = stripUnit; self.dimmed = dimmed
            self.value = value; self.low = low
        }
    }
    public struct Ring: Codable, Equatable, Sendable {
        public let provider: AgentProvider
        public let remaining: Double?
        public let dimmed: Bool
        /// The share of the window's time still left, 0...1, where the pace
        /// tick sits; nil when the tick is hidden or the window is unknown.
        public let time: Double?
        public let low: Bool?
        /// Nothing left: the arc goes and the track turns red.
        public let exhausted: Bool?
        /// "5h" or "7d" when the rings split one service's two windows.
        public let window: String?
        public init(provider: AgentProvider, remaining: Double?, dimmed: Bool, time: Double? = nil, low: Bool? = nil,
                    exhausted: Bool? = nil, window: String? = nil) {
            self.provider = provider; self.remaining = remaining; self.dimmed = dimmed; self.time = time; self.low = low
            self.exhausted = exhausted; self.window = window
        }
    }
    public struct Component: Codable, Equatable, Sendable {
        public let id: String, label: String, shortLabel: String, detail: String, symbol: String, hideLabel: String
        public let available: Bool, shown: Bool, visible: Bool, stripEligible: Bool
        public let text: String?, stripText: String?, unit: String?, stripUnit: String?
        public let help: String, accessibility: String
        public let entries: [Entry]
        /// "attention" or "failed" for status text that needs the matching color.
        public let tone: String?
        /// The widest the text draws, in points, before its end fades.
        public let maxWidth: Double?

        public init(id: String, label: String, shortLabel: String, detail: String, symbol: String, hideLabel: String,
                    available: Bool, shown: Bool, visible: Bool, stripEligible: Bool,
                    text: String?, stripText: String?, unit: String?, stripUnit: String?, help: String, accessibility: String,
                    entries: [Entry], tone: String? = nil, maxWidth: Double? = nil) {
            self.id = id; self.label = label; self.shortLabel = shortLabel; self.detail = detail; self.symbol = symbol; self.hideLabel = hideLabel
            self.available = available; self.shown = shown; self.visible = visible; self.stripEligible = stripEligible
            self.text = text; self.stripText = stripText; self.unit = unit; self.stripUnit = stripUnit; self.help = help; self.accessibility = accessibility
            self.entries = entries; self.tone = tone; self.maxWidth = maxWidth
        }

        public static func hidden(_ component: CompactIslandLayout.Component) -> Self {
            .init(id: component.rawValue, label: component.label, shortLabel: component.shortLabel,
                detail: component.detail, symbol: component.symbol,
                hideLabel: L10n.text("layout.hide_component", component.label),
                available: false, shown: false, visible: false, stripEligible: component.showsInStrip,
                text: nil, stripText: nil, unit: nil, stripUnit: nil,
                help: "", accessibility: "", entries: [])
        }
    }
    public struct Group: Codable, Equatable, Sendable { public let id: String, label: String; public let components: [String] }
    public struct Lanes: Codable, Equatable, Sendable { public let leading: [String], trailing: [String] }
    public struct Window: Codable, Equatable, Sendable {
        public let provider: AgentProvider
        public let label: String, selection: String
        public let weeklyOnly: Bool
    }
    public struct Output: Codable, Equatable, Sendable {
        public let version: Int
        public let layoutJSON: String
        public let warnings: [String]
        public let editorLeading: [String], editorTrailing: [String], leading: [String], trailing: [String]
        public let components: [Component], groups: [Group], windows: [Window]
        public let rings: [Ring]
        public let ringChoices: [String]
        public let gaugeClock: Bool, singleTaskCount: Bool
        /// Every component's choices after per-field fallback.
        public let componentOptions: CompactComponentOptions?
        /// Points for the requested bar size.
        public let metrics: CompactBarMetrics?
        /// The core shows the only task's reported percent instead of its stage.
        public let singleTaskPercent: Bool?
        /// Strip order and visibility, using the same component values and their strip text.
        public let stripLanes: Lanes?

        /// Invalid native input hides the bar's components until a valid projection arrives.
        public static let empty: Self = {
            let layout = CompactIslandLayout(warnings: [])
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
            let layoutJSON = (try? encoder.encode(layout)).map { String(decoding: $0, as: UTF8.self) }
                ?? #"{"leading":[],"trailing":[],"version":\#(layout.version),"warnings":[]}"#
            return Self(version: 1, layoutJSON: layoutJSON, warnings: [],
                editorLeading: [], editorTrailing: [], leading: [], trailing: [], components: [], groups: [], windows: [],
                rings: [], ringChoices: ["none", "none"], gaugeClock: false, singleTaskCount: false,
                componentOptions: CompactComponentOptions(), metrics: .standard, singleTaskPercent: false, stripLanes: nil)
        }()

        public func component(_ component: CompactIslandLayout.Component) -> Component {
            components.first { $0.id == component.rawValue } ?? .hidden(component)
        }
    }

    public static func project(_ request: Request, layout suppliedLayout: CompactIslandLayout? = nil,
                               components suppliedComponents: CompactComponentOptions? = nil) -> Output? {
        guard let language = AppLanguage(rawValue: request.language), request.providers.count <= HarnessRegistry.descriptors.count,
              Set(request.providers).count == request.providers.count, request.options.valid,
              request.warnings.map({ $0.count <= CompactIslandLayout.Warning.allCases.count && $0.allSatisfy { CompactIslandLayout.Warning(rawValue: $0) != nil } }) ?? true,
              request.layout.map({ $0.utf8.count <= 8192 }) ?? true,
              request.componentOptions.map({ $0.utf8.count <= CompactComponentOptions.byteLimit }) ?? true,
              request.size.map({ $0.utf8.count <= 64 }) ?? true else { return nil }
        let choices = suppliedComponents ?? CompactComponentOptions.decode(request.componentOptions)
        let metrics = (request.size.flatMap(CompactBarSize.init(rawValue:)) ?? .standard).metrics
        let ordered = HarnessRegistry.descriptors.filter { $0.balance != nil && request.providers.contains($0.id) }.map(\.id)
        let providers = Set(ordered)
        var layout = suppliedLayout ?? (request.layout.flatMap { $0.data(using: .utf8) }.flatMap { try? JSONDecoder().decode(CompactIslandLayout.self, from: $0) }?.normalized ?? .standard)
        if let warnings = request.warnings { layout.warnings = Set(warnings.compactMap(CompactIslandLayout.Warning.init(rawValue:))) }
        if let action = request.action {
            if action.kind == "restore" { layout = .standard }
            else if ["warning", "warningOff"].contains(action.kind), let raw = action.component, let warning = CompactIslandLayout.Warning(rawValue: raw) {
                if action.kind == "warningOff" { layout.warnings.remove(warning) }
                else if !layout.components.contains(.warnings) {
                    layout.warnings = [warning]; layout.move(.warnings, to: .trailing, before: layout.trailing.first)
                } else { layout.warnings.insert(warning) }
            } else {
                guard let raw = action.component, let component = CompactIslandLayout.Component(rawValue: raw) else { return nil }
                switch action.kind {
                case "hide": layout.hide(component)
                case "show": layout.move(component, to: component.preferredLane)
                case "move":
                    guard let value = action.lane, let lane = CompactIslandLayout.Lane(rawValue: value),
                          action.before == nil || action.before.flatMap(CompactIslandLayout.Component.init(rawValue:)) != nil else { return nil }
                    layout.move(component, to: lane, before: action.before.flatMap(CompactIslandLayout.Component.init(rawValue:)))
                case "shift":
                    guard let offset = action.offset, (-10...10).contains(offset) else { return nil }
                    layout.shift(component, by: offset, providers: providers)
                default: return nil
                }
            }
        }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        guard let bytes = try? encoder.encode(layout), let canonical = String(data: bytes, encoding: .utf8) else { return nil }
        let context = request.context
        guard context.map({ $0.version == 1 && $0.sources.count <= HarnessRegistry.descriptors.count &&
            ($0.credits?.count ?? 0) <= HarnessRegistry.descriptors.count && $0.now.timeIntervalSince1970.isFinite && $0.warnings.count <= 16
            && ($0.firstOutputs?.count ?? 0) <= CompactFirstOutputHistory.limit }) ?? true
        else { return nil }
        let date = context?.now ?? Date(timeIntervalSince1970: 0)
        func source(_ provider: AgentProvider) -> CompactBarContext.Source? { context?.sources.first { $0.provider == provider } }
        func selection(_ provider: AgentProvider) -> QuotaWindowSelection {
            .init(saved: request.options.window(for: provider), snapshot: source(provider)?.snapshot)
        }
        func selected(_ provider: AgentProvider) -> QuotaWindow? {
            QuotaDashboardPresentation.selectedWindow(provider: provider, snapshot: source(provider)?.snapshot,
                selection: request.options.window(for: provider))
        }
        let wallet = context?.wallet
        func windowed(_ provider: AgentProvider) -> Bool { HarnessRegistry.descriptor(for: provider)?.hasQuotaWindows == true }
        func credits(_ provider: AgentProvider) -> CompactBarContext.Credits? {
            HarnessRegistry.descriptor(for: provider)?.reportsAccountCredits == true
                ? context?.credits?.first { $0.provider == provider } ?? .init(provider: provider, credits: nil, stale: false, now: date) : nil
        }
        let automatic = request.options.rings.allSatisfy { $0 == .automatic }
        let ringChoices: [RingChoice]
        if automatic {
            // Quota windows first, then account credits that have a reading.
            let candidates = ordered.filter(windowed) + ordered.filter { credits($0)?.percent != nil }
            var values = Array(candidates.prefix(2)).map(RingChoice.init(provider:))
            // Settings names an enabled wallet even before it has a budget;
            // the drawing below independently excludes undrawable rings.
            if values.count == 1, providers.contains(.deepseek) { values.append(.init(provider: .deepseek)) }
            ringChoices = values + Array(repeating: .none, count: 2 - values.count)
        } else { ringChoices = request.options.rings.map { $0 == .automatic ? .none : $0 } }
        var ringProviders: [AgentProvider] = []
        for choice in ringChoices {
            guard let provider = choice.provider, providers.contains(provider),
                  provider != .deepseek || wallet?.hasBudget == true, !ringProviders.contains(provider) else { continue }
            ringProviders.append(provider)
        }
        func ring(_ provider: AgentProvider, window: QuotaWindow?, tag: String? = nil) -> Ring {
            let remaining: Double?, dimmed: Bool
            if provider == .deepseek { remaining = wallet?.budgetPercent; dimmed = wallet?.dimmed == true }
            else if let account = credits(provider) { remaining = account.percent; dimmed = account.dimmed }
            else {
                remaining = source(provider)?.failed == true ? nil : window?.remainingPercent
                dimmed = source(provider)?.snapshot?.isStale(at: date) == true || window?.resetsAt.map { $0 <= date } == true
            }
            let exhausted = remaining.map { $0 < 0.5 } == true
            return .init(provider: provider, remaining: remaining, dimmed: dimmed,
                time: choices.paceTick && !dimmed ? window?.remainingTimePercent(at: date).map { $0 / 100 } : nil,
                low: !exhausted && choices.lowColor && remaining.map { $0 <= lowQuota } == true ? true : nil,
                exhausted: exhausted ? true : nil, window: tag)
        }
        var rings: [Ring] = ringProviders.map { ring($0, window: $0 == .deepseek ? wallet?.budgetWindow : selected($0)) }
        // One service's two windows share the gauge when the split layout has both.
        if choices.ringLayout == .split, let provider = ringProviders.first(where: windowed),
           let windows = QuotaDashboardPresentation.bucket(provider: provider, snapshot: source(provider)?.snapshot)?.windows,
           let five = windows.first(where: { $0.durationMinutes == 300 }), let week = windows.first(where: { $0.durationMinutes == 10080 }) {
            rings = [ring(provider, window: five, tag: QuotaWindowSelection.fiveHour.rawValue),
                     ring(provider, window: week, tag: QuotaWindowSelection.weekly.rawValue)]
        }
        let clock = rings.isEmpty && providers.contains(.deepseek) && !layout.components.contains(.priceClock)
        let usesBudget = layout.components.contains(.quotaGauge) && ringProviders.contains(.deepseek)
        func value(_ provider: AgentProvider) -> Double? {
            quotaValue(provider: provider, snapshot: source(provider)?.snapshot, failed: source(provider)?.failed == true,
                metric: request.options.metric, selection: request.options.window(for: provider), now: date)
        }
        let known = ordered.filter {
            if $0 == .deepseek { return wallet?.hasBalance == true || usesBudget }
            if let account = credits($0) { return account.text != "—" }
            return value($0) != nil
        }
        let alternating = known.isEmpty ? Array(ordered.prefix(1)) : known
        func percent(_ value: Double?) -> String { value.map { String(Int($0.rounded())) } ?? "—" }
        let metric = request.options.metric
        func entry(_ provider: AgentProvider) -> Entry {
            if provider == .deepseek {
                return .init(provider: provider, text: usesBudget ? wallet?.budget ?? "¥—" : wallet?.balance ?? "¥—",
                    stripText: (usesBudget ? wallet?.stripBudget : wallet?.stripBalance) ?? "—",
                    stripUnit: (usesBudget ? wallet?.stripBudgetUnit : wallet?.stripBalanceUnit) ?? "¥", dimmed: wallet?.dimmed == true,
                    value: usesBudget ? wallet?.budgetPercent : nil,
                    low: usesBudget && choices.lowColor && wallet?.budgetPercent.map { $0 <= lowQuota } == true ? true : nil)
            }
            if let account = credits(provider) {
                return .init(provider: provider, text: account.text, stripText: account.stripText, stripUnit: account.stripUnit,
                    dimmed: account.dimmed,
                    value: account.percent, low: choices.lowColor && account.low == true ? true : nil)
            }
            let raw = value(provider), number = percent(raw)
            return .init(provider: provider, text: number == "—" ? number : number + "%",
                stripText: number, stripUnit: "%", dimmed: provider == .antigravity &&
                    (source(provider)?.failed == true || QuotaDashboardPresentation.isStale(snapshot: source(provider)?.snapshot, window: selected(provider), now: date)), value: raw,
                low: metric == .remaining && choices.lowColor && raw.map { $0 <= lowQuota } == true ? true : nil)
        }
        var entries = alternating.map(entry)
        if choices.quotaMultiple == .lowest, entries.count > 1 {
            let lowest = entries.enumerated().filter { $0.element.value != nil }
                .min { ($0.element.value ?? 0, $0.offset) < ($1.element.value ?? 0, $1.offset) }?.element
            entries = [lowest ?? entries[0]]
        }
        let times: [Entry] = ordered.filter(windowed).map { provider in
            let window = selected(provider)
            if choices.timeStyle == .countdown {
                let seconds = window?.remainingSeconds(at: date)
                let text = seconds.map { $0 <= 0 ? L10n.text("dashboard.countdown_waiting", language: language) : CompactDuration.compact($0, language: language) } ?? "—"
                return .init(provider: provider, text: text, stripText: seconds.map { CompactDuration.short($0) } ?? "—", dimmed: false,
                    value: window?.remainingTimePercent(at: date))
            }
            let left = window?.elapsedTimePercent(at: date).map { 100 - $0 }, number = percent(left)
            return .init(provider: provider, text: number == "—" ? number : number + "%", stripText: number, dimmed: false, value: left)
        }
        func quotaName(_ provider: AgentProvider) -> String {
            guard provider == .antigravity, let id = source(provider)?.snapshot?.buckets.first?.id,
                  let group = AntigravityQuotaGroup(rawValue: id) else { return provider.displayName }
            return provider.displayName + " · " + L10n.text("antigravity.quota." + group.rawValue, language: language)
        }
        let quotaHelp = ordered.map(entry).map { entry in L10n.text("provider.compact_quota", quotaName(entry.provider), entry.text, language: language) }.joined(separator: " · ")
        let gaugeHelp = rings.map { ring in
            L10n.text("provider.compact_quota", ring.window.map { quotaName(ring.provider) + " " + $0 } ?? quotaName(ring.provider),
                ring.provider == .deepseek ? wallet?.budget ?? "—" : credits(ring.provider)?.text ?? ring.remaining.map { "\(Int(min(100, max(0, $0)).rounded()))%" } ?? "—", language: language)
        }.joined(separator: " · ")
        let timeHelp = times.map { entry in L10n.text("provider.compact_time", quotaName(entry.provider), entry.text, language: language) }.joined(separator: " · ")
        let clockSummary = L10n.text("deepseek.clock_accessibility", L10n.text(wallet?.peakNow == true ? "deepseek.now.peak" : "deepseek.now.offpeak", language: language),
            DeepSeekDialPresentation.amount(wallet?.todayTotal ?? 0), language: language)
        let showsStatus = layout.components.contains(.status)
        let stripRateVisible = context.map { rateIsVisible(context: $0, attached: request.attached, strip: true,
            showsStatus: showsStatus, language: language) } ?? false
        let componentValues = CompactIslandLayout.Component.allCases.map { component -> Component in
            var text: String?, stripText: String?, unit: String?, stripUnit: String?
            var help = "", accessibility = "", visible = component.isAvailable(for: providers), values: [Entry] = []
            var tone: String?, maxWidth: Double?
            switch component {
            case .activity: help = context?.activitySummary(language: language) ?? L10n.text("activity.idle", language: language)
            case .status:
                help = context?.statusText(choices.statusShow, language: language) ?? L10n.text("activity.idle", language: language); text = help
                tone = context?.statusTone(choices.statusShow); maxWidth = (choices.statusWidth.points * metrics.scale).rounded()
            case .tps:
                let compact = request.attached || request.strip, average = choices.rateMeasure == .average
                let measured = max(1, context?.measuredTasks ?? 1)
                let shown = context?.rate.map { average ? $0 / Double(measured) : $0 }
                func format(_ rate: Double, compact: Bool) -> String {
                    if compact && rate >= 999_950 { return String(format: "%.1fM", rate / 1_000_000) }
                    if compact && rate >= 999.5 { return String(format: "%.1fk", rate / 1000) }
                    return String(format: "%03.0f", rate)
                }
                text = shown.map { format($0, compact: compact) } ?? "000"
                let figure = CompactStripFigure.rate(shown)
                unit = "t/s"; stripText = figure.number; stripUnit = figure.unit
                visible = context.map { rateIsVisible(context: $0, attached: request.attached, strip: request.strip,
                    showsStatus: showsStatus, language: language) } ?? false
                accessibility = (shown.map { String(format: "%.0f", $0) } ?? "0") + " t/s"
                if let shown {
                    help = average
                        ? L10n.text("performance.average_help", shown, measured, language: language)
                        : L10n.text(context?.rateFresh == true ? "performance.total_help" : "performance.partial_total_help", shown, language: language)
                } else {
                    help = L10n.text(context?.running == true ? "performance.awaiting_usage" : "activity.idle", language: language)
                }
            case .firstOutput:
                let median = choices.firstOutput == .median ? context?.firstOutputs.flatMap(CompactFirstOutputHistory.median) : nil
                let seconds = median ?? context?.firstOutput
                text = seconds.map { String(format: "%.2f", $0) } ?? "—"; unit = "s"
                stripText = seconds.map { String(format: $0 < 10 ? "%.1f" : "%.0f", $0) } ?? "—"; stripUnit = "s"
                help = L10n.text(median == nil ? "layout.latest_ttft_help" : "layout.median_ttft_help", language: language)
            case .warnings: visible = context?.warnings.isEmpty == false; help = CompactWarningPresentation.summary(context?.warnings ?? [])
            // One unit shared by every value sits under them; mixed units take turns with their values.
            case .quota: values = entries; stripUnit = Set(entries.map(\.stripUnit)).count == 1 ? entries.first?.stripUnit : nil; help = quotaHelp + "\n" + L10n.text("layout.metric_help", language: language)
            case .quotaGauge: visible = !rings.isEmpty || clock; help = clock ? "" : gaugeHelp + "\n" + L10n.text("layout.gauge_help", language: language)
            case .priceClock: visible = visible && (choices.clockShow == .always || wallet?.peakNow == true)
            case .quotaLabel: text = L10n.text(request.options.metric.labelKey, language: language); help = quotaHelp + "\n" + L10n.text("layout.metric_help", language: language)
            case .timeRemaining:
                values = times; stripUnit = choices.timeStyle == .countdown ? nil : "%"
                help = timeHelp + "\n" + L10n.text(choices.timeStyle == .countdown ? "layout.countdown_help" : "layout.time_remaining_help", language: language)
            }
            switch component {
            case .firstOutput: accessibility = L10n.text("performance.first_output", text.map { $0 == "—" ? $0 : $0 + " s" } ?? "—", language: language)
            case .quota: accessibility = quotaHelp
            case .quotaGauge: accessibility = clock ? clockSummary : gaugeHelp
            case .quotaLabel: accessibility = text ?? ""
            case .timeRemaining: accessibility = timeHelp
            case .tps: break
            case .priceClock: accessibility = clockSummary
            default: accessibility = help
            }
            return .init(id: component.rawValue, label: L10n.text("layout.component." + component.rawValue, language: language),
                shortLabel: L10n.text("layout.short." + component.rawValue, language: language), detail: L10n.text("layout.detail." + component.rawValue, language: language), symbol: component.symbol,
                hideLabel: L10n.text("layout.hide_component", L10n.text("layout.component." + component.rawValue, language: language), language: language),
                available: component.isAvailable(for: providers), shown: layout.components.contains(component), visible: visible, stripEligible: component.showsInStrip,
                text: text, stripText: stripText,
                unit: unit, stripUnit: stripUnit, help: help, accessibility: accessibility, entries: values,
                tone: tone, maxWidth: maxWidth)
        }
        func runtime(_ lane: CompactIslandLayout.Lane, strip: Bool) -> [String] {
            layout[lane].filter { component in
                guard let value = componentValues.first(where: { $0.id == component.rawValue }) else { return false }
                if !strip { return value.visible }
                return value.stripEligible && (component == .tps ? stripRateVisible : value.visible)
            }.map(\.rawValue)
        }
        let stripLanes = Lanes(leading: runtime(.leading, strip: true), trailing: runtime(.trailing, strip: true))
        let windows: [Window] = ordered.filter(windowed).map { provider in
            let snapshot = source(provider)?.snapshot
            let own = snapshot.flatMap { $0.buckets.first { $0.id == provider.rawValue } ?? $0.buckets.first }
            let weeklyOnly = own?.windows.contains(where: { $0.durationMinutes == 10080 }) == true && own?.windows.contains(where: { $0.durationMinutes == 300 }) == false
            return .init(provider: provider, label: L10n.text("provider.window_selection", provider.displayName, language: language),
                selection: weeklyOnly ? "7d" : selection(provider).rawValue, weeklyOnly: weeklyOnly)
        }
        return .init(version: 1, layoutJSON: canonical, warnings: CompactIslandLayout.Warning.allCases.filter(layout.warnings.contains).map(\.rawValue),
            editorLeading: layout.visibleComponents(in: .leading, providers: providers).map(\.rawValue), editorTrailing: layout.visibleComponents(in: .trailing, providers: providers).map(\.rawValue),
            leading: request.strip ? stripLanes.leading : runtime(.leading, strip: false),
            trailing: request.strip ? stripLanes.trailing : runtime(.trailing, strip: false), components: componentValues,
            groups: CompactIslandLayout.Group.allCases.map { .init(id: $0.rawValue, label: L10n.text("layout.group." + $0.rawValue, language: language), components: $0.components.map(\.rawValue)) },
            windows: windows, rings: rings, ringChoices: ringChoices.map(\.rawValue), gaugeClock: clock, singleTaskCount: request.options.singleTask == .count,
            componentOptions: choices, metrics: metrics,
            singleTaskPercent: request.options.singleTask == .percent, stripLanes: stripLanes)
    }
    public static func quotaValue(provider: AgentProvider, snapshot: QuotaSnapshot?, failed: Bool,
                                  metric: Metric, selection: String?, now: Date) -> Double? {
        let window = QuotaDashboardPresentation.selectedWindow(provider: provider, snapshot: snapshot, selection: selection)
        switch metric {
        case .pace:
            guard !failed, snapshot?.isStale(at: now) == false else { return nil }
            return window?.pacePercent(at: now)
        case .remaining: return window?.remainingPercent
        }
    }
    public static func timeRemainingNumber(provider: AgentProvider, snapshot: QuotaSnapshot?, selection: String?, now: Date) -> String? {
        QuotaDashboardPresentation.selectedWindow(provider: provider, snapshot: snapshot, selection: selection)?
            .elapsedTimePercent(at: now).map { String(Int((100 - $0).rounded())) }
    }
    public static func project(_ bytes: Data) -> Data? {
        guard bytes.count <= 262144, let request = try? JSONDecoder().decode(Request.self, from: bytes), let value = project(request),
              let output = try? JSONEncoder().encode(value), output.count <= 131072 else { return nil }
        return output
    }
}
