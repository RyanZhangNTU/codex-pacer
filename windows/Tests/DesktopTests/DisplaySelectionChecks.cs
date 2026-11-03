using System.Diagnostics;
using System.Security.Cryptography;
using System.Text.Json;
using CodexPacer.Windows;

internal static class DisplaySelectionChecks
{
    internal static async Task Run(string directory)
    {
        void Check(bool condition, string message) { if (!condition) throw new InvalidOperationException(message); }
        var main = new DisplayMonitor(new(1), "qa-main", "QA Twin", "DISPLAY1", new(0, 0, 2560, 1440), new(0, 0, 2560, 1400), true);
        var left = new DisplayMonitor(new(2), "qa-left", "QA Twin", "DISPLAY2", new(-1920, 0, 0, 1080), new(-1872, 0, 0, 1040), false);
        var upper = new DisplayMonitor(new(3), "qa-upper", "QA Upper", "DISPLAY3", new(2560, -1440, 5120, 0), new(2560, -1400, 5120, 0), false);
        DisplayMonitor[] topology = [upper, left, main];
        Check(DisplaySelection.Resolve(topology, new()).Display == main, "Automatic follows the primary display independently of enumeration order");
        Check(DisplaySelection.Resolve(topology, new() { DisplaySelection = "primary" }).Display == main, "Main Display follows the system primary");
        var preference = left.Choose(new() { HideProjects = true, Position = "bottomRight", ShowInFullscreen = true });
        Check(preference.IsValid && preference.HideProjects && preference.Position == "bottomRight" && preference.ShowInFullscreen, "Monitor selection preserves unrelated choices");
        Check(DisplaySelection.Resolve(topology, preference with { DisplayID = "QA-LEFT" }).Display == left, "Device paths match without case sensitivity");
        var moved = left with { Name = "QA Renamed", DeviceName = "DISPLAY9", Bounds = new(-2560, -100, 0, 1340), Work = new(-2560, -60, 0, 1340) };
        Check(DisplaySelection.Resolve([main, moved, upper], preference).Display == moved, "Device path wins over changed name, position, resolution and display number");
        var port = left with { DevicePath = "qa-reconnected-port", DeviceName = "DISPLAY8" };
        Check(DisplaySelection.Resolve([main, port], preference).Display == port, "Unique name and position recover a changed interface path");
        string saved = JsonSerializer.Serialize(preference);
        var missing = DisplaySelection.Resolve([main, upper], preference);
        Check(missing.Display == main && missing.FellBack, "Disconnect uses Main Display and cannot match another same-name screen at another position");
        Check(JsonSerializer.Serialize(preference) == saved, "Fallback never rewrites the preference");
        Check(DisplaySelection.Resolve([left, main, upper], preference).Display == left, "Reconnect restores the specified display");
        var newMain = left with { Primary = true }; var oldMain = main with { Primary = false };
        Check(DisplaySelection.Resolve([oldMain, upper, newMain], new()).Display == newMain, "Automatic follows primary changes");
        Check(DisplaySelection.Resolve([oldMain, upper, newMain], main.Choose(new())).Display == oldMain, "A specified display does not follow primary changes");
        Check(DisplaySelection.Resolve([left, port, main], preference with { DisplayID = "missing" }).FellBack, "Ambiguous fallback does not depend on enumeration order");
        Check(DisplaySelection.Resolve([], preference) is { Display: null, FellBack: true }, "An unavailable topology invents no monitor");
        var layout = new NativeLayout(directory);
        foreach (var monitor in topology.Append(moved))
        foreach (double scale in new[] { 1.0, 1.25, 1.5, 2.0 })
        {
            var frame = monitor.AtScale(scale);
            Check(Math.Abs(frame.Screen.X * scale - monitor.Bounds.Left) < .00001 && Math.Abs(frame.WorkArea.Y * scale - monitor.Work.Top) < .00001,
                "Negative origins and top-taskbar work areas use the target DPI");
            foreach (int position in Enumerable.Range(0, 5))
            foreach (bool expanded in new[] { false, true })
            {
                var target = layout.Measure(frame.Screen, frame.WorkArea, 2, 0, 0, position, expanded, 500, 402, 180, 135).Target;
                double l = target.X * scale, t = target.Y * scale, r = (target.X + target.Width) * scale, b = (target.Y + target.Height) * scale;
                Check(l >= monitor.Bounds.Left - 2 && r <= monitor.Bounds.Right + 2 && t >= monitor.Bounds.Top - 2 && b <= monitor.Bounds.Bottom + 2,
                    "Every collapsed and expanded anchor stays inside the selected screen at each DPI");
                if (position is 1 or 2) Check(Math.Abs(l - monitor.Work.Left) <= 2, "Left anchors respect side taskbars");
                if (position is 3 or 4) Check(Math.Abs(r - monitor.Work.Right) <= 2, "Right anchors follow the selected work area");
                if (position is 2 or 4) Check(Math.Abs(b - (monitor.Work.Bottom - 10 * scale)) <= 2, "Bottom anchors retain the shared ten-point margin");
                else Check(Math.Abs(t - (monitor.Work.Top + 10 * scale)) <= 2, "Top anchors retain the shared work-area margin");
                var notch = layout.Measure(frame.Screen, frame.WorkArea, 1, 0, 0, position, expanded, 500, 402, 180, 135);
                Check(notch.Position == 0 && Math.Abs(notch.Target.Y * scale - monitor.Bounds.Top) <= 2, "Notch keeps the physical top-center anchor");
            }
        }
        foreach (double invalid in new[] { 0.0, -1.0, double.NaN, double.PositiveInfinity })
        {
            bool rejected = false; try { _ = left.AtScale(invalid); } catch (ArgumentOutOfRangeException) { rejected = true; }
            Check(rejected, "Invalid DPI is rejected");
        }
        int configurations = 0;
        var session = new PreferencesSession(new(), _ => { configurations++; return Task.CompletedTask; }, _ => true);
        Check(await session.ChangeAsync(_ => preference) == PreferencesApplyResult.Applied && configurations == 1, "Only the unrelated privacy edit configures the engine");
        Check(await session.ChangeAsync(p => p with { DisplaySelection = "primary", DisplayID = "", ShowInFullscreen = false }) == PreferencesApplyResult.Applied && configurations == 1,
            "Display and fullscreen changes do not restart collectors");
        var failed = new PreferencesSession(preference, _ => throw new InvalidOperationException("Presentation edit reached the engine"), _ => false);
        Check(await failed.ChangeAsync(p => p with { ShowInFullscreen = false }) == PreferencesApplyResult.SaveFailed && failed.Current == preference, "Failed saves preserve the acknowledged choices");
        string file = Path.Combine(AppContext.BaseDirectory, "display-preferences-" + Guid.NewGuid().ToString("N") + ".json");
        try
        {
            var store = new PreferencesStore(file); Check(store.Save(preference), "Display preferences save through the existing store");
            var loaded = store.Load();
            Check(!loaded.Unavailable && loaded.Value.DisplayID == preference.DisplayID && loaded.Value.ShowInFullscreen && loaded.Value.SchemaVersion == 1, "Identity and fullscreen round-trip without a schema change");
            using (var json = JsonDocument.Parse(File.ReadAllText(file)))
                Check(json.RootElement.GetProperty("displayID").GetString() == preference.DisplayID && json.RootElement.GetProperty("showInFullscreen").GetBoolean(), "Stored keys retain displayID and showInFullscreen semantics");
            await RestartAndRead(file, preference);
            foreach (string alias in new[] { "automatic", "primary" })
            {
                var legacy = preference with { DisplaySelection = alias };
                Check(store.Save(legacy), "Either legacy Main Display alias can be saved");
                byte[] beforeRead = File.ReadAllBytes(file);
                await RestartAndRead(file, legacy);
                var restarted = new PreferencesStore(file).Load();
                Check(!restarted.Unavailable && restarted.Value.DisplaySelection == alias
                    && DisplaySelection.Resolve(topology, restarted.Value).Display == main,
                    "Both stored aliases resolve to Main Display and retain their original value after restart");
                Check(File.ReadAllBytes(file).SequenceEqual(beforeRead), "Restart and read never rewrite a legacy alias or its other fields");
            }
            File.WriteAllText(file, "{\"schemaVersion\":1}"); loaded = store.Load();
            Check(!loaded.Unavailable && loaded.Value.DisplaySelection == "automatic" && !loaded.Value.ShowInFullscreen, "Missing keys retain Main Display and fullscreen-off defaults");
            File.WriteAllText(file, "{\"schemaVersion\":1,\"displaySelection\":\"future-mode\"}");
            Check(store.Load().Value.DisplaySelection == "automatic", "Unknown modes retain the default without discarding the profile");
        }
        finally { File.Delete(file); }
    }

