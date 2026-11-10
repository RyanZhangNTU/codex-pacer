import Foundation
import PacerCore

extension IslandModel {
    var compactTaskContext: CompactBarContext {
        CompactBarContext(activities: activities, requests: pendingInputRequests, completions: pendingCompletions,
            sources: [], firstOutput: latestFirstOutputLatency, groups: taskGroups, overview: overview, now: now)
    }
    var compactWarningItems: [CompactWarningPresentation.Item] { warningItems() }
    func warningItems(warnings supplied: Set<CompactIslandLayout.Warning>? = nil) -> [CompactWarningPresentation.Item] {
        let enabled = Set(enabledProviders), warnings = supplied ?? compactLayout.warnings
        let snapshots = Dictionary(uniqueKeysWithValues: enabledProviders.compactMap { provider in
            providerQuota(provider).map { (provider, $0) }
        })
        let failed = Set(enabledProviders.filter { providerQuotaError($0) != nil })
        let selections = Dictionary(uniqueKeysWithValues: enabledProviders.filter { $0 != .deepseek }.map { provider in
            (provider, QuotaWindowSelection(saved: defaults.string(forKey: provider == .codex ? "quotaWindowID" : "claudeQuotaWindowID"),
                snapshot: providerQuota(provider)))
        })
        let wallet = enabled.contains(.deepseek) ? DeepSeekAlertPresentation(wallet: deepseekWallet,
            lowBalance: warnings.contains(.lowBalance), spike: warnings.contains(.spendSpike), budget: warnings.contains(.budget)) : nil
        return CompactWarningPresentation.items(enabled: enabled, warnings: warnings, snapshots: snapshots,
            failed: failed, selections: selections, sshIssue: hasSSHConnectionIssue, wallet: wallet, now: now)
    }

    var compactContext: CompactBarContext {
        CompactBarContext(activities: activities, requests: pendingInputRequests, completions: pendingCompletions,
            sources: enabledProviders.filter { $0 != .deepseek }.map {
                .init(provider: $0, snapshot: providerQuota($0), failed: providerQuotaError($0) != nil)
            }, wallet: enabledProviders.contains(.deepseek) ? .init(deepseekWallet, preferred: deepseekRingPeriod) : nil,
            firstOutput: latestFirstOutputLatency, warnings: compactWarningItems,
            groups: taskGroups, overview: overview, firstOutputs: activityState.firstOutputHistory.values, now: now)
    }
    /// Every component's choices, edited in the Collapsed Bar page.
    var compactComponentOptions: CompactComponentOptions { .load(from: defaults) }
    /// The bar size the island draws at: the saved one, or standard while
    /// attached to a hardware notch, whose height the bar keeps.
    var compactBarSize: CompactBarSize {
        CompactBarSize.load(from: defaults).effective(attached: isAttached, hardwareNotch: screenNotchSize.height > 0)
    }
    var barMetrics: CompactBarMetrics { compactBarSize.metrics }

    func compactPresentation(showsStatus: Bool = true) -> CompactBarPresentation.Output {
        var layout = compactLayout
        if !showsStatus { layout.hide(.status) }
        let options = CompactBarPresentation.Options(singleTask: ActivityBadgeSingleTask(defaults: defaults),
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
            context: compactContext, attached: isAttached, strip: sideDock != nil, componentOptions: choices.json,
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
        DeepSeekSoloPresentation(wallet: deepseekWallet, at: now, hideProjects: hideProjects, taskTitle: deepseekTaskTitle)
    }

    func quotaHistoryPresentation(_ provider: AgentProvider) -> QuotaHistoryPresentation {
        let snapshot = providerQuota(provider)
        let chart = providerCurrentCycle(provider).map {
            QuotaCycleChartPresentation(data: QuotaChartData(cycle: $0, resetCredits: snapshot?.resetCredits, now: now))
        }
        return .init(provider: provider, snapshot: snapshot, weekly: dashboardQuota(provider: provider, period: .weekly),
            chart: chart, error: providerQuotaError(provider), warning: providerHistoryWarning(provider),
            refreshing: providerRefreshing(provider), accountContext: "", now: now)
    }
}
