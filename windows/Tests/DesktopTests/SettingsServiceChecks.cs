using Microsoft.Win32;
using CodexPacer.Windows;

internal static class SettingsServiceChecks
{
    internal static void Run()
    {
        // This isolated key is never an OS startup location.
        string parent = @"Software\CodexPacer\Tests";
        string name = Guid.NewGuid().ToString("N"), key = parent + "\\" + name;
        try
        {
            using (var fixture = Registry.CurrentUser.CreateSubKey(key)) fixture.SetValue("OtherFixture", "preserve");
            var startup = new WindowsStartupRegistration(@"C:\fixture 中文 space\CodexPacer.exe", key);
            Check(startup.Read() == new StartupRegistrationState(false, true), "The fixture must start without a Pacer entry");
            Check(startup.Set(true) && startup.Read().Registered, "Enabling must register only Pacer");
            using (var fixture = Registry.CurrentUser.OpenSubKey(key))
            {
                Check((string?)fixture?.GetValue("CodexPacer") == "\"C:\\fixture 中文 space\\CodexPacer.exe\" --launch-at-login", "The executable path must stay quoted");
                Check((string?)fixture?.GetValue("OtherFixture") == "preserve", "Other entries must be preserved");
            }
            Check(startup.Set(false) && !startup.Read().Registered, "Disabling must remove Pacer's own value");
            Check(!new WindowsStartupRegistration("C:\\" + new string('x', 260) + "\\CodexPacer.exe", key).Set(true), "An oversized Run command cannot be registered");
        }
        finally { Registry.CurrentUser.DeleteSubKey(key, throwOnMissingSubKey: false); }

        var opened = new List<string>();
        var apps = new WindowsDesktopApplications(family => family.StartsWith("OpenAI.Codex_", StringComparison.Ordinal),
            value => { opened.Add(value); return true; });
        Check(apps.Available().Select(value => value.Provider).SequenceEqual(["codex"]), "Only registered desktop apps belong in the catalog");
        Check(!apps.Open("claude") && !apps.Open("unknown;command"), "Missing and unknown providers cannot launch anything");
        Check(apps.Open("codex") && opened.SequenceEqual(["OpenAI.Codex_2p2nqsd0c76g0!App"]), "Activation must use the verified package identity");
        Check(!new WindowsDesktopApplications(_ => true, _ => false).Open("claude"), "Activation failures must remain failures");
    }
    private static void Check(bool value, string message) { if (!value) throw new InvalidOperationException(message); }
}
