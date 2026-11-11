using System;
using System.Collections.Generic;
using System.Linq;

namespace CodexPacer.Windows;

public partial class IslandWindow
{
    // A new snapshot deserializes every list again. Compare list contents and
    // leave clock values to the controls that can update them in place.
    private static bool SameQuota(QuotaPaint a, QuotaPaint b) =>
        a == b with { Layout = a.Layout, Providers = a.Providers, Legacy = a.Legacy, Wallet = a.Wallet, BalanceStatus = a.BalanceStatus } &&
        SameValue(a.Layout, b.Layout, static (x, y) => x == y with { Slots = x.Slots } && x.Slots.SequenceEqual(y.Slots)) &&
        SameItems(a.Providers, b.Providers, SameProvider) &&
        SameValue(a.Legacy, b.Legacy, SameLegacy) && SameWallet(a.Wallet, b.Wallet, b.Budget, b.Solo, b.SpendBeside) &&
        SameValue(a.BalanceStatus, b.BalanceStatus, static (x, y) =>
            x == y with { Actions = x.Actions } && x.Actions.SequenceEqual(y.Actions));

    private static bool SameLegacy(LegacyQuotaDashboard a, LegacyQuotaDashboard b) =>
        a == b with { Buckets = a.Buckets } && SameItems(a.Buckets, b.Buckets, static (x, y) =>
            x == y with { Windows = x.Windows } && x.Windows.SequenceEqual(y.Windows));

    private static bool SameProvider(ProviderPaint a, ProviderPaint b) => a == b with { Reading = a.Reading } &&
        SameValue(a.Reading, b.Reading, static (x, y) =>
            x == y with { FiveHour = x.FiveHour, Weekly = x.Weekly, Status = x.Status } &&
            SameReading(x.FiveHour, y.FiveHour) && SameReading(x.Weekly, y.Weekly) &&
            SameValue(x.Status, y.Status, static (previous, current) =>
                previous == current with { Actions = previous.Actions } && previous.Actions.SequenceEqual(current.Actions)));

    // Only the dial uses the unrounded time and pace. Formatted labels, help
    // and accessibility also belong to other provider controls.
    private static bool SameReading(DashboardReading a, DashboardReading b) => a == b ||
        a == b with { RemainingTimePercent = a.RemainingTimePercent, PacePercent = a.PacePercent, CapturedAt = a.CapturedAt };

    private static bool SameWallet(EngineWallet? a, EngineWallet? b, bool budget, bool solo, bool spend)
    {
        if (ReferenceEquals(a, b)) return true;
        if (a == null || b == null) return false;

        var previousBudgets = budget ? a.Solo?.Budgets ?? [] : [];
        var currentBudgets = budget ? b.Solo?.Budgets ?? [] : [];
        if (!SameItems(previousBudgets, currentBudgets, SameBudget)) return false;
        bool showsBudget = currentBudgets.Count > 0;
        if (!SameWalletValues(a, b, showsBudget)) return false;
        if (!showsBudget && (!a.Hourly.SequenceEqual(b.Hourly) || !a.Peak.SequenceEqual(b.Peak))) return false;
        return !solo || a.Dial?.PeakHelp == b.Dial?.PeakHelp && SameSolo(a.Solo, b.Solo, spend);
    }

    // Ignore only data for a different surface, lists compared separately,
    // and day-dial values when a budget replaces that dial. New fields take
    // part in record equality until a renderer explicitly owns their update.
    private static bool SameWalletValues(EngineWallet a, EngineWallet b, bool showsBudget) => a == b with
    {
        Angle = a.Angle, Hourly = a.Hourly, Peak = a.Peak, Solo = a.Solo,
        Compact = a.Compact, Today = a.Today, Elsewhere = a.Elsewhere, AverageDaily = a.AverageDaily,
        RunwayDays = a.RunwayDays, Settings = a.Settings, Alert = a.Alert, Reminders = a.Reminders,
        Balance = showsBudget ? a.Balance : b.Balance, Whole = showsBudget ? a.Whole : b.Whole,
        Cents = showsBudget ? a.Cents : b.Cents, Dial = showsBudget ? a.Dial : b.Dial,
        Subtitle = showsBudget ? a.Subtitle : b.Subtitle
    };

    // The budget dial and detail rows handle these fields. A change in spend,
    // period, verdict or warning still repaints the section.
    private static bool SameBudget(DeepSeekBudgetPresentation a, DeepSeekBudgetPresentation b) => a == b ||
        a == b with
        {
            TimeFraction = a.TimeFraction, PacePercent = a.PacePercent, Countdown = a.Countdown,
            PaceText = a.PaceText, ProjectionText = a.ProjectionText, Help = a.Help
        };

    private static bool SameSolo(DeepSeekSoloPresentation? a, DeepSeekSoloPresentation? b, bool spend) =>
        SameValue(a, b, (x, y) =>
            x == y with { Speed = x.Speed, Distribution = x.Distribution, Week = x.Week, Budgets = x.Budgets } &&
            SameValue(x.Speed, y.Speed, static (previous, current) =>
                previous == current with { Fractions = previous.Fractions } && previous.Fractions.SequenceEqual(current.Fractions)) &&
            (!spend || SameDistribution(x.Distribution, y.Distribution)));

    private static bool SameDistribution(DeepSeekDistribution? a, DeepSeekDistribution? b) =>
        SameValue(a, b, static (x, y) => x == y with { Parts = x.Parts } && x.Parts.SequenceEqual(y.Parts));

    private static bool SameChart(ChartPaint a, ChartPaint b) => a == b with { Distribution = a.Distribution, Week = a.Week } &&
        SameDistribution(a.Distribution, b.Distribution) &&
        SameValue(a.Week, b.Week, static (x, y) => x == y with { Days = x.Days } && x.Days.SequenceEqual(y.Days));

    private static bool SameValue<T>(T? a, T? b, Func<T, T, bool> equals) where T : class =>
        ReferenceEquals(a, b) || a != null && b != null && equals(a, b);

    private static bool SameItems<T>(IReadOnlyList<T> a, IReadOnlyList<T> b, Func<T, T, bool> equals)
    {
        if (ReferenceEquals(a, b)) return true;
        if (a.Count != b.Count) return false;
        for (int index = 0; index < a.Count; index++)
            if (!equals(a[index], b[index])) return false;
        return true;
    }
}
