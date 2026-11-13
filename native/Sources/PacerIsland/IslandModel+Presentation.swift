import Foundation
import PacerCore

struct CompactBarSnapshot {
    struct PriceClock {
        let hourly: [Double]
        let peaks: [ClosedRange<Double>]
        let angle: Double
        let dimmed: Bool
        let peakNow: Bool

        init(wallet: DeepSeekWallet, now: Date) {
            hourly = wallet.hourly
            peaks = wallet.peakToday.map { wallet.angle(of: $0.start)...wallet.angle(of: $0.end) }
            angle = wallet.angle(of: now)
            dimmed = [.stale, .disconnected].contains(wallet.state)
            peakNow = wallet.peakNow
        }
    }

    let output: CompactBarPresentation.Output
    let context: CompactBarContext
    let activity: HeaderActivity
    let hasPendingAttention: Bool
    let clock: PriceClock?
    let stripWidth: CGFloat

    var metrics: CompactBarMetrics { output.metrics ?? .standard }
    var choices: CompactComponentOptions { output.componentOptions ?? CompactComponentOptions() }
}

extension IslandModel {
    var compactTaskContext: CompactBarContext {
        CompactBarContext(activities: activities, requests: pendingInputRequests, completions: pendingCompletions,
            sources: [], firstOutput: latestFirstOutputLatency, groups: taskGroups, overview: overview, now: now)
    }
    var compactWarningItems: [CompactWarningPresentation.Item] { warningItems() }
    func warningItems(warnings supplied: Set<CompactIslandLayout.Warning>? = nil) -> [CompactWarningPresentation.Item] {
        warningItems(warnings: supplied ?? compactLayout.warnings, wallet: compactWallet)
    }

    private var compactWallet: DeepSeekWallet? { enabledProviders.contains(.deepseek) ? deepseekWallet : nil }

    private func warningItems(warnings: Set<CompactIslandLayout.Warning>, wallet: DeepSeekWallet?) -> [CompactWarningPresentation.Item] {
        let enabled = Set(enabledProviders)
        let snapshots = Dictionary(uniqueKeysWithValues: enabledProviders.compactMap { provider in
            providerQuota(provider).map { (provider, $0) }
        })
        let failed = Set(enabledProviders.filter { providerQuotaError($0) != nil })
        let selections = Dictionary(uniqueKeysWithValues: enabledProviders.filter { $0 != .deepseek }.map { provider in
            (provider, QuotaWindowSelection(saved: defaults.string(forKey: provider == .codex ? "quotaWindowID" : "claudeQuotaWindowID"),
                snapshot: providerQuota(provider)))
        })
        let alert = wallet.flatMap { DeepSeekAlertPresentation(wallet: $0,
            lowBalance: warnings.contains(.lowBalance), spike: warnings.contains(.spendSpike), budget: warnings.contains(.budget)) }
        return CompactWarningPresentation.items(enabled: enabled, warnings: warnings, snapshots: snapshots,
            failed: failed, selections: selections, sshIssue: hasSSHConnectionIssue, wallet: alert, now: now)
    }

    private func compactInputs() -> (context: CompactBarContext, tasks: ActivityTaskPresentation, wallet: DeepSeekWallet?) {
        let tasks = taskPresentation
        let wallet = compactWallet
        let context = CompactBarContext(activities: activities, requests: pendingInputRequests, completions: tasks.pendingCompletions,
            sources: quotaProviders.filter { $0 != .deepseek }.map {
                .init(provider: $0, snapshot: providerQuota($0), failed: providerQuotaError($0) != nil)
            }, wallet: wallet.map { .init($0, preferred: deepseekRingPeriod) },
            firstOutput: latestFirstOutputLatency, warnings: warningItems(warnings: compactLayout.warnings, wallet: wallet),
            groups: tasks.groups, overview: tasks.overview, firstOutputs: activityState.firstOutputHistory.values, now: now)
        return (context, tasks, wallet)
    }

    /// Every component's choices, edited in the Collapsed Bar page.
    var compactComponentOptions: CompactComponentOptions { .load(from: defaults) }
    /// The bar size the island draws at: the saved one, or standard while
    /// attached to a hardware notch, whose height the bar keeps.
    var compactBarSize: CompactBarSize {
        CompactBarSize.load(from: defaults).effective(attached: isAttached, hardwareNotch: screenNotchSize.height > 0)
    }
    var barMetrics: CompactBarMetrics { compactBarSize.metrics }

