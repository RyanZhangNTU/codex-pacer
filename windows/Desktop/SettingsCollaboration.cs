using System;
using System.IO;
using System.Linq;
using System.Runtime.InteropServices;
using System.Text.RegularExpressions;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;

namespace CodexPacer.Windows;

/// Settings → Collaboration, a page of its own as on the Mac: Codex for Claude's
/// switch, its status, how runs show, the defaults the runner applies when
/// Claude leaves them out, and the last week's runs. Explanations wait behind ⓘ.
internal sealed partial class SettingsWindow
{
    private CheckBox? delegationEnabled;
    private StackPanel? delegationSections;
    private TextBlock? delegationCodex, delegationSkill, delegationLegacyPath, delegationWeek;
    private Grid? delegationLegacy;
    private Button? delegationLegacyRemove;
    private TextBox? delegationModel;
    private ComboBox? delegationDisplay, delegationEffort, delegationFast, delegationAccess, delegationTimeout, delegationConcurrency;

    private void ClearCollaboration()
    {
        delegationEnabled = null; delegationSections = null; delegationCodex = delegationSkill = delegationLegacyPath = delegationWeek = null;
        delegationLegacy = null; delegationLegacyRemove = null; delegationModel = null;
        delegationDisplay = delegationEffort = delegationFast = delegationAccess = delegationTimeout = delegationConcurrency = null;
    }

    private void BuildCollaboration()
    {
        var main = Toggle("collaboration.codex_for_claude", "collaboration.info.codex_for_claude", "settings.collaboration.enabled", out var enabled);
        delegationEnabled = enabled; editors.Add(enabled);
        BindToggle(enabled, (p, value) => p with { CodexDelegation = value });
        form.Children.Add(Card(main));
        delegationSections = new StackPanel(); form.Children.Add(delegationSections);

        delegationSections.Children.Add(SectionTitle(ui.Text("main.section.status")));
        delegationCodex = Detail(""); Identify(delegationCodex, "settings.collaboration.codex", "");
        delegationSkill = Detail(""); Identify(delegationSkill, "settings.collaboration.skill", "");
        delegationLegacyPath = Detail(""); delegationLegacyPath.TextWrapping = TextWrapping.Wrap;
        delegationLegacyRemove = new Button { Content = ui.Text("collaboration.legacy_remove"), VerticalAlignment = VerticalAlignment.Center };
        Identify(delegationLegacyRemove, "settings.collaboration.legacy_remove", ui.Text("collaboration.legacy_remove")); editors.Add(delegationLegacyRemove);
        delegationLegacyRemove.Click += (_, _) => RemoveLegacySkill();
        delegationLegacy = InfoRow(ui.Text("collaboration.legacy"), delegationLegacyRemove, ui.Text("collaboration.info.legacy"), delegationLegacyPath,
            "settings.collaboration.legacy");
        delegationSections.Children.Add(Card(InfoRow(ui.Text("collaboration.codex_program"), delegationCodex),
            InfoRow(ui.Text("collaboration.skill"), delegationSkill), delegationLegacy));

        delegationSections.Children.Add(SectionTitle(ui.Text("main.section.display")));
        delegationDisplay = Choices("settings.collaboration.display", [("rows", ui.Text("collaboration.display.rows")), ("count", ui.Text("collaboration.display.count"))],
            (p, value) => p with { CodexDelegationRows = value == "rows" });
        delegationSections.Children.Add(Card(InfoRow(ui.Text("collaboration.display"), delegationDisplay)));

        delegationSections.Children.Add(SectionTitle(ui.Text("collaboration.section.defaults")));
        delegationModel = new TextBox { MinWidth = 180, MaxWidth = 240, MaxLength = 80, VerticalAlignment = VerticalAlignment.Center, ToolTip = ui.Text("collaboration.model_hint") };
        Identify(delegationModel, "settings.collaboration.model", ui.Text("collaboration.model")); editors.Add(delegationModel);
        delegationModel.LostKeyboardFocus += async (_, _) => await CommitDelegationModel();
        delegationModel.KeyDown += async (_, e) => { if (e.Key == Key.Enter) { e.Handled = true; await CommitDelegationModel(); } };
        string follow = ui.Text("collaboration.follow");
        delegationEffort = Choices("settings.collaboration.effort",
            DesktopPreferences.DelegationEfforts.Select(value => (value, value.Length == 0 ? follow : ui.Text("collaboration.effort." + value))).ToArray(),
            (p, value) => p with { CodexDelegationEffort = value });
        delegationFast = Choices("settings.collaboration.fast", [("", follow), ("on", ui.Text("collaboration.fast.on")), ("off", ui.Text("collaboration.fast.off"))],
            (p, value) => p with { CodexDelegationFast = value });
        delegationAccess = Choices("settings.collaboration.access", [("read", ui.Text("collaboration.access.read_only")), ("write", ui.Text("collaboration.access.write"))],
            (p, value) => p with { CodexDelegationWrite = value == "write" });
        string minutes = ui.Text("collaboration.unit.minutes");
        delegationTimeout = Choices("settings.collaboration.timeout",
            DesktopPreferences.DelegationTimeouts.Select(value => (value.ToString(), value + " " + minutes)).ToArray(),
            (p, value) => p with { CodexDelegationTimeout = int.Parse(value) });
        delegationConcurrency = Choices("settings.collaboration.concurrency",
            DesktopPreferences.DelegationConcurrency.Select(value => (value.ToString(), value.ToString())).ToArray(),
            (p, value) => p with { CodexDelegationConcurrency = int.Parse(value) });
        delegationSections.Children.Add(Card(
            InfoRow(ui.Text("collaboration.model"), delegationModel, ui.Text("collaboration.info.defaults"), id: "settings.collaboration.model_row"),
            InfoRow(ui.Text("collaboration.effort"), delegationEffort), InfoRow(ui.Text("collaboration.fast"), delegationFast),
            InfoRow(ui.Text("collaboration.access"), delegationAccess, ui.Text("collaboration.info.access"), id: "settings.collaboration.access_row"),
            InfoRow(ui.Text("collaboration.timeout"), delegationTimeout), InfoRow(ui.Text("collaboration.concurrency"), delegationConcurrency)));

        delegationSections.Children.Add(SectionTitle(ui.Text("collaboration.section.week")));
        delegationWeek = Label(""); Identify(delegationWeek, "settings.collaboration.week", "");
        var week = new Border { Child = delegationWeek, Padding = new Thickness(14, 12, 14, 12) };
        delegationSections.Children.Add(Card(week));
        RefreshCollaboration();
    }

