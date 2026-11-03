using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Linq;
using System.Text.Json;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using System.Windows.Threading;
using CodexPacer.Windows;

internal static class TypographyLocaleChecks
{
    internal static async Task Run(string output)
    {
        CultureInfo previousCulture = CultureInfo.CurrentCulture, previousUi = CultureInfo.CurrentUICulture;
        var evidence = new List<object>(); var widths = new Dictionary<string, double[]>();
        try
        {
            foreach (string language in new[] { "en", "zh-Hans" })
                foreach (string host in new[] { "en-US", "ja-JP" })
                {
                    CultureInfo.CurrentCulture = CultureInfo.CurrentUICulture = CultureInfo.GetCultureInfo(host);
                    var ui = UiText.For(language == "zh-Hans"); var engine = new EngineClient();
                    var preferences = new DesktopPreferences { IslandAppearance = "classic", LastSettingsPane = "collapsed",
                        ProviderModes = new() { ["codex"] = "enabled", ["claude"] = "enabled", ["deepseek"] = "enabled" } };
                    var session = new PreferencesSession(preferences, _ => Task.CompletedTask, _ => true);
                    var island = new IslandWindow(engine, true, language == "zh-Hans", animationOverride: false)
                        { IsHitTestVisible = false, ShowActivated = false };
                    var settings = new SettingsWindow(ui, session, new Startup(), true, false, engine)
                        { IsHitTestVisible = false, ShowActivated = false };
                    string name = language + "-host-" + host;
                    try
                    {
                        island.ApplyPreferences(preferences); island.Show(); settings.Show();
                        await engine.StartAsync(Path.Combine(AppContext.BaseDirectory, "Engine/PacerEngine.exe"), true, language,
                            configuration: preferences.EngineConfiguration(), referenceFixture: true);
                        island.Reveal(); await island.WaitForPresentationAsync();
                        await Application.Current.Dispatcher.InvokeAsync(() => { }, DispatcherPriority.ApplicationIdle);
                        settings.CapturePreview(Path.Combine(output, "typography-" + name + "-settings.png"));
                        island.CapturePreview(Path.Combine(output, "typography-" + name + "-island.png"));
                        string expected = language == "zh-Hans" ? "zh-Hans" : "en-US";
                        Check(settings.Language.IetfLanguageTag.Equals(expected, StringComparison.OrdinalIgnoreCase) &&
                            island.Language.IetfLanguageTag.Equals(expected, StringComparison.OrdinalIgnoreCase), "Both actual windows must use their selected UI language");
                        var text = Descendants(settings.ClientContent).OfType<TextBlock>()
                            .Single(value => value.Text == ui.Text("settings.pane.collapsed") && value.FontSize == 20);
                        Check(text.Language == settings.Language, "The actual heading must inherit its window's rendering language");
                        var heading = Glyphs(text).ToArray();
                        Check(heading.Length > 0, "The heading must have rendered glyphs, not only a declared typeface");
                        var settingsGlyphs = Glyphs(settings.ClientContent).ToArray();
                        var islandGlyphs = Glyphs(island).ToArray();
                        Validate(settingsGlyphs, language); Validate(islandGlyphs, language);
                        if (language == "zh-Hans") Check(heading.Any(run => Han(run)) && islandGlyphs.Any(run => Han(run)), "Chinese coverage requires actual Han glyphs in both windows");
                        var rows = Descendants(island).OfType<TaskRow>().ToArray();
                        Check(rows.Length > 0 && rows.All(row => row.Language == island.Language), "Task rows must receive their language before natural-width measurement");
                        double[] ideal = rows.Select(row => row.IdealWidth()).ToArray();
                        if (widths.TryGetValue(language, out var prior)) Check(prior.Length == ideal.Length && prior.Zip(ideal).All(pair => Math.Abs(pair.First - pair.Second) < .01),
                            "Changing the machine culture cannot change a task row's UI-language width");
                        else widths[language] = ideal;
                        Check(CultureInfo.CurrentCulture.Name == host && CultureInfo.CurrentUICulture.Name == host, "Rendering language cannot overwrite the user's numeric or system UI culture");
                        evidence.Add(new { language, hostCulture = host, renderingLanguage = settings.Language.IetfLanguageTag,
                            taskIdealWidths = ideal, heading = Describe(heading), settings = Describe(settingsGlyphs), island = Describe(islandGlyphs) });
                    }
                    finally { await engine.DisposeAsync(); settings.AllowClose = true; settings.Close(); island.AllowClose = true; island.Close(); }
                }
        }
        finally { CultureInfo.CurrentCulture = previousCulture; CultureInfo.CurrentUICulture = previousUi; }
        File.WriteAllText(Path.Combine(output, "typography-language.json"), JsonSerializer.Serialize(evidence, new JsonSerializerOptions { WriteIndented = true }));
        Console.WriteLine("PASS rendered language: actual Settings, task and vector glyphs use the selected UI language under English/Japanese host cultures; Latin font bytes and task widths remain stable");
    }
    private static void Validate(GlyphRun[] glyphs, string language)
    {
        Check(glyphs.Length > 0, "A font check requires real rendered glyph runs");
        foreach (var run in glyphs)
        {
            if (language == "zh-Hans" && Han(run))
                Check(run.GlyphTypeface.FamilyNames.Values.Contains("Microsoft YaHei UI"), "Simplified Chinese UI glyphs cannot silently use Japanese or Traditional Chinese fallback: " +
                    new string(run.Characters!.ToArray()) + " in " + string.Join(",", run.GlyphTypeface.FamilyNames.Values));
            if (run.Characters?.Any(value => value is >= 'A' and <= 'Z' or >= 'a' and <= 'z' or >= '0' and <= '9') == true)
                TypographyChecks.CheckRenderedFace(run.GlyphTypeface);
        }
    }
    private static object[] Describe(GlyphRun[] runs) => runs.Select(run => new { text = run.Characters == null ? null : new string(run.Characters.ToArray()),
        family = run.GlyphTypeface.FamilyNames.Values.Distinct().ToArray(), weight = run.GlyphTypeface.Weight.ToOpenTypeWeight(),
        font = run.GlyphTypeface.FontUri.AbsoluteUri }).Distinct().Cast<object>().ToArray();
    private static bool Han(GlyphRun run) => run.Characters?.Any(value => value is >= '\u3400' and <= '\u9fff') == true;
    private static IEnumerable<GlyphRun> Glyphs(DependencyObject root)
    {
        foreach (var value in Descendants(root).OfType<Visual>())
            if (VisualTreeHelper.GetDrawing(value) is Drawing drawing) foreach (var run in Runs(drawing)) yield return run;
    }
    private static IEnumerable<GlyphRun> Runs(Drawing drawing)
    {
        if (drawing is GlyphRunDrawing glyph) yield return glyph.GlyphRun;
        if (drawing is DrawingGroup group) foreach (var child in group.Children) foreach (var run in Runs(child)) yield return run;
    }
    private static IEnumerable<DependencyObject> Descendants(DependencyObject root)
    {
        yield return root;
        for (int i = 0; i < VisualTreeHelper.GetChildrenCount(root); i++) foreach (var value in Descendants(VisualTreeHelper.GetChild(root, i))) yield return value;
    }
    private static void Check(bool condition, string message) { if (!condition) throw new InvalidOperationException(message); }
    private sealed class Startup : IStartupRegistration { public StartupRegistrationState Read() => new(false, true); public bool Set(bool enabled) => true; }
}
