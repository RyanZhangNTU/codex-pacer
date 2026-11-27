using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Automation;
using System.Windows.Automation.Peers;
using System.Windows.Controls;
using System.Windows.Media;
using CodexPacer.Windows;

internal static class AntigravityPresentationChecks
{
    private const string Provider = "antigravity";
    private const string Prefix = "settings.antigravity.";

    internal static async Task Run(string language, bool dark, string output)
    {
        var ui = UiText.For(language == "zh-Hans");
        string root = Path.Combine(Path.GetTempPath(), "pacer-antigravity-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(root);
        var store = new PreferencesStore(Path.Combine(root, "preferences.json"));
        _ = store.Load();
        var initial = new DesktopPreferences { LastSettingsPane = "overview", MonitorSSH = false,
            ProviderModes = new() { ["codex"] = "disabled", ["claude"] = "disabled", ["deepseek"] = "disabled" } };
        Check(store.Save(initial), "The demo preferences must use the temporary profile");
        await using var engine = new EngineClient();
        await engine.StartAsync(Path.Combine(AppContext.BaseDirectory, "Engine/PacerEngine.exe"), true, language,
            configuration: initial.EngineConfiguration(), referenceFixture: true, demoAntigravity: true);
        EngineModule? Module() => engine.LatestSnapshot?.Modules?.FirstOrDefault(m => m.Provider == Provider);
        await PresentationWait.UntilAsync(() => Module()?.QuotaGroups != null, "The reference engine must advertise Antigravity's groups");
        var groups = Module()!.QuotaGroups!;
        var sample = engine.LatestSnapshot!;
        Check(Module() is { Enabled: true, Installed: true } && groups.Selected == "gemini" && groups.Options.Count == 2,
            "The demo must automatically enable the installed module with Gemini selected");
        var tasks = sample.Tasks.Where(t => t.Provider == Provider).ToArray();
        Check(tasks.Length == 4 && tasks.Any(t => t.ParentThreadId != null) && tasks.Any(t => t.TokensPerSecond > 0)
            && sample.Requests.Any(r => r.Provider == Provider), "The demo must include a child, a final rate and a pending approval");
        Check(ProviderIcon.Source(Provider) != null && ProviderIcon.Source(Provider, outline: true) != null,
            "The sidebar and launch button must have packaged Antigravity icons");
        var session = new PreferencesSession(initial, value => engine.SendAsync("configure", value), store.Save);
        Uri? website = null;
        var settings = new SettingsWindow(ui, session, new DemoStartupRegistration(), true, dark, engine,
            guideLinkLauncher: uri => { website = uri; return true; }) { ShowActivated = false };
        var island = new IslandWindow(engine, true, language == "zh-Hans", animationOverride: false) { ShowActivated = false, IsHitTestVisible = false };
        try
        {
            settings.Show(); island.Show(); island.ApplyPreferences(initial);
            await settings.NavigateAsync(Provider);
            await Wait(settings, Prefix + "group");
            var choice = Get<ComboBox>(settings, Prefix + "group");
            Check(Name(choice) == groups.Title && Equals(choice.SelectedValue, "gemini")
                && Texts(settings).Contains(ui.Text("harness.account.signed_in"))
                && Texts(settings).Any(t => t.Contains("66%")), "The account, weekly usage and group picker must match the reading");
            Check(Get<Button>(settings, Prefix + "open").IsVisible && Get<Button>(settings, Prefix + "refresh").IsEnabled,
                "The module must offer Open Antigravity and Refresh");
            Click(Get<Button>(settings, Prefix + "website"));
            Check(website?.AbsoluteUri == "https://antigravity.google/", "The module's website must use its descriptor URL");
            var guide = Module()!.ProgressGuide!;
            Check(guide.Stage == "allowTool" && guide.Steps.Count == 4 && guide.Steps[0].Title == ui.Text("progress_guide.plugin.restart")
                && guide.Steps[2].State == "current" && guide.Picture == "antigravityApproval",
                $"The guide must lead from restart and a new task to the permission card (stage {guide.Stage}, steps {guide.Steps.Count}, "
                + $"first '{guide.Steps.FirstOrDefault()?.Title}', third {guide.Steps.ElementAtOrDefault(2)?.State}, picture {guide.Picture})");
            await CheckGuideStates(settings, ui, guide);
            settings.CapturePreview(Path.Combine(output, $"antigravity-settings-{language}-{(dark ? "dark" : "light")}.png"));

            island.Reveal(); await island.SynchronizeExpansionAsync(); await island.WaitForPresentationAsync();
            await Wait(island, "quota.antigravity.group");
            Check(Name(Get<TextBlock>(island, "quota.antigravity.group")) == groups.Options[0].Label
                && Find<StackPanel>(island, "quota.antigravity.resetDetails") != null, "Gemini must show its group and reset details");
            choice.SelectedValue = "3p";
            await PresentationWait.UntilAsync(() => Module()?.QuotaGroups?.Selected == "3p"
                && session.Current.HarnessQuotaGroups.GetValueOrDefault(groups.DefaultsKey) == "3p",
                "Changing groups must reach the preferences session and the engine");
            Check(store.Load().Value.HarnessQuotaGroups.GetValueOrDefault(groups.DefaultsKey) == "3p", "The selected group must survive reloading preferences");
            string thirdParty = groups.Options.Single(g => g.Id == "3p").Label;
            await PresentationWait.UntilAsync(() => Find<TextBlock>(island, "quota.antigravity.group")?.Text == thirdParty, "The island must switch groups");
            Check(Find<StackPanel>(island, "quota.antigravity.resetDetails") == null && Texts(settings).Any(t => t.Contains("100%")),
                "A full group without a reset time must omit reset details and show full weekly usage");
            var withCompactQuota = await NativeCompactBar.Shared.EditAsync(session.Current, language, [Provider], new("show", "quota"));
            island.ApplyPreferences(withCompactQuota);
            await PresentationWait.UntilAsync(() => Find<Button>(island, "compact.row.quota") is { } slot &&
                UIElementAutomationPeer.CreatePeerForElement(slot)?.GetName().Contains(thirdParty) == true,
                "The rendered compact quota button must announce the selected group");
            var projection = await NativeCompactBar.Shared.ReadAsync(withCompactQuota, language, [Provider], engine.LatestSnapshot!.CompactContext);
            var quota = projection.Components.Single(c => c.Id == "quota");
            Check(quota.Help.Contains(thirdParty) && quota.Accessibility.Contains(thirdParty), "Compact help and accessibility must identify the selected group");

            await settings.NavigateAsync("collapsed"); settings.SelectCompactComponent("quota");
            await Wait(settings, "compact.window.antigravity");
            var window = Get<ComboBox>(settings, "compact.window.antigravity");
            Check(window.Items.Count == 3, "The compact quota window must offer automatic, five-hour and weekly readings");
            window.SelectedValue = "7d";
            await PresentationWait.UntilAsync(() => session.Current.ModuleWindows.GetValueOrDefault(Provider) == "7d", "The module must save its compact window");
            await settings.NavigateAsync("expandedPanel"); settings.SelectPanelBlock(Provider);
            await Wait(settings, "panel.option.antigravityPeriods.weekly");
            foreach (string style in new[] { "classic", "split" })
            {
                string id = "panel.option.antigravity.style." + style;
                await Wait(settings, id);
                Get<RadioButton>(settings, id).IsChecked = true;
                await PresentationWait.UntilAsync(() => session.Current.ExpandedQuotaStyle == style && Get<RadioButton>(settings, id).IsEnabled,
                    "The Antigravity block must save the selected quota style");
            }
            Get<RadioButton>(settings, "panel.option.antigravityPeriods.weekly").IsChecked = true;
            await PresentationWait.UntilAsync(() => session.Current.ExpandedPanelOptions?.Contains("weekly") == true, "The panel must save the module's periods");
            const string tile = "panel.block.antigravity.toggle";
            await PresentationWait.UntilAsync(() => Get<Button>(settings, tile) is { IsEnabled: true, Tag: "added" }, "Antigravity must start in the panel");
            Click(Get<Button>(settings, tile));
            await PresentationWait.UntilAsync(() => Get<Button>(settings, tile) is { IsEnabled: true, Tag: "add" }
                && !PresentationWait.Places(session.Current.ExpandedPanelLayout, Provider), "The editor must remove Antigravity");
            Click(Get<Button>(settings, tile));
            await PresentationWait.UntilAsync(() => Get<Button>(settings, tile) is { Tag: "added" }
                && PresentationWait.Places(session.Current.ExpandedPanelLayout, Provider), "The editor must add Antigravity");
            await settings.NavigateAsync("history");
            await Wait(settings, "quota.history.week.gemini");
            Check(Name(Get<TextBlock>(settings, "quota.history.week.gemini")).Contains(groups.Options[0].Label)
                && Name(Get<TextBlock>(settings, "quota.history.week.3p")).Contains(thirdParty),
                "History must keep both weekly groups when the selected group changes");
            settings.CapturePreview(Path.Combine(output, $"antigravity-history-{language}-{(dark ? "dark" : "light")}.png"));

            var reading = engine.LatestSnapshot!.QuotaDashboard!.Providers.Single(p => p.Provider == Provider);
            var weeks = reading.GroupWeeks!;
            var chart = weeks.Single(w => w.Id == "gemini").Chart;
            Check(chart != null && weeks.Single(w => w.Id == "3p").Chart == null, "Only a measured cycle can supply chart points");
            var history = new QuotaHistoryView(ui, PacerPalette.Provider(Provider), () => Task.CompletedTask);
            history.Update(reading.History, weeks.Select(w => w with { Chart = chart }).ToArray());
            Check(Descendants(history).OfType<QuotaHistoryChart>().Count() == 2, "Both measured weekly cycles must draw their own chart");

            await settings.NavigateAsync("modules");
            await Wait(settings, "settings.modules.antigravity");
            Check(Get<RadioButton>(settings, "settings.pane.antigravity").IsVisible, "An installed module belongs in the sidebar");
            await settings.NavigateAsync("help");
            await Wait(settings, "help.module.antigravity");
            Get<RadioButton>(settings, "help.module.antigravity").IsChecked = true;
            foreach (string topic in new[] { "tasks", "speed", "quota", "progress", "apps" })
                await Wait(settings, "help.antigravity." + topic);

            var catalog = await engine.QueryAsync<GuideCatalog>("guidePages", new { shell = new { guide =
                new GuideRequest("4.7.0", null, 4, language, true, false, true, false) } });
            var missing = sample with { Modules = [Module()! with { ApplicationInstalled = false }] };
            var welcome = new GuideContent(ui, session, new DemoStartupRegistration(), catalog, _ => { }, () => { },
                launch: uri => { website = uri; return true; }, snapshot: () => missing);
            var guideWindow = new GuideWindow(ui, welcome, catalog, dark) { ShowActivated = false };
            try
            {
                guideWindow.Show(); welcome.WelcomeStep(2); welcome.Refresh(); guideWindow.UpdateLayout();
                var get = Get<Button>(welcome, "welcome.module.antigravity.action");
                website = null; Click(get);
                Check(Name(get) == ui.Text("modules.get").Replace("%@", "Antigravity") && website?.AbsoluteUri == "https://antigravity.google/",
                    "Welcome must offer Get when a data folder remains without the app");
            }
            finally { guideWindow.Close(); }
            Console.WriteLine($"PASS Antigravity settings, plugin guide, island, History, Help and Welcome ({language}, {(dark ? "dark" : "light")})");
        }
        finally
        {
            settings.AllowClose = true; settings.Close();
            island.StopPresentation(); island.AllowClose = true; island.Close();
            Directory.Delete(root, true);
        }
    }

    private static readonly AntigravityApprovalCard EnglishCard = new("Permission", "Allow using this MCP tool?",
        "codex-pacer_pacer_progress/report_progress", "Yes, allow this time", "Yes, and always allow in this conversation",
        "Yes, and always allow", "Deny", "No", "(tell the agent what to do instead)", "Skip", "Submit");

    private static void CheckPicture(DependencyObject parent, AntigravityApprovalCard card)
    {
        var picture = Get<DecorativeBorder>(parent, "progress_approval.picture");
        var rows = Descendants(picture).OfType<Grid>().Where(row => AutomationProperties.GetAutomationId(row).StartsWith("progress_approval.row", StringComparison.Ordinal)).ToArray();
        var header = Descendants(picture).OfType<TextBlock>().Take(2).ToArray();
        Check(header.Length == 2 && header[0].Text == card.Title && header[0].FontWeight == FontWeights.Bold
            && header[1].Text == card.Resource && header[1].FontFamily.Source == "Consolas"
            && !Texts(picture).Any(text => text == card.Permission || text == card.Deny),
            "The card must open with its bold title and monospaced tool target");
        Check(rows.Length == 4 && rows[0].Parent is Panel group && group.Children.Cast<UIElement>().SequenceEqual(rows)
            && !Descendants(picture).OfType<Separator>().Any(), "The four rows must be consecutive, without separators");
        string[] choices = [card.Once, card.Conversation, card.Always, card.No];
        for (int index = 0; index < rows.Length; index++)
        {
            var row = rows[index];
            string digit = (index + 1).ToString(System.Globalization.CultureInfo.InvariantCulture);
            var labels = Descendants(row).OfType<TextBlock>().ToArray();
            string[] expected = index == 3 ? [digit, card.No, card.NoHint, card.Skip, card.Submit + " ↵"] : [digit, choices[index]];
            Check(AutomationProperties.GetAutomationId(row) == "progress_approval.row" + digit && labels.Select(label => label.Text).SequenceEqual(expected),
                "Each numbered choice must display the engine labels in order");
            Check(labels[0].Parent is Panel && labels[0].Background == null && labels[0].Foreground == row.FindResource("SettingsSecondary"),
                "Row numbers must be plain grey text");
            bool selected = index == 2;
            Check(labels[1].Foreground == row.FindResource(selected ? "SettingsPrimary" : "SettingsSecondary"),
                "Only the selected choice uses primary text");
            var fill = row.Children.OfType<Border>().SingleOrDefault(border => border.Background != null);
            var ring = Find<Border>(row, "progress_approval.ring");
            Check(selected ? fill is { CornerRadius.TopLeft: > 0 } && fill.Background == row.FindResource("SettingsTileStroke")
                && ring?.RenderSize == row.RenderSize : fill == null && ring == null,
                "Only row 3 must have a rounded fill and a ring around the whole row");
        }
        var last = rows[3];
        var hint = Descendants(last).OfType<TextBlock>().Single(label => label.Text == card.NoHint);
        var skip = Descendants(last).OfType<TextBlock>().Single(label => label.Text == card.Skip);
        var submit = Get<Border>(last, "progress_approval.submit");
        var submitRing = Get<Border>(last, "progress_approval.submit_ring");
        var mic = Descendants(last).OfType<System.Windows.Shapes.Path>().Single();
        Rect Bounds(FrameworkElement element) => new(element.TranslatePoint(new Point(), last), element.RenderSize);
        var no = Descendants(last).OfType<TextBlock>().Single(label => label.Text == card.No);
        Rect[] parts = [Bounds(no), Bounds(hint), Bounds(mic), Bounds(skip), Bounds(submit)];
        double centerY = last.ActualHeight / 2;
        Check(hint.Opacity < skip.Opacity && parts.All(part => part.Width > 0 && part.Top <= centerY && centerY <= part.Bottom)
            && parts.Zip(parts.Skip(1)).All(pair => pair.First.Right <= pair.Second.Left),
            "No, its muted hint, the microphone, Skip and Submit must share the last line in that order");
        var submitBounds = Bounds(submit);
        var ringBounds = Bounds(submitRing);
        Check(Texts(submit).Single() == card.Submit + " ↵" && submit.CornerRadius.TopLeft >= submit.ActualHeight / 2
            && ringBounds.Contains(submitBounds) && Rect.Inflate(submitBounds, 3, 3).Contains(ringBounds)
            && submitRing.Style == Get<Border>(rows[2], "progress_approval.ring").Style
            && Descendants(picture).OfType<Border>().Count(border => border.Style == picture.FindResource("ApprovalPictureRing")) == 2,
            "The second ring must surround just the Submit capsule");
        Check(!picture.Focusable && !picture.IsHitTestVisible && !Descendants(picture).OfType<UIElement>().Any(element => element.Focusable)
            && !Descendants(picture).OfType<System.Windows.Controls.Primitives.ButtonBase>().Any(), "The illustration must be decorative");
    }

    private static HarnessProgressGuide ConversationGuide(UiText ui, HarnessProgressGuide guide, string stage)
    {
        string title = ui.Text(stage == "conversationMissedTool" ? "progress_guide.plugin.conversation_missed_tool" : "progress_guide.plugin.conversation");
        return guide with { Stage = stage, FloatTitle = title, FloatNext = null, FloatPicture = null, Example = ui.Text("progress_guide.plugin.example"),
            Steps = guide.Steps.Select((step, i) => i == 1 ? step with { Title = title, State = "current" }
                : step with { State = i == 0 ? "done" : "pending" }).ToArray() };
    }

    private static async Task CheckGuideStates(SettingsWindow settings, UiText ui, HarnessProgressGuide guide)
    {
        var card = guide.ApprovalCard ?? throw new InvalidOperationException("Missing approval card");
        Check(card == EnglishCard, "Antigravity's permission prompt uses the same English labels in both languages");
        foreach (var (stage, index) in new[] { ("restartForPlugin", 0), ("newConversation", 1), ("conversationMissedTool", 1), ("allowTool", 2) })
        {
            var state = index == 1 ? ConversationGuide(ui, guide, stage) : guide with { Stage = stage,
                Steps = guide.Steps.Select((step, i) => step with { State = i < index ? "done" : i == index ? "current" : "pending" }).ToArray() };
            var steps = state.Steps;
            settings.RefreshHarnessProgressGuide(Provider, state, true);
            settings.UpdateLayout();
            var current = Get<Grid>(settings, Prefix + "progress_step" + index);
            Check(Name(current) == steps[index].Title && AutomationProperties.GetItemStatus(current) == ui.Text("progress_guide.state.current"),
                "The current plugin step must have a localized accessible state");
            CheckPicture(current, card);
            if (index == 2) Check(steps[index].Title.Contains(card.Submit, StringComparison.Ordinal) && !string.IsNullOrEmpty(steps[index].Detail),
                "The approval step must mention Submit and explain the grant");
            var detail = Find<TextBlock>(current, Prefix + "progress_detail");
            Check(detail?.Text == steps[index].Detail && (detail == null || detail.TextWrapping == TextWrapping.Wrap),
                "The current step must show its complete, wrapping detail");
            if (index == 1)
            {
                var box = Descendants(settings).OfType<ProgressGuideExample>().Single();
                Check(steps[index].Detail == null && detail == null && box.Parent is StackPanel body
                    && body.Children[0] is TextBlock title && title.Text == state.FloatTitle && body.Children[1] == box,
                    "The conversation title must be followed by the example, with no detail");
                await CheckCopy(box, ui, ui.Text("progress_guide.plugin.example"));
            }
            else CheckNoExample(settings, stage);
            Check(Descendants(settings).OfType<DecorativeBorder>().Count(x => AutomationProperties.GetAutomationId(x) == "progress_approval.picture") == 1,
                "Only the current step may have a picture");
        }
        foreach (var stage in new[] { "adding", "turnedOff", "conflict", "failed", "ready", "removalPending", "cleanupFailed" })
        {
            bool preview = stage is "adding" or "turnedOff" or "conflict" or "failed";
            string? line = stage switch { "adding" => null, "ready" => ui.Text("progress_guide.plugin.report"),
                "removalPending" => ui.Text("progress_guide.plugin.quit"), _ => stage };
            settings.RefreshHarnessProgressGuide(Provider, guide with { Stage = stage, Steps = [], Line = line,
                Picture = preview ? "antigravityApproval" : null, FloatPicture = null, ApprovalCard = preview ? card : null,
                Action = stage == "removalPending" ? "retry" : null, ActionTitle = ui.Text("progress_guide.action.retry") }, true);
            settings.UpdateLayout();
            var body = Get<StackPanel>(settings, Prefix + "progress_guide");
            CheckNoExample(body, stage);
            Check((Find<DecorativeBorder>(body, "progress_approval.picture") != null) == preview, "Settings must follow Core's picture for " + stage);
            if (preview) CheckPicture(body, card);
            if (line != null)
            {
                var message = Get<TextBlock>(body, Prefix + "progress_line");
                Check(message.Text == line, "The guide must show the status or recovery instruction");
                var picture = preview ? Get<DecorativeBorder>(body, "progress_approval.picture") : null;
                if (picture != null) Check(((StackPanel)message.Parent).Children[1] is var below && (below == picture || below is Grid holder && holder.Children.Contains(picture)),
                    "The recovery picture belongs directly below its instruction");
                // As on the Mac, it starts at the left edge rather than centering.
                if (picture != null) Check(picture.TranslatePoint(new Point(0, 0), message).X <= 0.5, "The picture must line up with its instruction");
            }
            if (stage == "removalPending") Check(Get<Button>(body, Prefix + "progress_action").IsVisible, "Pending removal must offer a retry");
        }
        settings.RefreshHarnessProgressGuide(Provider, guide, true);
    }

    private static void CheckNoExample(DependencyObject root, string stage) =>
        Check(Find<TextBlock>(root, "progress_guide.example") == null && Find<Button>(root, "progress_guide.example.copy") == null,
            "Unexpected example or Copy button during " + stage);

    private static async Task CheckCopy(ProgressGuideExample box, UiText ui, string expected)
    {
        var text = Get<TextBlock>(box, "progress_guide.example");
        var button = Get<Button>(box, "progress_guide.example.copy");
        string copy = ui.Text("progress_guide.action.copy"), copied = ui.Text("support.share.copied");
        bool LabelIs(string label) => Name(button) == label && UIElementAutomationPeer.CreatePeerForElement(button)?.GetName() == label
            && Descendants(button).OfType<TextBlock>().Single(t => t.IsVisible).Text == label;
        Check(text.IsVisible && text.Text == expected && text.TextWrapping == TextWrapping.Wrap && LabelIs(copy),
            "The prompt and the accessible Copy button must match the guide language");
        double width = text.ActualWidth;
        box.WriteClipboard = _ => false;
        Click(button);
        Check(LabelIs(copy), "A failed copy must keep the Copy label");
        string? written = null;
        box.WriteClipboard = value => { written = value; return true; };
        box.FeedbackDuration = TimeSpan.Zero;
        Click(button);
        box.UpdateLayout();
        Check(written == expected && LabelIs(copied) && text.ActualWidth == width,
            "Copy must write the entire prompt and announce Copied without rewrapping the text");
        await PresentationWait.UntilAsync(() => LabelIs(copy), "Copy must return after its feedback expires");
    }

    // Exercise both WPF surfaces with an in-memory module and no engine or provider process.
    internal static async Task RunGuideFixtures(string language, bool dark)
    {
        var ui = UiText.For(language == "zh-Hans");
        string allow = ui.Text("progress_guide.plugin.allow").Replace("%1$@", EnglishCard.Title).Replace("%2$@", EnglishCard.Always).Replace("%3$@", EnglishCard.Submit);
        string choose = ui.Text("progress_guide.plugin.choose").Replace("%1$@", EnglishCard.Always).Replace("%2$@", EnglishCard.Submit);
        var steps = new HarnessProgressStep[] { new("Restart", "done"), new("New conversation", "done"),
            new(allow, "current", "Why Antigravity asks.\nWhen it asks again."), new("Ready", "pending") };
        var guide = new HarnessProgressGuide("allowTool", "Setup", "attention", steps, null, null, null, true, null, true, "",
            Picture: "antigravityApproval", FloatTitle: choose, FloatNext: steps[2].Detail,
            FloatPicture: "antigravityApproval", ApprovalCard: EnglishCard);
        var module = new EngineModule(Provider, "enabled", true, true, ProgressConnector: true, ProgressGuide: guide);
        var conversation = ConversationGuide(ui, guide, "newConversation");
        var session = new PreferencesSession(new DesktopPreferences(), _ => Task.CompletedTask, _ => true);
        var settings = new SettingsWindow(ui, session, new DemoStartupRegistration(), true, dark) { ShowActivated = false };
        var area = new System.Drawing.Rectangle(0, 0, 1280, 900);
        var pending = new PendingGuideFloat("Restarting the app", "Start a new conversation");
        var floating = new HarnessGuideFloat(Provider, ui, HarnessGuideFloat.StandaloneResources(dark, null, null), !dark, area, pending);
        try
        {
            settings.Content = settings.BuildHarnessProgressRow(Provider, "settings." + Provider, module);
            settings.Show();
            await CheckGuideStates(settings, ui, guide);
            await ProviderHomeSettingsChecks.CheckGuideFloat(settings, ui, !dark);
            settings.AllowClose = true; settings.Close();
            var starting = module with { ProgressGuide = conversation };
            floating.Update(starting, true, DateTime.UtcNow);
            CheckNoExample(floating, "pending restart");
            Check(Get<TextBlock>(floating, "guide_float.title").Text == pending.Title && Get<TextBlock>(floating, "guide_float.next").Text == pending.Next
                && Find<DecorativeBorder>(floating, "progress_approval.picture") == null, "The restart must keep its pending instruction until the app returns");
            floating.Update(starting, false, DateTime.UtcNow);
            floating.UpdateLayout();
            await ProviderHomeSettingsChecks.CheckGuideFloatExample(floating, ui, ui.Text("progress_guide.plugin.conversation"));
            floating.Present(guide with { FloatPicture = null });
            CheckNoExample(floating, guide.Stage);
            Check(Find<DecorativeBorder>(floating, "progress_approval.picture") == null, "The float must ignore the Settings preview");
            floating.Present(guide with { Picture = null });
            floating.UpdateLayout();
            CheckPicture(floating, EnglishCard);
            Check(!floating.ShowActivated && !floating.IsActive, "The approval guide must leave the foreground app active");
            Check(Get<TextBlock>(floating, "guide_float.title").Text == choose, "The float must display the instruction to select and submit");
            var picture = Get<DecorativeBorder>(floating, "progress_approval.picture");
            Border[] rings = [Get<Border>(picture, "progress_approval.ring"), Get<Border>(picture, "progress_approval.submit_ring")];
            picture.Resources[SystemParameters.ClientAreaAnimationKey] = true;
            await PresentationWait.UntilAsync(() => rings.All(ring => ring.Opacity < 0.98), "Both rings must pulse with animations enabled");
            picture.Resources[SystemParameters.ClientAreaAnimationKey] = false;
            await PresentationWait.UntilAsync(() => rings.All(ring => !ring.IsEnabled && !ring.HasAnimatedProperties && ring.Opacity == 1),
                "Reduced motion must leave both rings visible and still");
            floating.Update(module with { ProgressGuide = ConversationGuide(ui, guide, "conversationMissedTool") }, false, DateTime.UtcNow);
            floating.UpdateLayout();
            await ProviderHomeSettingsChecks.CheckGuideFloatExample(floating, ui, ui.Text("progress_guide.plugin.conversation_missed_tool"));
            var ready = module with { ProgressGuide = guide with { Stage = "ready", FloatTitle = ui.Text("progress_guide.plugin.report"),
                FloatNext = null, FloatPicture = null }, ProgressApprovals = ["still-pending"] };
            var now = DateTime.UtcNow;
            floating.Update(ready, false, now);
            floating.UpdateLayout();
            CheckNoExample(floating, "ready");
            Check(Find<DecorativeBorder>(floating, "progress_approval.picture") == null
                && Get<TextBlock>(floating, "guide_float.title").Text == ready.ProgressGuide.FloatTitle,
                "The ready message replaces the permission card even with a pending ID");
            floating.Update(ready, false, now.AddSeconds(7.9));
            Check(floating.IsVisible, "The ready message must remain visible for eight seconds");
            floating.Update(ready, false, now.AddSeconds(8));
            Check(!floating.IsVisible, "The float must close after eight seconds at ready");
            Console.WriteLine($"PASS Antigravity guide pictures and steps ({language}, {(dark ? "dark" : "light")})");
        }
        finally { if (floating.IsVisible) floating.Close(); if (settings.IsVisible) { settings.AllowClose = true; settings.Close(); } }
    }

    private static void Click(Button button) => button.RaiseEvent(new RoutedEventArgs(Button.ClickEvent));
    private static string Name(DependencyObject element) => AutomationProperties.GetName(element);
    private static Task Wait(DependencyObject root, string id) => PresentationWait.UntilAsync(
        () => Find<FrameworkElement>(root, id)?.IsVisible == true, "Expected visible control " + id);
    private static T Get<T>(DependencyObject root, string id) where T : FrameworkElement =>
        Find<T>(root, id) ?? throw new InvalidOperationException("Missing " + id);
    private static T? Find<T>(DependencyObject root, string id) where T : FrameworkElement =>
        Descendants(root).OfType<T>().FirstOrDefault(x => AutomationProperties.GetAutomationId(x) == id);
    private static IEnumerable<string> Texts(DependencyObject root) => Descendants(root).OfType<TextBlock>().Select(t => t.Text);
    private static IEnumerable<DependencyObject> Descendants(DependencyObject root)
    {
        for (int i = 0; i < VisualTreeHelper.GetChildrenCount(root); i++)
        {
            var child = VisualTreeHelper.GetChild(root, i); yield return child;
            foreach (var nested in Descendants(child)) yield return nested;
        }
    }
    private static void Check(bool valid, string message) { if (!valid) throw new InvalidOperationException(message); }
}
