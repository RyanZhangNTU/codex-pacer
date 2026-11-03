using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Runtime.InteropServices;
using System.Text.Json;
using System.Threading.Tasks;
using CodexPacer.Windows;

internal static class CpuProbe
{
    internal static async Task Run(string output)
    {
        await using var scene = await ProtectedScene.Start(output);
        await using var engine = new EngineClient(); ShellProjection.Client = engine;
        var window = new IslandWindow(engine, true, false, animationOverride: true) { IsHitTestVisible = false, ShowActivated = false };
        var rows = new List<object>();
        try
        {
            window.Show(); await engine.StartAsync(Path.Combine(AppContext.BaseDirectory, "Engine/PacerEngine.exe"), true, "en", referenceFixture: true);
            using var shell = Process.GetCurrentProcess(); using var child = Process.GetProcessById(engine.ProcessId!.Value);
            long frames = 0; var stamps = new List<double>();
            window.FrameApplied += _ => { frames++; stamps.Add(Stopwatch.GetTimestamp() / (double)Stopwatch.Frequency); };
            // Warm both rendering paths and the shared controls before ABBA.
            // Keep cold-start measurements in a separate run, not in idle data.
            foreach (string style in new[] { "classic", "liquidGlass" })
            {
                window.ApplyPreferences(new() { IslandAppearance = style, DisplayMode = "notch" });
                window.Reveal(); await window.WaitForPresentationAsync(); await Task.Delay(15000);
                window.CollapseForAutomation(); await window.WaitForPresentationAsync(); await Task.Delay(15000);
            }
            foreach (string style in new[] { "classic", "liquidGlass", "liquidGlass", "classic" })
            {
                window.ApplyPreferences(new() { IslandAppearance = style, DisplayMode = "notch" });
                window.Reveal(); await window.WaitForPresentationAsync(); await Task.Delay(1000);
                if (style == "liquidGlass" && !window.GlassVisible) throw new InvalidOperationException("CPU comparison requires actual glass.");
                foreach (string phase in new[] { "collapsed-idle", "expanded-idle", "animation" })
                {
                    if (phase == "collapsed-idle") window.CollapseForAutomation(); else window.Reveal();
                    await window.WaitForPresentationAsync(); await Task.Delay(500); stamps.Clear();
                    double Cpu(Process process) { process.Refresh(); return process.TotalProcessorTime.TotalSeconds; }
                    double shellBefore = Cpu(shell), engineBefore = Cpu(child); var hostBefore = Times();
                    long frameBefore = frames; var clock = Stopwatch.StartNew(); int transitions = 0;
                    while (clock.Elapsed.TotalSeconds < 15)
                    {
                        if (phase == "animation") { if (transitions++ % 2 == 0) window.CollapseForAutomation(); else window.Reveal(); }
                        await Task.Delay(phase == "animation" ? 900 : 250);
                    }
                    var hostAfter = Times(); double seconds = clock.Elapsed.TotalSeconds;
                    double shellCore = (Cpu(shell) - shellBefore) / seconds * 100, engineCore = (Cpu(child) - engineBefore) / seconds * 100;
                    var intervals = stamps.Zip(stamps.Skip(1), (a, b) => (b - a) * 1000).Where(value => value < 200).Order().ToArray();
                    double Percentile(double percent) => intervals.Length == 0 ? 0 : intervals[(int)Math.Min(intervals.Length - 1, intervals.Length * percent)];
                    double total = (hostAfter.Kernel - hostBefore.Kernel) + (hostAfter.User - hostBefore.User);
                    var row = new { style, phase, seconds, processors = Environment.ProcessorCount, shellSingleCorePercent = shellCore, engineSingleCorePercent = engineCore,
                        pacerSingleCorePercent = shellCore + engineCore, pacerMachinePercent = (shellCore + engineCore) / Environment.ProcessorCount,
                        wholeMachineBusyPercent = 100 * (total - (hostAfter.Idle - hostBefore.Idle)) / total,
                        frames = frames - frameBefore, transitions, medianFrameIntervalMs = Percentile(.5), p95FrameIntervalMs = Percentile(.95), worstActiveIntervalMs = intervals.LastOrDefault() };
                    rows.Add(row); File.WriteAllText(Path.Combine(output, "cpu.json"), JsonSerializer.Serialize(rows, new JsonSerializerOptions { WriteIndented = true }));
                }
            }
        }
        finally { window.AllowClose = true; window.Close(); ShellProjection.Client = null; }
    }
    private readonly record struct CpuTimes(ulong Idle, ulong Kernel, ulong User);
    private static CpuTimes Times() { if (!GetSystemTimes(out ulong idle, out ulong kernel, out ulong user)) throw new System.ComponentModel.Win32Exception(); return new(idle, kernel, user); }
    [DllImport("kernel32.dll", SetLastError = true)] [return: MarshalAs(UnmanagedType.Bool)] private static extern bool GetSystemTimes(out ulong idle, out ulong kernel, out ulong user);
}
