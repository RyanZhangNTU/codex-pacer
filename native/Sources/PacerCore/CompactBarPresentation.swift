import Foundation

/// Edits use CompactIslandLayout's migration, ordering and provider rules.
/// Platform views arrange the returned components and draw their live values.
public enum CompactBarPresentation {
    public static let dimDuration = 0.2
    public static let expandedOpacity = 0.3
    public static func dimsWhenExpanded(_ component: CompactIslandLayout.Component) -> Bool {
        [.quota, .quotaGauge, .quotaLabel, .timeRemaining, .priceClock].contains(component)
    }
    public struct Options: Codable, Equatable, Sendable {
        public var singleTask: String
        public var metric: String
        public var codexWindow: String
        public var claudeWindow: String
        public var rings: [String]
        public init(singleTask: String = "stage", metric: String = "remaining", codexWindow: String = "auto",
                    claudeWindow: String = "auto", rings: [String] = ["", ""]) {
            self.singleTask = singleTask; self.metric = metric; self.codexWindow = codexWindow; self.claudeWindow = claudeWindow; self.rings = rings
        }
        public var valid: Bool {
            ["stage", "count"].contains(singleTask) && ["remaining", "pace"].contains(metric) && rings.count == 2 &&
                rings.allSatisfy { ["", "none", "codex", "claude", "deepseek"].contains($0) } &&
                [codexWindow, claudeWindow].allSatisfy { $0.utf8.count <= 1024 && !$0.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) } }
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
        public init(layout: String? = nil, warnings: [String]? = nil,
                    language: String = L10n.language.rawValue, providers: [AgentProvider], options: Options = .init(),
                    action: Action? = nil, context: CompactBarContext? = nil, attached: Bool = false, strip: Bool = false) {
            self.layout = layout; self.warnings = warnings; self.language = language; self.providers = providers; self.options = options
            self.action = action; self.context = context; self.attached = attached; self.strip = strip
        }
    }
    public struct Entry: Codable, Equatable, Sendable {
        public let provider: String, text: String, stripText: String
        public let dimmed: Bool
    }
    public struct Ring: Codable, Equatable, Sendable {
        public let provider: String
        public let remaining: Double?
        public let dimmed: Bool
    }
    public struct Component: Codable, Equatable, Sendable {
        public let id: String, label: String, shortLabel: String, detail: String, symbol: String, hideLabel: String
        public let available: Bool, shown: Bool, visible: Bool, stripEligible: Bool, dimsExpanded: Bool
        public let text: String?, stripText: String?, unit: String?, stripUnit: String?
        public let help: String, accessibility: String
        public let entries: [Entry]
    }
    public struct Group: Codable, Equatable, Sendable { public let id: String, label: String; public let components: [String] }
    public struct Window: Codable, Equatable, Sendable { public let provider: String, label: String, selection: String; public let weeklyOnly: Bool }
    public struct Output: Codable, Equatable, Sendable {
        public let version: Int
        public let layoutJSON: String
        public let warnings: [String]
        public let editorLeading: [String], editorTrailing: [String], leading: [String], trailing: [String]
        public let components: [Component], groups: [Group], windows: [Window]
        public let rings: [Ring]
        public let ringChoices: [String]
        public let gaugeClock: Bool, singleTaskCount: Bool
        public let dimDuration: Double, expandedOpacity: Double
    }

    public static func project(_ request: Request, layout suppliedLayout: CompactIslandLayout? = nil) -> Output? {
        guard let language = AppLanguage(rawValue: request.language), request.providers.count <= 3,
              Set(request.providers).count == request.providers.count, request.options.valid,
              request.warnings.map({ $0.count <= 6 && $0.allSatisfy { CompactIslandLayout.Warning(rawValue: $0) != nil } }) ?? true,
              request.layout.map({ $0.utf8.count <= 8192 }) ?? true else { return nil }
        let providers = Set(request.providers), ordered = AgentProvider.allCases.filter(providers.contains)
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
        guard context.map({ $0.version == 1 && $0.sources.count <= 3 && $0.now.timeIntervalSince1970.isFinite && $0.warnings.count <= 16 }) ?? true else { return nil }
        let date = context?.now ?? Date(timeIntervalSince1970: 0)
        func source(_ provider: AgentProvider) -> CompactBarContext.Source? { context?.sources.first { $0.provider == provider } }
        func selection(_ provider: AgentProvider) -> QuotaWindowSelection {
            .init(saved: provider == .codex ? request.options.codexWindow : request.options.claudeWindow, snapshot: source(provider)?.snapshot)
        }
        func selected(_ provider: AgentProvider) -> QuotaWindow? {
            QuotaDashboardPresentation.selectedWindow(provider: provider, snapshot: source(provider)?.snapshot,
                selection: provider == .codex ? request.options.codexWindow : request.options.claudeWindow)
        }
        let wallet = context?.wallet
        let automatic = request.options.rings.allSatisfy(\.isEmpty)
        let ringChoices: [String]
        if automatic {
            var values = Array(ordered.filter { $0 != .deepseek }.prefix(2)).map(\.rawValue)
            // Settings names an enabled wallet even before it has a budget;
            // the drawing below independently excludes undrawable rings.
            if values.count == 1, providers.contains(.deepseek) { values.append("deepseek") }
            ringChoices = values + Array(repeating: "none", count: 2 - values.count)
        } else { ringChoices = request.options.rings.map { $0.isEmpty ? "none" : $0 } }
        var ringProviders: [AgentProvider] = []
        for raw in ringChoices {
            guard let provider = AgentProvider(rawValue: raw), providers.contains(provider),
                  provider != .deepseek || wallet?.hasBudget == true, !ringProviders.contains(provider) else { continue }
            ringProviders.append(provider)
        }
        let rings: [Ring] = ringProviders.map { provider in
            if provider == .deepseek { return .init(provider: provider.rawValue, remaining: wallet?.budgetPercent, dimmed: wallet?.dimmed == true) }
            let input = source(provider), window = selected(provider)
            return .init(provider: provider.rawValue, remaining: window?.remainingPercent,
                dimmed: input?.snapshot?.isStale(at: date) == true || window?.resetsAt.map { $0 <= date } == true)
        }
        let clock = rings.isEmpty && providers.contains(.deepseek) && !layout.components.contains(.priceClock)
        let usesBudget = layout.components.contains(.quotaGauge) && ringProviders.contains(.deepseek)
        func value(_ provider: AgentProvider) -> Double? {
            quotaValue(provider: provider, snapshot: source(provider)?.snapshot, failed: source(provider)?.failed == true,
                metric: request.options.metric, selection: provider == .codex ? request.options.codexWindow : request.options.claudeWindow, now: date)
        }
        let known = ordered.filter { $0 == .deepseek ? wallet?.hasBalance == true || usesBudget : value($0) != nil }
        let alternating = known.isEmpty ? Array(ordered.prefix(1)) : known
        func percent(_ value: Double?) -> String { value.map { String(Int($0.rounded())) } ?? "—" }
        func entry(_ provider: AgentProvider) -> Entry {
            if provider == .deepseek {
                return .init(provider: provider.rawValue, text: usesBudget ? wallet?.budget ?? "¥—" : wallet?.balance ?? "¥—",
                    stripText: usesBudget ? wallet?.stripBudget ?? "¥—" : wallet?.stripBalance ?? "¥—", dimmed: wallet?.dimmed == true)
            }
            let number = percent(value(provider))
            return .init(provider: provider.rawValue, text: number == "—" ? number : number + "%",
                stripText: number == "—" || !alternating.contains(.deepseek) ? number : number + "%", dimmed: false)
        }
        let entries = alternating.map(entry)
        let times: [Entry] = ordered.filter { $0 != .deepseek }.map { provider in
            let number = percent(selected(provider)?.elapsedTimePercent(at: date).map { 100 - $0 })
            return .init(provider: provider.rawValue, text: number == "—" ? number : number + "%", stripText: number, dimmed: false)
        }
        let quotaHelp = ordered.map(entry).map { entry in L10n.text("provider.compact_quota", AgentProvider(rawValue: entry.provider)!.displayName, entry.text, language: language) }.joined(separator: " · ")
        let gaugeHelp = ringProviders.map { provider in L10n.text("provider.compact_quota", provider.displayName,
            provider == .deepseek ? wallet?.budget ?? "—" : selected(provider)?.remainingPercent.map { "\(Int(min(100, max(0, $0)).rounded()))%" } ?? "—", language: language) }.joined(separator: " · ")
        let timeHelp = times.map { entry in L10n.text("provider.compact_time", AgentProvider(rawValue: entry.provider)!.displayName, entry.text, language: language) }.joined(separator: " · ")
        let clockSummary = L10n.text("deepseek.clock_accessibility", L10n.text(wallet?.peakNow == true ? "deepseek.now.peak" : "deepseek.now.offpeak", language: language),
            DeepSeekDialPresentation.amount(wallet?.todayTotal ?? 0), language: language)
        let componentValues = CompactIslandLayout.Component.allCases.map { component -> Component in
            var text: String?, stripText: String?, unit: String?, stripUnit: String?
            var help = "", accessibility = "", visible = component.isAvailable(for: providers), values: [Entry] = []
            switch component {
            case .activity: help = context?.activitySummary(language: language) ?? L10n.text("activity.idle", language: language)
            case .status: text = context?.statusText(language: language) ?? L10n.text("activity.idle", language: language); help = text!
            case .tps:
                let compact = request.attached || request.strip
                text = context?.rate.map { rate in compact && rate >= 1_000_000 ? String(format: "%.1fM", rate / 1_000_000) : compact && rate >= 1000 ? String(format: "%.1fk", rate / 1000) : String(format: "%.0f", rate) } ?? "—"
                stripText = text; unit = "t/s"; stripUnit = unit
                visible = context?.running == true && context?.rate != nil &&
                    (!layout.components.contains(.status) || request.strip || !request.attached || language != .english || context?.attention != true)
                help = L10n.text(context?.rateFresh == true ? "performance.total_help" : "performance.partial_total_help", context?.rate ?? 0, language: language)
            case .firstOutput:
                text = context?.firstOutput.map { String(format: "%.2f s", $0) } ?? "—"
                stripText = context?.firstOutput.map { String(format: $0 < 10 ? "%.1f" : "%.0f", $0) } ?? "—"; stripUnit = "s"
                help = L10n.text("layout.latest_ttft_help", language: language)
            case .warnings: visible = context?.warnings.isEmpty == false; help = context?.warnings.map(\.help).joined(separator: "\n") ?? ""
            case .quota: values = entries; stripUnit = alternating.contains(.deepseek) ? nil : "%"; help = quotaHelp + "\n" + L10n.text("layout.metric_help", language: language)
            case .quotaGauge: visible = !rings.isEmpty || clock; help = clock ? "" : gaugeHelp + "\n" + L10n.text("layout.gauge_help", language: language)
            case .priceClock: break
            case .quotaLabel: text = L10n.text(request.options.metric == "pace" ? "quota.pace" : "layout.quota_label", language: language); help = quotaHelp + "\n" + L10n.text("layout.metric_help", language: language)
            case .timeRemaining: values = times; stripUnit = "%"; help = timeHelp + "\n" + L10n.text("layout.time_remaining_help", language: language)
            }
            switch component {
            case .firstOutput: accessibility = L10n.text("performance.first_output", text ?? "—", language: language)
            case .quota: accessibility = quotaHelp
            case .quotaGauge: accessibility = clock ? clockSummary : gaugeHelp
            case .quotaLabel: accessibility = text ?? ""
            case .timeRemaining: accessibility = timeHelp
            case .tps: accessibility = (text ?? "—") + " t/s"
            case .priceClock: accessibility = clockSummary
            default: accessibility = help
            }
            return .init(id: component.rawValue, label: L10n.text("layout.component." + component.rawValue, language: language),
                shortLabel: L10n.text("layout.short." + component.rawValue, language: language), detail: L10n.text("layout.detail." + component.rawValue, language: language), symbol: component.symbol,
                hideLabel: L10n.text("layout.hide_component", L10n.text("layout.component." + component.rawValue, language: language), language: language),
                available: component.isAvailable(for: providers), shown: layout.components.contains(component), visible: visible, stripEligible: component.showsInStrip,
                dimsExpanded: dimsWhenExpanded(component), text: text, stripText: stripText,
                unit: unit, stripUnit: stripUnit, help: help, accessibility: accessibility, entries: values)
        }
        func runtime(_ lane: CompactIslandLayout.Lane) -> [String] {
            layout[lane].filter { component in componentValues.first { $0.id == component.rawValue }.map { $0.visible && (!request.strip || $0.stripEligible) } == true }.map(\.rawValue)
        }
        let windows: [Window] = ordered.filter { $0 != .deepseek }.map { provider in
            let snapshot = source(provider)?.snapshot
            let own = snapshot.flatMap { $0.buckets.first { $0.id == provider.rawValue } ?? $0.buckets.first }
            let weeklyOnly = own?.windows.contains(where: { $0.durationMinutes == 10080 }) == true && own?.windows.contains(where: { $0.durationMinutes == 300 }) == false
            return .init(provider: provider.rawValue, label: L10n.text("provider.window_selection", provider.displayName, language: language),
                selection: weeklyOnly ? "7d" : selection(provider).rawValue, weeklyOnly: weeklyOnly)
        }
        return .init(version: 1, layoutJSON: canonical, warnings: CompactIslandLayout.Warning.allCases.filter(layout.warnings.contains).map(\.rawValue),
            editorLeading: layout.visibleComponents(in: .leading, providers: providers).map(\.rawValue), editorTrailing: layout.visibleComponents(in: .trailing, providers: providers).map(\.rawValue),
            leading: runtime(.leading), trailing: runtime(.trailing), components: componentValues,
            groups: CompactIslandLayout.Group.allCases.map { .init(id: $0.rawValue, label: L10n.text("layout.group." + $0.rawValue, language: language), components: $0.components.map(\.rawValue)) },
            windows: windows, rings: rings, ringChoices: ringChoices, gaugeClock: clock, singleTaskCount: request.options.singleTask == "count",
            dimDuration: dimDuration, expandedOpacity: expandedOpacity)
    }
    public static func quotaValue(provider: AgentProvider, snapshot: QuotaSnapshot?, failed: Bool,
                                  metric: String, selection: String?, now: Date) -> Double? {
        let window = QuotaDashboardPresentation.selectedWindow(provider: provider, snapshot: snapshot, selection: selection)
        if metric == "pace" {
            guard !failed, snapshot?.isStale(at: now) == false else { return nil }
            return window?.pacePercent(at: now)
        }
        return window?.remainingPercent
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
