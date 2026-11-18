using System;
using System.Collections.Generic;
using System.Linq;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Automation;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;
using System.Windows.Input;
using System.Windows.Media;

namespace CodexPacer.Windows;

public partial class IslandWindow
{
    private const string ConversationDragFormat = "PacerConversationGroup";
    private sealed record ConversationDrag(string Profile, string[] Members, string? Group);
    private ConversationDrag? activeConversationDrag;
    private string? conversationDragToken;
    private bool groupSavePending, conversationDragging, conversationRenaming;
    private string conversationStructure = "";
    private string ConversationStructure => string.Join("|", ConversationSections().Select(s => (s.Group?.Id ?? "") + ":" + s.Group?.Name + ":" + s.Group?.Collapsed + ":" + string.Join(",", s.Rows.Select(r => r.Id))));
    private ScrollViewer? conversationScroll;
    private readonly Dictionary<string, TaskRow> conversationControls = [];
    private readonly Dictionary<string, Border> conversationGroupIndicators = [];
    private Border? conversationDropIndicator;
    private ToolTip? conversationDropHint;
    private bool viewingPinnedChats = true;
    private bool HasPinnedView => compactPreferences.ShowPinnedConversations && latest?.PinnedConversations != null;
    private bool UsesConversationGroups => viewingPinnedChats && HasPinnedView;
    private string ConversationProfile => latest?.PinnedConversations?.Profile ?? "";
    private IReadOnlyList<EngineTaskRow> DisplayRows(EnginePresentation presentation) =>
        UsesConversationGroups ? latest!.PinnedConversations!.Rows : presentation.Rows;
    private void OnSwitchConversationView(object sender, RoutedEventArgs e)
    {
        if (!HasPinnedView || conversationDragging || conversationRenaming || latest == null) return;
        viewingPinnedChats = !viewingPinnedChats;
        panelDirty = true;
        Render(latest);
    }
    private void UpdateConversationSwitch()
    {
        SwitchConversationView.Visibility = HasPinnedView ? Visibility.Visible : Visibility.Collapsed;
        if (!HasPinnedView) return;
        string label = ui.Text(UsesConversationGroups ? "windows.conversation_groups.all_tasks" : "windows.conversation_groups.title");
        SwitchConversationView.Content = label;
        AutomationProperties.SetName(SwitchConversationView, label);
    }
    private ConversationGroup[] SavedGroups => ConversationGroups.Read(compactPreferences.ConversationGroups).For(ConversationProfile);
    private double ConversationHeight => Math.Min(360, Math.Max(44, ConversationSections().Sum(s => 32 + (s.Group?.Collapsed == true ? 0 : s.Rows.Length * (RowHeight + 2)))));
    private (ConversationGroup? Group, EngineTaskRow[] Rows)[] ConversationSections() => ConversationGroups.Sections(SavedGroups, rows);
    private async Task SaveGroups(Func<ConversationGroup[], ConversationGroup[]> edit)
    {
        if (!UsesConversationGroups || groupSavePending || SaveIslandPlacement == null) return;
        groupSavePending = true;
        var profile = ConversationProfile;
        try
        {
            var result = await SaveIslandPlacement(previous => {
                if (!previous.ShowPinnedConversations || profile != ConversationProfile) return previous;
                var stored = ConversationGroups.Read(previous.ConversationGroups);
                return previous with { ConversationGroups = stored.Update(profile, edit(stored.For(profile))) };
            });
            if (result != PreferencesApplyResult.Applied) SetStatus(ui.Text("windows.settings.save_failed"));
            else { InvalidatePanel(true); Relayout(); }
        }
        catch (InvalidOperationException) { SetStatus(ui.Text("windows.settings.save_failed")); }
        finally { groupSavePending = false; }
    }
    private void ClearConversationDropFeedback(bool closeHint = true)
    {
        if (conversationDropIndicator != null) conversationDropIndicator.Visibility = Visibility.Collapsed;
        conversationDropIndicator = null;
        if (closeHint && conversationDropHint != null) conversationDropHint.IsOpen = false;
    }
    private void ConversationDragSource(FrameworkElement control, Func<string[]> members, string? group = null)
    {
        Point? start = null;
        control.PreviewMouseLeftButtonDown += (_, e) => start = e.GetPosition(control);
        control.PreviewMouseMove += (_, e) => {
            if (start is not { } origin || e.LeftButton != MouseButtonState.Pressed || groupSavePending) return;
            var position = e.GetPosition(control);
            if (Math.Abs(position.X-origin.X) < SystemParameters.MinimumHorizontalDragDistance && Math.Abs(position.Y-origin.Y) < SystemParameters.MinimumVerticalDragDistance) return;
            start = null; conversationDragging = true; collapse.Stop();
            activeConversationDrag = new ConversationDrag(ConversationProfile, members(), group);
            conversationDragToken = Guid.NewGuid().ToString("N");
            try { DragDrop.DoDragDrop(control, new DataObject(ConversationDragFormat, conversationDragToken), DragDropEffects.Move); }
            finally { ClearConversationDropFeedback(); activeConversationDrag = null; conversationDragToken = null; conversationDragging = false; InvalidatePanel(true); }
            e.Handled = true;
        };
        control.PreviewMouseLeftButtonUp += (_, _) => start = null;
    }
    private void ConversationDropTarget(FrameworkElement control, string? group, string? row = null)
    {
        control.AllowDrop = true;
        control.DragLeave += (_, _) => { control.Opacity = 1; ClearConversationDropFeedback(); };
        ConversationDrag? Payload(DragEventArgs e) => activeConversationDrag is { } value && value.Profile == ConversationProfile &&
            e.Data.GetData(ConversationDragFormat) is string token && token == conversationDragToken && !groupSavePending ? value : null;
        bool Merge(DragEventArgs e) => (e.KeyStates & DragDropKeyStates.ShiftKey) != 0;
        bool After(DragEventArgs e) => group != null && (row != null || e.GetPosition(control).Y >= control.ActualHeight / 2);
        bool Allowed(ConversationDrag? value, DragEventArgs e) => value != null &&
            (value.Group != null ? value.Group != group && (!Merge(e) || group != null) : row == null || !value.Members.Contains(row));
        control.DragOver += (_, e) => {
            var value = Payload(e);
            var allowed = Allowed(value, e);
            e.Effects = allowed ? DragDropEffects.Move : DragDropEffects.None; e.Handled = true;
            ClearConversationDropFeedback(!allowed || value?.Group == null);
            control.Opacity = allowed && value?.Group == null ? 0.65 : 1;
            if (allowed && value?.Group != null && conversationGroupIndicators.TryGetValue(group ?? "", out var indicator))
            {
                conversationDropIndicator = indicator;
                indicator.BorderThickness = Merge(e) ? new Thickness(1) : After(e) ? new Thickness(0,0,0,2) : new Thickness(0,2,0,0);
                indicator.Visibility = Visibility.Visible;
                conversationDropHint ??= new ToolTip { Placement = PlacementMode.Right, StaysOpen = true, IsHitTestVisible = false };
                conversationDropHint.PlacementTarget = control;
                conversationDropHint.Content = ui.Text(Merge(e) ? "windows.conversation_groups.merge_hint" : "windows.conversation_groups.reorder_hint");
                conversationDropHint.IsOpen = true;
            }
            if (conversationScroll != null) { var y = e.GetPosition(conversationScroll).Y; if (y < 24) conversationScroll.ScrollToVerticalOffset(conversationScroll.VerticalOffset-12); else if (y > conversationScroll.ActualHeight-24) conversationScroll.ScrollToVerticalOffset(conversationScroll.VerticalOffset+12); } };
        control.Drop += async (_, e) => {
            control.Opacity = 1; ClearConversationDropFeedback();
            var value = Payload(e); e.Handled = true;
            if (value == null || !Allowed(value, e)) return;
            if (value.Group is { } source)
            {
                var after = After(e); var merge = Merge(e);
                await SaveGroups(groups => ConversationGroups.DropGroup(groups, source, group, after, merge));
                return;
            }
            await SaveGroups(groups => {
                var destination = group;
                var members = value.Members;
                if (row != null && destination == null) { destination = Guid.NewGuid().ToString("N"); members = members.Append(row).ToArray(); }
                return ConversationGroups.Move(groups, members, destination, ui.Text("windows.conversation_groups.new"));
            });
        };
    }
    private bool UpdateConversationRows()
    {
        if (conversationDragging || conversationRenaming) return true;
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
        ClearConversationDropFeedback(); conversationGroupIndicators.Clear();
        conversationStructure = ConversationStructure;
        var list = new StackPanel();
        conversationScroll = new ScrollViewer { Content = list, Height = ConversationHeight, VerticalScrollBarVisibility = ScrollBarVisibility.Auto, HorizontalScrollBarVisibility = ScrollBarVisibility.Disabled };
        content.Children.Add(conversationScroll);
        AutomationProperties.SetAutomationId(conversationScroll, "island.conversations");
        var savedGroups = SavedGroups;
        foreach (var section in ConversationGroups.Sections(savedGroups, rows))
        {
            var group = section.Group;
            var heading = new StackPanel { Orientation = Orientation.Horizontal, Height = 32 };
            var toggle = new Button { Content = group?.Collapsed == true ? "›" : "⌄", Width = 26, Background = Brushes.Transparent, Foreground = PacerPalette.Secondary, BorderThickness = new Thickness(0) };
            toggle.IsEnabled = group != null;
            if (group != null) toggle.Click += async (_, _) => await SaveGroups(groups => groups.Select(g => g.Id == group.Id ? g with { Collapsed = !g.Collapsed } : g).ToArray());
            AutomationProperties.SetAutomationId(toggle, "island.group.toggle." + (group?.Id ?? "ungrouped"));
            heading.Children.Add(toggle);
            var name = new Button { Content = (group?.Name ?? ui.Text("windows.conversation_groups.ungrouped")) + "  " + section.Rows.Length, Background = Brushes.Transparent, Foreground = PacerPalette.Secondary, BorderThickness = new Thickness(0), Padding = new Thickness(5,0,5,0) };
            AutomationProperties.SetName(name, group == null ? ui.Text("windows.conversation_groups.ungrouped") : string.Format(ui.Text("windows.conversation_groups.rename"), group.Name));
            var headingHost = new Grid { Height = 32, Background = Brushes.Transparent };
            var indicator = new Border { BorderBrush = SystemColors.HighlightBrush, Visibility = Visibility.Collapsed, IsHitTestVisible = false };
            conversationGroupIndicators[group?.Id ?? ""] = indicator;
            heading.Children.Add(name); headingHost.Children.Add(heading); headingHost.Children.Add(indicator); list.Children.Add(headingHost);
            AutomationProperties.SetAutomationId(headingHost, "island.group.header." + (group?.Id ?? "ungrouped"));
            ConversationDropTarget(headingHost, group?.Id);
            if (group != null)
            {
                headingHost.ToolTip = ui.Text("windows.conversation_groups.drag_help");
                ConversationDragSource(headingHost, () => group.Members, group.Id);
                name.Click += (_, _) => {
                    conversationRenaming = true; collapse.Stop();
                    var input = new TextBox { Text = group.Name, MaxLength = 64, Width = 200, VerticalContentAlignment = VerticalAlignment.Center };
                    heading.Children.Remove(name); heading.Children.Add(input); Activate(); input.Focus(); input.SelectAll();
                    bool finished = false;
                    async Task Finish(bool save) { if (finished) return; finished = true; conversationRenaming = false; var text = input.Text.Trim(); if (save && text.Length > 0) await SaveGroups(groups => groups.Select(g => g.Id == group.Id ? g with { Name = text } : g).ToArray()); else InvalidatePanel(true); }
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
                menu.Opened += (_, _) => {
                    menu.Items.Clear();
                    foreach (var destination in savedGroups.Select(g => (Id: (string?)g.Id, Name: g.Name)).Prepend((null, ui.Text("windows.conversation_groups.ungrouped"))))
                    {
                        var item = new MenuItem { Header = string.Format(ui.Text("windows.conversation_groups.move"), destination.Name) };
                        item.Click += async (_, _) => await SaveGroups(groups => ConversationGroups.Move(groups, [value.Id], destination.Id)); menu.Items.Add(item);
                    }
                };
                // WPF only opens a menu that initially has an item.
                menu.Items.Add(new MenuItem());
                control.ContextMenu = menu;
            }
        }
        conversationScroll.ScrollToVerticalOffset(offset);
    }
}
