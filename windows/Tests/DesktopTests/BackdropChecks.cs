using System.Runtime.InteropServices;
using CodexPacer.Windows;

internal static class BackdropChecks
{
    internal static void Run()
    {
        var good = new BackdropSystemState(22621, true, false);
        Check(BackdropPolicy.Resolve("classic", good) == new BackdropDecision("classic", false, BackdropReason.Classic), "Classic stays Black");
        Check(BackdropPolicy.Resolve("graphite", good) == new BackdropDecision("graphite", false, BackdropReason.Classic)
            && BackdropPolicy.Resolve("graphite", good with { Build = 19041 }).Reason == BackdropReason.Classic, "Graphite is opaque on every build");
        Check(BackdropPolicy.Resolve("liquidGlass", good).Glass, "The minimum supported build accepts glass");
        Check(BackdropPolicy.Resolve("liquidGlassLight", good) == new BackdropDecision("liquidGlassLight", true, BackdropReason.Available)
            && BackdropPolicy.Resolve("liquidGlassLight", good with { Build = 22620 }).Reason == BackdropReason.OldSystem
            && BackdropPolicy.Resolve("liquidGlassLight", good with { Transparency = false }).Reason == BackdropReason.TransparencyOff,
            "Light Liquid Glass is the same system material, with the same fallbacks");
        Check(BackdropPolicy.Resolve("liquidGlass", good with { Build = 22620 }).Reason == BackdropReason.OldSystem, "A preceding build fails closed");
        Check(BackdropPolicy.Resolve("liquidGlass", good with { Available = false }).Reason == BackdropReason.SystemUnavailable, "Missing system settings fail closed");
        Check(BackdropPolicy.Resolve("liquidGlass", good with { Transparency = false }).Reason == BackdropReason.TransparencyOff, "Transparency effects off selects Black");
        Check(BackdropPolicy.Resolve("liquidGlass", good with { HighContrast = true }).Reason == BackdropReason.HighContrast, "High contrast selects Black");
        Check(BackdropPolicy.Resolve("liquidGlass", good, true).Reason == BackdropReason.GraphicsUnavailable, "API failure selects Black");
        Check(BackdropPolicy.Resolve("liquidGlass", good, lost: true).Reason == BackdropReason.DeviceLost, "Device removal selects Black");
        try { BackdropPolicy.Resolve("unknown", good); throw new Exception("Unknown preferences accepted"); } catch (ArgumentException) { }

        var queue = new Queue<Action>();
        void Drain() { int count = 0; while (queue.TryDequeue(out var work)) { Check(++count < 50, "No unbounded retry loop"); work(); } }
        var source = new Source(good); var created = new List<Surface>();
        var controller = new BackdropController(source, () => { var surface = new Surface(); created.Add(surface); return surface; }, queue.Enqueue);
        var frame = new BackdropFrame(-1200, 0, 900, 600, 1.5, [0, 0, 900, 0, 900, 600, 0, 600], true);
        controller.Apply(frame); Drain();
        Check(created.Count == 0, "Classic does not initialize a compositor");
        controller.Prefer("liquidGlass");
        Check(controller.Glass && created.Count == 1 && created[0].Frames.Single().SameGeometry(frame), "The cached frame starts glass at the correct monitor and DPI");
        controller.Apply(frame with { Polygon = frame.Polygon.ToArray() }); Drain();
        Check(created[0].Frames.Count == 1 && queue.Count == 0, "An unchanged idle frame does not redraw or schedule a wake-up");
        var moved = frame with { X = 10, Y = 20, Scale = 1.25 };
        controller.Apply(moved);
        Check(created[0].Frames.Last().SameGeometry(moved), "A move or DPI change applies its complete frame");
        controller.Hide();
        Check(created[0].Hidden == 1, "Hiding the content hides its underlay");
        controller.Apply(moved); Check(created[0].Frames.Count == 3, "Showing again reapplies the underlay");
        source.Set(good with { Transparency = false }); Drain();
        Check(!controller.Glass && controller.Decision.Preferred == "liquidGlass" && created[0].Black == 1 && created[0].Disposed == 1,
            "Transparency off makes Black and retires resources while preserving the preference");
        source.Set(good); Drain();
        Check(controller.Glass && created.Count == 2 && created[1].Frames.Single().SameGeometry(moved), "Transparency on restores glass without a preference write");
        source.Set(good with { HighContrast = true }); Drain();
        Check(!controller.Glass && controller.Decision.Reason == BackdropReason.HighContrast && created[1].Disposed == 1, "High contrast tears down the glass surface");
        source.Set(good); Drain(); Check(controller.Glass && created.Count == 3, "Leaving high contrast restores glass");
        created[2].Remove(); Drain();
        Check(!controller.Glass && controller.Decision.Reason == BackdropReason.DeviceLost && created[2].Disposed == 1, "A device event falls back without waiting for another animation frame");
        controller.GraphicsChanged(); Drain(); Check(controller.Glass && created.Count == 4, "Display recovery can create a new graphics device without changing system settings");
        controller.GraphicsChanged(); Drain(); Check(created.Count == 4, "A healthy surface is retained on repeated display messages");

        // An already queued loss from a retired native surface cannot poison its replacement.
        created[3].Remove(); controller.Prefer("classic"); controller.Prefer("liquidGlass");
        Drain();
        Check(controller.Glass && controller.Decision.Reason == BackdropReason.Available, "Stale removal and deferred teardown do not discard a replacement");
        // The wash is set when an underlay is made, so a new glass tone makes a new one.
        int made = created.Count;
        controller.Prefer("liquidGlassLight"); Drain();
        Check(controller.Glass && created.Count == made + 1 && created[made - 1].Disposed == 1, "Light Liquid Glass replaces the dark underlay");
        controller.Prefer("liquidGlass"); Drain();
        Check(controller.Glass && created.Count == made + 2 && created[made].Disposed == 1, "Dark Liquid Glass replaces the light underlay");
        controller.Prefer("classic"); Drain();
        Check(!controller.Glass && created.Last().Disposed == 1 && controller.WindowHandle == IntPtr.Zero, "Classic releases the native window");
        source.Set(good); controller.Dispose(); source.Set(good); Drain();
        Check(source.Disposed == 1 && created.All(value => value.Disposed == 1), "Shutdown releases each source and native surface exactly once");

        foreach (Exception failure in new Exception[] { new COMException("injected", unchecked((int)0x80004005)), new DllNotFoundException(), new EntryPointNotFoundException(), new BadImageFormatException(), new NotSupportedException() })
        {
            int attempts = 0; var failedSource = new Source(good);
            using var failed = new BackdropController(failedSource, () => { attempts++; throw failure; }, queue.Enqueue);
            failed.Prefer("liquidGlass"); failed.Apply(frame); Drain(); failed.Apply(frame);
            Check(!failed.Glass && failed.Decision.Reason == BackdropReason.GraphicsUnavailable && attempts == 1 && failed.Decision.Preferred == "liquidGlass",
                "An unavailable API falls back without retrying on every frame");
        }
        Drain();
        var applySource = new Source(good); var applying = new Surface { Failure = new COMException("injected update", unchecked((int)0x887A0005)) };
        using (var updateFailure = new BackdropController(applySource, () => applying, queue.Enqueue))
        {
            updateFailure.Prefer("liquidGlass"); updateFailure.Apply(frame); Drain();
            Check(!updateFailure.Glass && updateFailure.Decision.Reason == BackdropReason.DeviceLost && applying.Disposed == 1,
                "Device loss returned by a frame update also releases the failed surface");
        }
        Drain();
        var unavailable = new Source(good with { Build = 22000 }); int calls = 0;
        using (var old = new BackdropController(unavailable, () => { calls++; return new Surface(); }, queue.Enqueue))
        { old.Prefer("liquidGlass"); old.Apply(frame); Drain(); Check(calls == 0 && old.Decision.Reason == BackdropReason.OldSystem, "An unsupported OS never loads the native DLL"); }
        Drain();
    }
    private sealed class Source(BackdropSystemState value) : IBackdropSystemSource
    {
        public BackdropSystemState Current { get; private set; } = value;
        public event Action? Changed;
        internal int Disposed;
        internal void Set(BackdropSystemState next) { Current = next; Changed?.Invoke(); }
        public void Dispose() { Disposed++; Changed = null; }
    }
    private sealed class Surface : ICompositionBackdrop
    {
        public IntPtr WindowHandle => new(123);
        public event Action? DeviceRemoved;
        internal readonly List<BackdropFrame> Frames = [];
        internal int Hidden, Black, Disposed;
        internal Exception? Failure;
        public void Apply(BackdropFrame value) { if (Failure != null) throw Failure; Frames.Add(value); }
        public void MakeBlack() => Black++;
        public void Hide() => Hidden++;
        internal void Remove() => DeviceRemoved?.Invoke();
        public void Dispose() => Disposed++;
    }
    private static void Check(bool value, string message) { if (!value) throw new InvalidOperationException(message); }
}
