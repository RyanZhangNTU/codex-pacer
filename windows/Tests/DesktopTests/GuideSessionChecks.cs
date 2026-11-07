using System.Diagnostics;
using System.Text.Json;
using CodexPacer.Windows;

internal static class GuideSessionChecks
{
    internal static async Task Run(string enginePath)
    {
        await using var engine = new EngineClient(); await engine.StartAsync(enginePath, true, "en", referenceFixture: true);
        int queries = 0;
        Task<GuideCatalog> Query(GuideRequest input) { queries++; return engine.QueryAsync<GuideCatalog>("guidePages", new { shell = new { guide = input } }, TimeSpan.FromSeconds(3)); }
        string file = Path.Combine(AppContext.BaseDirectory, "guide-preferences-" + Guid.NewGuid().ToString("N") + ".json");
        try
        {
            int configured = 0, saved = 0;
            var store = new PreferencesStore(file);
            var session = new PreferencesSession(new() { HideProjects = true }, _ => { configured++; return Task.CompletedTask; }, value => { saved++; return store.Save(value); });
            var guides = new GuideSession(session, Query, "4.2.4", "en", false, false);
            var fresh = await guides.LoadAsync(); Check(fresh.Page == "welcome" && fresh.RecordLaunch, "Fresh installs show the two-step guide before release notes");
            Check(await guides.RecordAsync(false) == PreferencesApplyResult.Applied && session.Current.WelcomeGuideVersion == 0 && session.Current.WhatsNewVersion == "4.2.4",
                "Opening the welcome guide records the note, and closing owns the welcome record");
            Check(await guides.RecordAsync(true) == PreferencesApplyResult.Applied && session.Current.WelcomeGuideVersion == 4 && configured == 0, "Guide records never reconfigure collectors");
            Check(queries == 1, "Closing a guide records the engine-confirmed version without another IPC request");
            await ColdRead(file, "4.2.4", 4);
            using (var json = JsonDocument.Parse(File.ReadAllText(file)))
                Check(json.RootElement.GetProperty("schemaVersion").GetInt32() == 2
                    && json.RootElement.GetProperty("welcomeGuideVersion").GetInt32() == 4 && json.RootElement.GetProperty("whatsNewVersion").GetString() == "4.2.4", "Schema 2 persists the exact Mac preference keys");
            var reopened = new PreferencesSession(new PreferencesStore(file).Load().Value, _ => throw new Exception("Unexpected collector change"), value => store.Save(value));
            Check((await new GuideSession(reopened, Query, "4.2.4", "en", false, false).LoadAsync()).Page == null, "Restarting the same version opens neither window");
            var update = new GuideSession(reopened, Query, "4.2.5", "en", false, false);
            Check((await update.LoadAsync()).Page == null && await update.RecordAsync(false) == PreferencesApplyResult.Applied, "Versions without highlights update quietly");
            Check(reopened.Current.WelcomeGuideVersion == 4 && reopened.Current.WhatsNewVersion == "4.2.5", "Quiet updates retain the completed major line");
            await ColdRead(file, "4.2.5", 4);
            Check(await new GuideSession(reopened, Query, "4.2.0", "en", false, false).RecordAsync(true) == PreferencesApplyResult.Applied
                && reopened.Current.WhatsNewVersion == "4.2.5", "An older copy cannot roll the recorded note backwards");
            int beforeQuiet = saved;
            foreach (var flags in new[] { (Demo: true, Settings: false), (Demo: true, Settings: true) })
            {
                var quiet = new GuideSession(session, _ => throw new Exception("Quiet recording queried the engine"), "4.2.0", "en", flags.Demo, flags.Settings);
                Check(await quiet.RecordAsync(false) == PreferencesApplyResult.Applied && await quiet.RecordAsync(true) == PreferencesApplyResult.Applied && saved == beforeQuiet,
                    "Demo never queries or writes guide records, including when Settings is open");
            }
            foreach (bool forceWelcome in new[] { true, false })
                await CheckForcedSettings(Query, file + ".settings-" + forceWelcome, forceWelcome);
            var rejected = new PreferencesSession(new(), _ => throw new Exception("Presentation record configured the engine"), _ => false);
            Check(await new GuideSession(rejected, Query, "4.2.0", "en", false, false).RecordAsync(true) == PreferencesApplyResult.SaveFailed
                && rejected.Current.WelcomeGuideVersion == 0 && rejected.Current.WhatsNewVersion == null, "A failed save does not mark either page as seen");
            foreach (var pair in fresh.Links)
            {
                int launched = 0;
                Check(GuideLinks.Open(fresh, pair.Key, uri => { launched++; return uri.Scheme == "https" && uri.AbsoluteUri == pair.Value; }) && launched == 1,
                    "Every public link dispatches exactly once to the default-browser boundary");
            }
            Check(!GuideLinks.Open(fresh, "invented", _ => throw new Exception("Unknown action launched")), "Unknown page actions are rejected");
            foreach (string unsafeUri in new[] { "file:///C:/synthetic", "http://github.com/", "https://github.com.evil.invalid/", "https://user@github.com/", "https://github.com:444/" })
                Check(!GuideLinks.Open(fresh with { Links = new Dictionary<string, string> { ["manual"] = unsafeUri } }, "manual", _ => throw new Exception("Unsafe link launched")), "Unsafe links cannot reach a browser");
            Check(!GuideLinks.Open(fresh, "manual", _ => throw new System.ComponentModel.Win32Exception()), "Browser launch failures stay local");
            Check(GuideSession.MaximumNoteHeight(1000, 30) == 640 && GuideSession.MaximumNoteHeight(600, 28) == 524
                && GuideSession.MaximumNoteHeight(20, 28) == 0 && GuideSession.MaximumNoteHeight(double.NaN, 28) == 0, "Note height preserves Mac's content, title-bar and margin cap");
            byte[] unchanged = File.ReadAllBytes(file); _ = await update.LoadAsync();
            Check(File.ReadAllBytes(file).SequenceEqual(unchanged), "Reading page metadata never saves preferences");
        }
        finally { File.Delete(file); }
        foreach (var (welcomed, expected) in new[] { (0, "welcome"), (4, "whatsNew") })
        {
            var upgraded = await Query(new("4.2.0", "3.1.0", welcomed, "en", false, false, false, false));
            var result = new UpdateInstallResult(1, true, "4.2.0.1", "Synthetic signed feed notes");
            var startup = StartupPresentation.Resolve(upgraded, result);
            Check(startup.Guide == expected && startup.WindowCount == 1 && startup.Failure == null,
                "An upgraded launch opens exactly its built-in Welcome or What's New, with no additional feed-notes window");
            Check(StartupPresentation.Resolve(upgraded, result with { Success = false }).Failure == "windows.updates.install_failed",
                "A failed installation keeps its failure status independently of the single guide window");
        }
    }
    private static async Task CheckForcedSettings(Func<GuideRequest, Task<GuideCatalog>> query, string file, bool welcome)
    {
        try
        {
            var store = new PreferencesStore(file); _ = store.Load();
            int configured = 0;
            var session = new PreferencesSession(new() { HideProjects = true }, _ => { configured++; return Task.CompletedTask; }, store.Save);
            var guide = new GuideSession(session, query, "4.2.0", "en", false, true);
            var quiet = await guide.LoadAsync();
            Check(quiet.Page == null && !quiet.RecordLaunch && !File.Exists(file), "Settings alone neither opens pages nor records a silent update");
            var forced = await guide.LoadAsync(forceWelcome: welcome, forceWhatsNew: !welcome);
            Check(forced.Page == (welcome ? "welcome" : "whatsNew") && forced.RecordLaunch == welcome && forced.RecordClose,
                "Forced non-demo Settings pages use Mac's launch and close record conditions");
            if (forced.RecordLaunch) Check(await guide.RecordAsync(false) == PreferencesApplyResult.Applied, "A forced welcome records the note at launch");
            Check(session.Current.WelcomeGuideVersion == 0 && session.Current.WhatsNewVersion == (welcome ? "4.2.0" : null),
                "Welcome completion waits for close, and forced release notes stay unseen until close");
            Check(await guide.RecordAsync(welcome) == PreferencesApplyResult.Applied && configured == 0,
                "Closing either forced Settings page persists records without reconfiguring collectors");
            await ColdRead(file, "4.2.0", welcome ? 4 : 0);
            using var json = JsonDocument.Parse(File.ReadAllBytes(file));
            Check(json.RootElement.GetProperty("schemaVersion").GetInt32() == 2, "Forced Settings records use storage schema 2");
        }
        finally { File.Delete(file); }
    }
    internal static int ReadAfterRestart(string file, string version, string major)
    {
        var value = new PreferencesStore(file).Load();
        return !value.Unavailable && value.Value.WhatsNewVersion == version && value.Value.WelcomeGuideVersion.ToString() == major && value.Value.HideProjects ? 0 : 1;
    }
    private static async Task ColdRead(string file, string version, int major)
    {
        var start = new ProcessStartInfo(Path.Combine(AppContext.BaseDirectory, "Pacer.DesktopTests.exe")) { UseShellExecute = false, CreateNoWindow = true };
        foreach (string argument in new[] { "--guide-preferences-read", file, version, major.ToString() }) start.ArgumentList.Add(argument);
        using var child = Process.Start(start) ?? throw new Exception("Guide restart fixture did not start");
        try { await child.WaitForExitAsync().WaitAsync(TimeSpan.FromSeconds(10)); Check(child.ExitCode == 0, "A fresh process reads both guide records and unrelated privacy from disk"); }
        finally { if (!child.HasExited) { child.Kill(); await child.WaitForExitAsync().WaitAsync(TimeSpan.FromSeconds(2)); } }
    }
    private static void Check(bool condition, string message) { if (!condition) throw new InvalidOperationException(message); }
}
