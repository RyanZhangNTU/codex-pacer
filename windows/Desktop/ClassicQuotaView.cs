using System;
using System.Collections.Generic;
using System.Linq;
using System.Windows;
using System.Windows.Automation;
using System.Windows.Controls;

namespace CodexPacer.Windows;

/// The original classic row: shared slots decide provider/period ordering;
/// per-provider recovery follows its own summary, or the single-provider row.
internal sealed class ClassicQuotaView : StackPanel
{
    internal ClassicQuotaView(EngineQuotaDashboard data, IReadOnlyList<EngineQuota> raw, EngineWallet? wallet, UiText ui,
        Func<DashboardProvider?, FrameworkElement?> status, Action? connectDeepSeek = null, string? connectUnavailable = null, FrameworkElement? deepseekStatus = null)
    {
        var row = new Grid(); Children.Add(row);
        foreach (var slot in data.Classic.Slots)
        {
            if (row.Children.Count > 0) row.ColumnDefinitions.Add(new() { Width = new GridLength(16) });
            int column = row.ColumnDefinitions.Count; row.ColumnDefinitions.Add(new());
            var provider = data.Providers.Single(value => value.Provider == slot.Provider);
            FrameworkElement cell;
            if (slot.Provider == "deepseek") cell = new DeepSeekQuotaCell(wallet, ui, 88, connectDeepSeek, connectUnavailable, deepseekStatus);
            else
            {
                var classic = new ClassicQuotaCell(slot, provider, raw.FirstOrDefault(value => value.Provider == slot.Provider), null);
                if (slot.IdentifiesProvider)
                {
                    var recovery = status(provider) ?? new Border { Height = 0 };
                    recovery.Margin = new Thickness(0, 6, 0, 0); classic.Children.Add(recovery);
                }
                cell = classic;
            }
            Grid.SetColumn(cell, column); row.Children.Add(cell);
            AutomationProperties.SetAutomationId(cell, "quota.classic." + slot.Id);
        }
        if (data.Providers.Count == 1)
        {
            var recovery = status(data.Providers[0]) ?? new Border { Height = 0 };
            recovery.Margin = new Thickness(0, 12, 0, 0); Children.Add(recovery);
        }
    }
}
