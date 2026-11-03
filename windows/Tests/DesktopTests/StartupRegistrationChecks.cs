using CodexPacer.Windows;
using Microsoft.Win32;

internal static class StartupRegistrationChecks
{
    internal static void Run()
    {
        const string exe = @"C:\synthetic 中文 space\Pacer\CodexPacer.exe";
        const string owner = @"Software\CodexPacer\StartupOwners\CodexPacer";
        var store = new Store();
        int opened = 0;
        var startup = new WindowsStartupRegistration(exe, store: store, openSettings: () => { opened++; return true; });
        Check(startup.Set(true) && startup.Read() is { Registered: true, Effective: true }, "A current-user entry must register the quoted current executable");
        Check(startup.Command == "\"" + exe + "\" --launch-at-login", "Unicode and spaces must remain quoted");
        store.Put(WindowsStartupRegistration.ApprovedKey, "CodexPacer", Approval(3));
        byte[] disabled = (byte[])store.Read(WindowsStartupRegistration.ApprovedKey, "CodexPacer")!.Value;
        Check(startup.Read() is { Registered: true, Effective: false, BlockReason: StartupBlockReason.Disabled }, "Windows disablement must differ from the requested choice");
        Check(startup.Set(false) && startup.Set(true) && startup.Read().BlockReason == StartupBlockReason.Disabled,
            "Changing the requested choice cannot silently erase Windows disablement");
        Check(disabled.SequenceEqual((byte[])store.Read(WindowsStartupRegistration.ApprovedKey, "CodexPacer")!.Value), "The approval bytes must remain untouched");
        foreach (uint state in new uint[] { 2, 6, 7, 55 })
        {
            store.Put(WindowsStartupRegistration.ApprovedKey, "CodexPacer", Approval(state));
            var expected = state is 2 or 6 ? StartupBlockReason.None : state == 7 ? StartupBlockReason.Disabled : StartupBlockReason.Unknown;
            Check(startup.Read().BlockReason == expected, "Recognized OS states and unknown future states must stay distinct");
        }
        store.Put(WindowsStartupRegistration.ApprovedKey, "CodexPacer", new(new byte[] { 2 }, RegistryValueKind.Binary));
        Check(startup.Read().BlockReason == StartupBlockReason.Unknown, "Malformed approval data cannot look enabled");
        store.Put(WindowsStartupRegistration.PolicyKey, "DisableCurrentUserRun", new(1, RegistryValueKind.DWord));
        Check(startup.Read() is { Registered: true, BlockReason: StartupBlockReason.Policy }, "The current-user Run policy must be visible");
        Check(startup.Set(false) && !startup.Read().Registered, "A blocked item can still be explicitly unregistered");
        Check(startup.OpenSettings() && opened == 1 && WindowsStartupRegistration.SettingsUri == "ms-settings:startupapps", "Only the fixed Startup apps route belongs in this entry point");

        store = new();
        startup = new(exe, store: store);
        store.FailWriteAfter = (WindowsStartupRegistration.RunKey, "CodexPacer");
        Check(!startup.Set(true) && store.Read(WindowsStartupRegistration.RunKey, "CodexPacer") == null &&
            store.Read(owner, "Executable") == null, "An enable failure after mutation must roll back both values");
        Check(startup.Set(true), "The startup service must recover after a failed write");
        var before = store.Snapshot();
        store.FailDeleteAfter = (WindowsStartupRegistration.RunKey, "CodexPacer");
        Check(!startup.Set(false) && startup.Read().Registered && store.Same(before), "A disable failure must restore the acknowledged registration");
        store.FailDeleteAfter = (WindowsStartupRegistration.RunKey, "CodexPacer");
        store.ConcurrentEdit = () => store.Put(WindowsStartupRegistration.RunKey, "CodexPacer", new("concurrent foreign entry", RegistryValueKind.String));
        Check(!startup.Set(false) && (string?)store.Read(WindowsStartupRegistration.RunKey, "CodexPacer")?.Value == "concurrent foreign entry",
            "Failure rollback must preserve a newer entry written by another actor");

        string old = @"C:\synthetic old\Pacer\CodexPacer.exe";
        store = new(); startup = new(exe, store: store);
        store.Put(WindowsStartupRegistration.RunKey, "CodexPacer", new("\"" + old + "\" --launch-at-login", RegistryValueKind.String));
        store.Put(WindowsStartupRegistration.ApprovedKey, "CodexPacer", Approval(3));
        Check(startup.MigrateFrom(old) && startup.Read() is { Registered: true, BlockReason: StartupBlockReason.Disabled },
            "An owned upgrade must point to the new executable and keep OS disablement");
        store.Put(WindowsStartupRegistration.RunKey, "UnrelatedApp", new("preserve", RegistryValueKind.String));
        Check(startup.RemoveOwned() && store.Read(WindowsStartupRegistration.RunKey, "CodexPacer") == null &&
            store.Read(WindowsStartupRegistration.ApprovedKey, "CodexPacer") == null &&
            store.Read(owner, "Executable") == null &&
            (string?)store.Read(WindowsStartupRegistration.RunKey, "UnrelatedApp")?.Value == "preserve",
            "Uninstall must remove its own Run, approval and ownership values and preserve another app");
        Check(startup.Set(true) && startup.Set(false), "An explicit off choice must remain removable");
        store.Put(WindowsStartupRegistration.ApprovedKey, "CodexPacer", Approval(3));
        Check(startup.RemoveOwned() && store.Read(WindowsStartupRegistration.ApprovedKey, "CodexPacer") == null, "Uninstall must also clear a disabled entry's owned approval residue");

        store.Put(WindowsStartupRegistration.RunKey, "CodexPacer", new("foreign-command", RegistryValueKind.String));
        store.Put(WindowsStartupRegistration.ApprovedKey, "CodexPacer", Approval(3));
        store.Put(owner, "Executable", new(exe, RegistryValueKind.String));
        before = store.Snapshot();
        Check(startup.Read() is { Registered: false, Available: false, BlockReason: StartupBlockReason.OtherInstallation } &&
            !startup.Set(true) && !startup.Set(false) && store.Same(before), "Another installation's value must never be claimed by this copy");
        Check(startup.RemoveOwned() && (string?)store.Read(WindowsStartupRegistration.RunKey, "CodexPacer")?.Value == "foreign-command" &&
            store.Read(WindowsStartupRegistration.ApprovedKey, "CodexPacer") != null, "Uninstall cannot erase another copy's approval");
        Check(!new WindowsStartupRegistration("C:\\" + new string('x', 260) + "\\CodexPacer.exe", store: store).Set(true), "An overlong Run command must fail without registering anything");
    }
    private static RegistrationValue Approval(uint value)
    { var bytes = new byte[12]; BitConverter.GetBytes(value).CopyTo(bytes, 0); return new(bytes, RegistryValueKind.Binary); }
    private static void Check(bool value, string message) { if (!value) throw new InvalidOperationException(message); }
    internal sealed class Store : IUserRegistrationStore
    {
        private readonly Dictionary<(string Path, string Name), RegistrationValue> values = new();
        internal (string, string)? FailWriteAfter, FailDeleteAfter;
        internal Action? ConcurrentEdit;
        private static (string, string) Key(string path, string name) => (path.ToUpperInvariant(), name.ToUpperInvariant());
        public RegistrationValue? Read(string path, string name) => values.GetValueOrDefault(Key(path, name));
        internal void Put(string path, string name, RegistrationValue value) => values[Key(path, name)] = value;
        public void Write(string path, string name, RegistrationValue value)
        {
            Put(path, name, value);
            if (FailWriteAfter is { } failure && Key(path, name) == Key(failure.Item1, failure.Item2))
            { FailWriteAfter = null; throw new IOException("synthetic denied write"); }
        }
        public void Delete(string path, string name)
        {
            values.Remove(Key(path, name));
            if (FailDeleteAfter is { } failure && Key(path, name) == Key(failure.Item1, failure.Item2))
            { FailDeleteAfter = null; ConcurrentEdit?.Invoke(); ConcurrentEdit = null; throw new UnauthorizedAccessException("synthetic denied delete"); }
        }
        public void DeleteEmptyKey(string path) { }
        internal Dictionary<(string, string), RegistrationValue> Snapshot() => new(values);
        internal bool Same(Dictionary<(string, string), RegistrationValue> before) =>
            values.Count == before.Count && values.All(pair => pair.Value.Same(before.GetValueOrDefault(pair.Key)));
    }
}