    private ComboBox Choices(string id, (string Value, string Label)[] choices, Func<DesktopPreferences, string, DesktopPreferences> write)
    {
        var box = new ComboBox { VerticalAlignment = VerticalAlignment.Center, MinWidth = 150, MaxWidth = 240, SelectedValuePath = "Tag" };
        foreach (var (value, label) in choices) box.Items.Add(new ComboBoxItem { Content = label, Tag = value });
        Identify(box, id, "");
        box.SelectionChanged += async (_, _) => { if (!synchronizing && box.SelectedValue is string value) await Change(p => write(p, value)); };
        editors.Add(box);
        return box;
    }

    private async System.Threading.Tasks.Task CommitDelegationModel()
    {
        if (synchronizing || delegationModel == null) return;
        string value = delegationModel.Text.Trim();
        // A model slug: letters, digits and the punctuation Codex uses in them.
        if (value.Length > 0 && !Regex.IsMatch(value, @"^[A-Za-z0-9][A-Za-z0-9._:/-]{0,79}$")) { delegationModel.Text = session.Current.CodexDelegationModel; return; }
        if (value != session.Current.CodexDelegationModel) await Change(p => p with { CodexDelegationModel = value });
    }

    private void RefreshCollaboration()
    {
        if (delegationEnabled == null || engine == null) return;
        var snapshot = engine.LatestSnapshot;
        var status = snapshot?.CodexDelegation;
        var current = session.Current;
        bool claude = snapshot?.Modules?.FirstOrDefault(module => module.Provider == "claude")?.Enabled == true;
        bool connected = !providerConnectionClosed && !engine.IsConnectionClosed && snapshot != null;
        bool editable = connected && claude && !busy && !session.RequiresRestart;
        delegationEnabled.IsChecked = current.CodexDelegation;
        delegationEnabled.IsEnabled = editable;
        delegationSections!.Visibility = current.CodexDelegation ? Visibility.Visible : Visibility.Collapsed;
        delegationCodex!.Text = ui.Text(status?.CodexFound == false ? "collaboration.codex_missing" : "collaboration.codex_found");
        delegationSkill!.Text = ui.Text(status?.SkillInstalled == true ? "collaboration.skill_installed"
            : current.CodexDelegation ? "collaboration.skill_waiting" : "collaboration.skill_off");
        delegationLegacy!.Visibility = status?.LegacySkill is null ? Visibility.Collapsed : Visibility.Visible;
        delegationLegacyPath!.Text = status?.LegacySkill ?? "";
        delegationLegacyRemove!.IsEnabled = editable;
        if (!delegationModel!.IsKeyboardFocusWithin) delegationModel.Text = current.CodexDelegationModel;
        delegationDisplay!.SelectedValue = current.CodexDelegationRows ? "rows" : "count";
        delegationEffort!.SelectedValue = current.CodexDelegationEffort;
        delegationFast!.SelectedValue = current.CodexDelegationFast;
        delegationAccess!.SelectedValue = current.CodexDelegationWrite ? "write" : "read";
        delegationTimeout!.SelectedValue = current.CodexDelegationTimeout.ToString();
        delegationConcurrency!.SelectedValue = current.CodexDelegationConcurrency.ToString();
        foreach (var editor in new Control[] { delegationModel, delegationDisplay, delegationEffort, delegationFast, delegationAccess, delegationTimeout, delegationConcurrency })
            editor.IsEnabled = editable;
        delegationWeek!.Text = status?.WeekText ?? "";
    }

