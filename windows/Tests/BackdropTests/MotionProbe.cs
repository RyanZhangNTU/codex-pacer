using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Text.Json;
using System.Threading.Tasks;
using CodexPacer.Windows;

internal static class MotionProbe
{
    internal static async Task Run(string output)
    {
        await using var scene = await ProtectedScene.Start(output);
        await using var engine = new EngineClient(); ShellProjection.Client = engine;
        var window = new IslandWindow(engine, true, false, animationOverride: true) { ShowActivated = false, IsHitTestVisible = false };
        var results = new List<object>(); var intervals = new List<double>();
        bool measuring = false; double previous = 0;
        window.FrameApplied += _ =>
        {
            if (!measuring) return;
            double now = Stopwatch.GetTimestamp() / (double)Stopwatch.Frequency;
            if (previous > 0) intervals.Add((now - previous) * 1000);
            previous = now;
        };
        try
        {
            window.Show(); await engine.StartAsync(Path.Combine(AppContext.BaseDirectory, "Engine/PacerEngine.exe"), true, "en", referenceFixture: true);
            window.Reveal(); await window.WaitForPresentationAsync();
            foreach (string style in new[] { "classic", "liquidGlass" })
            {
                window.ApplyPreferences(new() { IslandAppearance = style, DisplayMode = "notch" }); await window.WaitForPresentationAsync();
                if (style == "liquidGlass" && !window.GlassVisible) throw new InvalidOperationException("Motion sampling requires glass.");
                intervals.Clear();
                for (int index = 0; index < 10; index++)
                {
                    previous = 0; measuring = true;
                    if (index % 2 == 0) window.CollapseForAutomation(); else window.Reveal();
                    await window.WaitForPresentationAsync(); measuring = false;
                    await Task.Delay(100);
                }
                var ordered = intervals.Order().ToArray();
                results.Add(new { style, transitions = 10, activeIntervals = ordered.Length, medianMs = ordered[ordered.Length / 2],
                    p95Ms = ordered[(int)(ordered.Length * .95)], worstMs = ordered[^1], over16Ms = ordered.Count(value => value > 16.67),
                    over33Ms = ordered.Count(value => value > 33.34), over100Ms = ordered.Count(value => value > 100), excludedInterTransitionWaits = true,
                    scale = System.Windows.Media.VisualTreeHelper.GetDpi(window).DpiScaleX });
                File.WriteAllText(Path.Combine(output, "motion.json"), JsonSerializer.Serialize(results, new JsonSerializerOptions { WriteIndented = true }));
            }
        }
        finally { window.AllowClose = true; window.Close(); ShellProjection.Client = null; }
    }
}