    /// The visible bar and its ideal-size copy draw from the same inputs.
    func compactBarSnapshot(showsStatus: Bool = true) -> CompactBarSnapshot {
        let (context, tasks, wallet) = compactInputs()
        let singleTask = ActivityBadgeSingleTask(defaults: defaults)
        let output = compactPresentation(showsStatus: showsStatus, context: context, singleTask: singleTask)
        return CompactBarSnapshot(output: output, context: context,
            activity: tasks.header(singleTask: singleTask, symbol: StatusSymbols.symbol),
            hasPendingAttention: !pendingInputRequests.isEmpty || !tasks.pendingCompletions.isEmpty,
            clock: wallet.map { .init(wallet: $0, now: context.now) }, stripWidth: stripWidth)
    }

    func compactPresentation(showsStatus: Bool = true) -> CompactBarPresentation.Output {
        compactPresentation(showsStatus: showsStatus, context: compactInputs().context, singleTask: ActivityBadgeSingleTask(defaults: defaults))
    }

    private func compactPresentation(showsStatus: Bool, context: CompactBarContext,
                                     singleTask: ActivityBadgeSingleTask) -> CompactBarPresentation.Output {
        var layout = compactLayout
        if !showsStatus { layout.hide(.status) }
        let options = CompactBarPresentation.Options(singleTask: singleTask,
            metric: defaults.string(forKey: "compactMetric").flatMap(CompactBarPresentation.Metric.init(rawValue:)) ?? .remaining,
            codexWindow: QuotaWindowSelection(saved: defaults.string(forKey: "quotaWindowID"), snapshot: providerQuota(.codex)).rawValue,
            claudeWindow: QuotaWindowSelection(saved: defaults.string(forKey: "claudeQuotaWindowID"), snapshot: providerQuota(.claude)).rawValue,
            rings: QuotaRingSlot.allCases.map { slot in
                guard let saved = defaults.string(forKey: slot.defaultsKey) else { return .automatic }
                // A present empty or unknown preference previously meant no ring.
                return AgentProvider(rawValue: saved).map(CompactBarPresentation.RingChoice.init(provider:)) ?? .none
            })
        let choices = compactComponentOptions
        let request = CompactBarPresentation.Request(providers: enabledProviders, options: options,
            context: context, attached: isAttached, strip: sideDock != nil, componentOptions: choices.json,
            size: compactBarSize.rawValue)
        if let cached = compactPresentationCache[showsStatus], cached.layout == layout, cached.request == request { return cached.output }
        guard let output = CompactBarPresentation.project(request, layout: layout, components: choices) else {
            return .empty
        }
        compactPresentationCache[showsStatus] = (layout, request, output)
        return output
    }

    func compactComponent(_ component: CompactIslandLayout.Component, showsStatus: Bool = true) -> CompactBarPresentation.Component {
        compactPresentation(showsStatus: showsStatus).component(component)
    }

    var deepseekSoloPresentation: DeepSeekSoloPresentation {
        DeepSeekSoloPresentation(wallet: deepseekWallet, at: now, hideProjects: hideProjects, panel: panelOptions, taskTitle: deepseekTaskTitle)
    }

    /// The panel's blocks: the saved ones, or the services' as before blocks.
    var panelLayout: ExpandedPanelLayout {
        .resolved(saved: savedPanelLayout, providers: Set(enabledProviders), deepseekDetailed: deepseekPanelStyle == .detailed)
    }

    /// What the expanded panel draws, top to bottom.
    var panelSections: [ExpandedPanelPresentation.Section] {
        ExpandedPanelPresentation.sections(layout: panelLayout, providers: Set(enabledProviders), options: panelOptions,
            budgetDial: deepseekShowsBudgetDial)
    }

    /// The History pane draws the cycle chart itself; it reads only the text here. Labeling
    /// every chart point on each redraw only decided whether the placeholder shows, which
    /// the pane shows only without a cycle.
    func quotaHistoryPresentation(_ provider: AgentProvider) -> QuotaHistoryPresentation {
        .init(provider: provider, snapshot: providerQuota(provider), weekly: dashboardQuota(provider: provider, period: .weekly),
            chart: nil, error: providerQuotaError(provider), warning: providerHistoryWarning(provider),
            refreshing: providerRefreshing(provider), accountContext: "", now: now)
    }
}