    /// The earlier user-level skill goes to the Recycle Bin, where the user can
    /// restore it; only the exact folder the engine reported is touched.
    private void RemoveLegacySkill()
    {
        if (engine?.LatestSnapshot?.CodexDelegation?.LegacySkill is not { Length: > 0 } path) return;
        string full = Path.GetFullPath(path);
        string expected = Path.GetFullPath(Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), ".claude", "skills", "codex"));
        bool known = string.Equals(full, expected, StringComparison.OrdinalIgnoreCase) || Path.GetFileName(full.TrimEnd('\\', '/')) == "codex"
            && string.Equals(Path.GetFileName(Path.GetDirectoryName(full.TrimEnd('\\', '/'))), "skills", StringComparison.OrdinalIgnoreCase);
        if (!known || !Directory.Exists(full) || !RecycleBin.Send(full)) { ShowIssue("collaboration.legacy_failed"); return; }
        ClearIssue();
        delegationLegacy!.Visibility = Visibility.Collapsed;
    }
}

/// Moves a file or folder to the Recycle Bin without asking, so the user can restore it.
internal static class RecycleBin
{
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    private struct Operation
    {
        public IntPtr Window;
        public uint Function;
        public string From;
        public string? To;
        public ushort Flags;
        public int Aborted;
        public IntPtr Mappings;
        public string? Title;
    }
    [DllImport("shell32.dll", CharSet = CharSet.Unicode)]
    private static extern int SHFileOperationW(ref Operation operation);
    private const uint Delete = 3;
    private const ushort Silent = 0x0004, NoConfirmation = 0x0010, AllowUndo = 0x0040, NoErrorUI = 0x0400, NoConfirmMakeDirectory = 0x0200;
    internal static bool Send(string path)
    {
        var operation = new Operation { Function = Delete, From = path + "\0\0", Flags = Silent | NoConfirmation | AllowUndo | NoErrorUI | NoConfirmMakeDirectory };
        return SHFileOperationW(ref operation) == 0 && operation.Aborted == 0 && !Directory.Exists(path) && !File.Exists(path);
    }
}
