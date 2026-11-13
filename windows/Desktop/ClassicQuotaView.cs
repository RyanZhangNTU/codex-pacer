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
    /// <param name="layout">One panel section's classic drawing from Core, its slots in block order.</param>
    /// <param name="providers">That section's services' readings.</param>
    internal ClassicQuotaView(DashboardLayout layout, IReadOnlyList<DashboardProvider> providers, IReadOnlyList<EngineQuota> raw, EngineWallet? wallet, UiText ui,
        Func<DashboardProvider?, FrameworkElement?> status, Action? connectDeepSeek = null, string? connectUnavailable = null, FrameworkElement? deepseekStatus = null,
        PanelOptions? options = null, bool budgetDial = true, Func<bool, bool, FrameworkElement>? account = null)
    {
        options ??= PanelOptions.Default;
        var row = new Grid(); Children.Add(row);
        foreach (var (slot, index) in layout.Slots.Select((item, index) => (item, index)))
        {
            FrameworkElement cell;
            if (slot.Period == null && account != null)
                cell = account(layout.Slots.Count == 1 && options.QuotaDetails, layout.Slots.Count > 1 || !options.QuotaDetails);
            else if (slot.Provider == "deepseek") cell = new DeepSeekQuotaCell(wallet, ui, 88, connectDeepSeek, connectUnavailable, deepseekStatus, budgetDial: budgetDial);
            else
            {
                var provider = providers.FirstOrDefault(value => value.Provider == slot.Provider);
                if (provider == null) continue;
                var classic = new ClassicQuotaCell(slot, provider, raw.FirstOrDefault(value => value.Provider == slot.Provider), null,
                    options.PaceTick, options.Periods(slot.Provider) == "both");
                if (slot.IdentifiesProvider)
                {
                    var recovery = status(provider) ?? new Border { Height = 0 };
                    recovery.Margin = new Thickness(0, 6, 0, 0); classic.Children.Add(recovery);
                }
                cell = classic;
            }
            QuotaCells.Add(row, cell, index, layout.Columns ?? layout.Slots.Count);
            AutomationProperties.SetAutomationId(cell, "quota.classic." + slot.Id);
        }
        if (providers.Count == 1 && providers[0].Provider != "deepseek" && layout.Slots.All(slot => slot.Provider == providers[0].Provider))
        {
            var recovery = status(providers[0]) ?? new Border { Height = 0 };
            recovery.Margin = new Thickness(0, 12, 0, 0); Children.Add(recovery);
        }
    }
}

internal static class QuotaCells
{
    internal static void Add(Grid grid, FrameworkElement cell, int index, int columns)
    {
        int column = (index % columns) * 2, row = (index / columns) * 2;
        while (grid.ColumnDefinitions.Count <= column)
            grid.ColumnDefinitions.Add(grid.ColumnDefinitions.Count % 2 == 0 ? new() : new() { Width = new GridLength(16) });
        while (grid.RowDefinitions.Count <= row)
            grid.RowDefinitions.Add(new() { Height = grid.RowDefinitions.Count % 2 == 0 ? GridLength.Auto : new GridLength(12) });
        cell.VerticalAlignment = VerticalAlignment.Top;
        Grid.SetColumn(cell, column); Grid.SetRow(cell, row); grid.Children.Add(cell);
    }
}
