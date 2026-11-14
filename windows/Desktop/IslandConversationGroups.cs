using System;
using System.Collections.Generic;
using System.Linq;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Automation;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;

namespace CodexPacer.Windows;

public partial class IslandWindow
{
    private const string ConversationDragFormat = "PacerConversationGroup";
    private sealed record ConversationDrag(string Profile, string[] Members);
    private bool groupSavePending, conversationDragging;
    private string conversationStructure = "";
    private string ConversationStructure => string.Join("|", ConversationSections().Select(s => (s.Group?.Id ?? "") + ":" + s.Group?.Name + ":" + s.Group?.Collapsed + ":" + string.Join(",", s.Rows.Select(r => r.Id))));
    private ScrollViewer? conversationScroll;
    private readonly Dictionary<string, TaskRow> conversationControls = [];
    private bool UsesConversationGroups => compactPreferences.CodexPinnedOnly;
    private string ConversationProfile => compactPreferences.CodexHome.Trim().TrimEnd('\\', '/').ToUpperInvariant();
    private ConversationGroup[] SavedGroups => ConversationGroups.Read(compactPreferences.ConversationGroups).For(ConversationProfile);
    private string GroupText(string zh, string en) => chinese ? zh : en;
    private double ConversationHeight => Math.Min(360, Math.Max(44, ConversationSections().Sum(s => 32 + (s.Group?.Collapsed == true ? 0 : s.Rows.Length * (RowHeight + 2)))));
    private (ConversationGroup? Group, EngineTaskRow[] Rows)[] ConversationSections()
    {
        var remaining = rows.ToDictionary(r => r.Id);
        var result = new List<(ConversationGroup?, EngineTaskRow[])>();
        foreach (var group in SavedGroups)
        {
            var members = group.Members.Where(remaining.ContainsKey).Select(id => remaining[id]).ToArray();
            foreach (var member in members) remaining.Remove(member.Id);
            if (members.Length > 0) result.Add((group, members));
        }
        result.Add((null, remaining.Values.OrderBy(r => r.Id, StringComparer.Ordinal).ToArray()));
        return result.ToArray();
    }
    private async Task SaveGroups(Func<ConversationGroup[], ConversationGroup[]> edit)
    {
        if (groupSavePending || SaveIslandPlacement == null) return;
        groupSavePending = true;
        var profile = ConversationProfile;
        try
        {
            var result = await SaveIslandPlacement(previous => previous with {
                ConversationGroups = ConversationGroups.Read(previous.ConversationGroups).Update(profile,
                    edit(ConversationGroups.Read(previous.ConversationGroups).For(profile))) });
            if (result != PreferencesApplyResult.Applied) SetStatus(ui.Text("windows.settings.save_failed"));
            else { InvalidatePanel(true); Relayout(); }
        }
        finally { groupSavePending = false; }
    }
    private void ConversationDragSource(FrameworkElement control, Func<string[]> members)
    {
        Point? start = null;
        control.PreviewMouseLeftButtonDown += (_, e) => start = e.GetPosition(control);
        control.PreviewMouseMove += (_, e) => {
            if (start is not { } origin || e.LeftButton != MouseButtonState.Pressed || groupSavePending) return;
            var position = e.GetPosition(control);
            if (Math.Abs(position.X-origin.X) < SystemParameters.MinimumHorizontalDragDistance && Math.Abs(position.Y-origin.Y) < SystemParameters.MinimumVerticalDragDistance) return;
            start = null; conversationDragging = true; collapse.Stop();
            try { DragDrop.DoDragDrop(control, new DataObject(ConversationDragFormat, new ConversationDrag(ConversationProfile, members())), DragDropEffects.Move); }
            finally { conversationDragging = false; InvalidatePanel(true); }
            e.Handled = true;
        };
        control.PreviewMouseLeftButtonUp += (_, _) => start = null;
    }
    private void ConversationDropTarget(FrameworkElement control, string? group, string? row = null)
    {
        control.AllowDrop = true;
        ConversationDrag? Payload(DragEventArgs e) => e.Data.GetData(ConversationDragFormat) is ConversationDrag value && value.Profile == ConversationProfile && !groupSavePending ? value : null;
        control.DragOver += (_, e) => { e.Effects = Payload(e) != null ? DragDropEffects.Move : DragDropEffects.None; e.Handled = true;
            if (conversationScroll != null) { var y = e.GetPosition(conversationScroll).Y; if (y < 24) conversationScroll.ScrollToVerticalOffset(conversationScroll.VerticalOffset-12); else if (y > conversationScroll.ActualHeight-24) conversationScroll.ScrollToVerticalOffset(conversationScroll.VerticalOffset+12); } };
        control.Drop += async (_, e) => {
            var value = Payload(e); e.Handled = true;
            if (value == null || row != null && value.Members.Contains(row)) return;
            await SaveGroups(groups => {
                var destination = group;
                var members = value.Members;
                if (row != null && destination == null) { destination = Guid.NewGuid().ToString("N"); members = members.Append(row).ToArray(); }
                return ConversationGroups.Move(groups, members, destination, GroupText("新分组", "New group"));
            });
        };
    }
    private bool UpdateConversationRows()
    {
        if (conversationDragging) return true;
        if (conversationStructure != ConversationStructure) return false;
        var values = ConversationSections().Where(s => s.Group?.Collapsed != true).SelectMany(s => s.Rows).ToArray();
        if (!values.Select(r => r.Id).Order().SequenceEqual(conversationControls.Keys.Order())) return false;
        foreach (var value in values) { var control = conversationControls[value.Id]; control.Update(value, panelOptions); BindTaskAction(control); }
        return true;
    }
    private void BuildConversationGroups(StackPanel content, bool settled)
    {
        var offset = conversationScroll?.VerticalOffset ?? 0;
        conversationControls.Clear();
        conversationStructure = ConversationStructure;
        var list = new StackPanel();
        conversationScroll = new ScrollViewer { Content = list, Height = ConversationHeight, VerticalScrollBarVisibility = ScrollBarVisibility.Auto, HorizontalScrollBarVisibility = ScrollBarVisibility.Disabled };
        content.Children.Add(conversationScroll);
        AutomationProperties.SetAutomationId(conversationScroll, "island.conversations");
        foreach (var section in ConversationSections())
        {
            var group = section.Group;
            var heading = new StackPanel { Orientation = Orientation.Horizontal, Height = 32 };
            var toggle = new Button { Content = group?.Collapsed == true ? "›" : "⌄", Width = 26, Background = Brushes.Transparent, Foreground = PacerPalette.Secondary, BorderThickness = new Thickness(0) };
            toggle.IsEnabled = group != null;
            if (group != null) toggle.Click += async (_, _) => await SaveGroups(groups => groups.Select(g => g.Id == group.Id ? g with { Collapsed = !g.Collapsed } : g).ToArray());
            heading.Children.Add(toggle);
            var name = new Button { Content = (group?.Name ?? GroupText("未分组", "Ungrouped")) + "  " + section.Rows.Length, Background = Brushes.Transparent, Foreground = PacerPalette.Secondary, BorderThickness = new Thickness(0), Padding = new Thickness(5,0,5,0) };
            AutomationProperties.SetName(name, group == null ? GroupText("未分组", "Ungrouped") : GroupText("重命名分组 ", "Rename group ") + group.Name);
            heading.Children.Add(name); list.Children.Add(heading);
            ConversationDropTarget(heading, group?.Id);
            if (group != null)
            {
                ConversationDragSource(heading, () => group.Members);
                name.Click += (_, _) => {
                    var input = new TextBox { Text = group.Name, MaxLength = 64, Width = 200, VerticalContentAlignment = VerticalAlignment.Center };
                    heading.Children.Remove(name); heading.Children.Add(input); Activate(); input.Focus(); input.SelectAll();
                    bool finished = false;
                    async Task Finish(bool save) { if (finished) return; finished = true; var text = input.Text.Trim(); if (save && text.Length > 0) await SaveGroups(groups => groups.Select(g => g.Id == group.Id ? g with { Name = text } : g).ToArray()); else InvalidatePanel(true); }
                    input.KeyDown += async (_, e) => { if (e.Key is Key.Enter or Key.Escape) { e.Handled = true; await Finish(e.Key == Key.Enter); } };
                    input.LostKeyboardFocus += async (_, _) => await Finish(true);
                };
            }
            if (group?.Collapsed == true) continue;
            var body = new StackPanel();
            list.Children.Add(new Border { BorderBrush = PacerPalette.Secondary, BorderThickness = new Thickness(1,0,0,0), Margin = new Thickness(12,0,0,6), Padding = new Thickness(6,0,0,0), Child = body });
            foreach (var value in section.Rows)
            {
                var control = new TaskRow(value, panelOptions, settled) { Language = Language, Margin = new Thickness(0,0,0,2) };
                BindTaskAction(control); body.Children.Add(control); conversationControls[value.Id] = control;
                measuredRowsWidth = Math.Max(measuredRowsWidth, control.IdealWidth()+20);
                ConversationDragSource(control, () => [value.Id]); ConversationDropTarget(control, group?.Id, value.Id);
                var menu = new ContextMenu();
                foreach (var destination in SavedGroups.Select(g => (Id: (string?)g.Id, Name: g.Name)).Prepend((null, GroupText("未分组", "Ungrouped"))))
                {
                    var item = new MenuItem { Header = GroupText("移到 ", "Move to ") + destination.Name };
                    item.Click += async (_, _) => await SaveGroups(groups => ConversationGroups.Move(groups, [value.Id], destination.Id)); menu.Items.Add(item);
                }
                control.ContextMenu = menu;
            }
        }
        conversationScroll.ScrollToVerticalOffset(offset);
    }
}
