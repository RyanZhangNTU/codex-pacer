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
            groups: taskGroups, overview: overview, now: now)
    }

    func compactPresentation(showsStatus: Bool = true) -> CompactBarPresentation.Output {
        var layout = compactLayout
        if !showsStatus { layout.hide(.status) }
        let options = CompactBarPresentation.Options(singleTask: ActivityBadgeSingleTask(defaults: defaults).rawValue,
            metric: defaults.string(forKey: "compactMetric") == "pace" ? "pace" : "remaining",
            codexWindow: QuotaWindowSelection(saved: defaults.string(forKey: "quotaWindowID"), snapshot: providerQuota(.codex)).rawValue,
            claudeWindow: QuotaWindowSelection(saved: defaults.string(forKey: "claudeQuotaWindowID"), snapshot: providerQuota(.claude)).rawValue,
            rings: QuotaRingSlot.allCases.map { slot in
                guard let saved = defaults.string(forKey: slot.defaultsKey) else { return "" }
                return AgentProvider(rawValue: saved)?.rawValue ?? "none"
            })
        let request = CompactBarPresentation.Request(providers: enabledProviders, options: options,
            context: compactContext, attached: isAttached, strip: sideDock != nil)
        if let cached = compactPresentationCache, cached.layout == layout, cached.request == request { return cached.output }
        guard let output = CompactBarPresentation.project(request, layout: layout) else {
            preconditionFailure("The native compact presentation inputs must be normalized")
        }
        compactPresentationCache = (layout, request, output)
        return output
    }

    func compactComponent(_ component: CompactIslandLayout.Component, showsStatus: Bool = true) -> CompactBarPresentation.Component {
        compactPresentation(showsStatus: showsStatus).components.first { $0.id == component.rawValue }!
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