    internal static int ReadAfterRestart(string file, string expected)
    {
        var loaded = new PreferencesStore(file).Load();
        return !loaded.Unavailable && Fingerprint(loaded.Value) == expected ? 0 : 1;
    }

    private static string Fingerprint(DesktopPreferences value) => Convert.ToHexString(SHA256.HashData(JsonSerializer.SerializeToUtf8Bytes(new
    {
        value.SchemaVersion, value.DisplaySelection, value.DisplayID, value.DisplayName, value.DisplayX, value.DisplayY,
        value.ShowInFullscreen, value.HideProjects, value.Position
    })));

    private static async Task RestartAndRead(string file, DesktopPreferences expected)
    {
        var start = new ProcessStartInfo(Path.Combine(AppContext.BaseDirectory, "Pacer.DesktopTests.exe"))
        { UseShellExecute = false, CreateNoWindow = true };
        start.ArgumentList.Add("--display-preferences-read"); start.ArgumentList.Add(file); start.ArgumentList.Add(Fingerprint(expected));
        using var child = Process.Start(start) ?? throw new InvalidOperationException("The preference restart fixture did not start");
        try
        {
            await child.WaitForExitAsync().WaitAsync(TimeSpan.FromSeconds(10));
            if (child.ExitCode != 0) throw new InvalidOperationException("Display identity, fallback position, fullscreen and unrelated choices must survive a fresh process");
        }
        finally { if (!child.HasExited) { child.Kill(); await child.WaitForExitAsync(); } }
    }
}
