using System;
using System.IO;
using System.Linq;
using System.Runtime.InteropServices;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Automation;
using System.Windows.Controls;
using System.Windows.Input;

namespace CodexPacer.Windows;

public partial class App
{
    private WindowsUpdateService? updates;
    private WindowsUpdateState? updateState;
    private WindowsUpdateChannel? updateChannel;
    private WindowsInstallationIdentity? updateIdentity;
    private UpdateWindow? updateWindow;
    private Window? updateNotes;
    private string updateVersion = "";
    private sealed class UpdatePresenter(App app) : IWindowsUpdatePresenter
    {
        private SettingsWindow? checkSettings;
        public bool KeepsResultOpen => app.updateWindow != null;

        public void Checking()
        {
            // Keep the result on the surface where the check started.
            checkSettings = !KeepsResultOpen && app.settings is { ShowsUpdatesInline: true } settings ? settings : null;
            if (checkSettings != null) checkSettings.InlineUpdate("checking");
            else app.PresentUpdateCheck();
        }

        public void Offer(WindowsUpdatePackage package, bool manual)
        {
            if (!manual) { app.settings?.InlineUpdate("offer"); return; }
            Complete("offer", window => window.Offer(package, true));
        }

        public void UpToDate() => Complete("upToDate", window => window.UpToDate());
        public void Failed() => Complete("failed", window => window.Failed());

        private void Complete(string phase, Action<UpdateWindow> apply)
        {
            var settings = checkSettings;
            checkSettings = null;
            if (app.quitting) return;
            if (settings != null) settings.InlineUpdate(phase);
            else if (app.updateWindow is { } window)
            {
                apply(window);
                window.Activate();
            }
        }
    }
    private Task CreateWindowsUpdaterAsync(string[] arguments, Guid? qa, bool reference)
    {
        updates = new WindowsUpdateService(action => Dispatcher.BeginInvoke(action));
        return CreateWindowsUpdaterCoreAsync(arguments, qa, reference);
    }
    private async Task CreateWindowsUpdaterCoreAsync(string[] arguments, Guid? qa, bool reference)
    {
        try
        {
            var identity = WindowsInstallationIdentity.ForApp(AppContext.BaseDirectory);
            // A demo never starts production checks. A local QA feed needs both
            // the installed QA identity and the explicit isolated demo scope.
            int test = Array.IndexOf(arguments, "--update-qa");
            WindowsUpdateChannel? channel;
            if (test >= 0)
            {
                if (!demo || !reference || qa == null || identity.QaScope != qa || test + 1 >= arguments.Length)
                    throw new ArgumentException("Update QA requires an isolated demo installation.");
                channel = await Task.Run(() => WindowsUpdateChannel.ReadTest(arguments[test + 1], qa.Value)).WaitAsync(TimeSpan.FromSeconds(3));
            }
            else channel = demo ? null : WindowsUpdateChannel.Production;
            updateIdentity = identity;
            updateState = new WindowsUpdateState(Path.Combine(UpdateSessions.Root(identity.DataRoot), "state-v1.json"));
            if (channel == null) return;
            channel.Validate();
            string arch = RuntimeInformation.ProcessArchitecture == Architecture.Arm64 ? "arm64" : "x64";
            var build = channel.TestCurrentBuild ?? WindowsUpdateVersion.Read(typeof(App).Assembly);
            updateVersion = WindowsUpdateVersion.Read(typeof(App).Assembly).ToString(3);
            var client = new UpdateFeedClient(channel, arch, build, Environment.OSVersion.Version, ui!.Language);
            updates = new WindowsUpdateService(action => Dispatcher.BeginInvoke(action), client, updateState) { Presenter = new UpdatePresenter(this) };
            updates.Changed += value => island?.SetUpdateInputSuspended(value.Busy || updateNotes != null);
            updateChannel = channel;
        }
        catch (Exception error) when (WindowsUpdateService.Recoverable(error)) { /* Fixed placeholder; never expose a feed path or key. */ }
    }
    private async Task StartWindowsUpdaterAsync(string[] arguments)
    {
        if (quitting || updates is not { } service || updateIdentity is not { } identity || ui == null) return;
        if (arguments.Contains("--update-failed")) island?.SetStatus(ui.Text("windows.updates.install_failed"));
        var channel = updateChannel;
        int resultIndex = Array.IndexOf(arguments, "--update-result");
        string? session = resultIndex >= 0 && resultIndex + 1 < arguments.Length ? arguments[resultIndex + 1] : null;
        if (channel == null && session == null) return;
        string[] oldSessions = [];
        try { oldSessions = await Task.Run(() => UpdateSessions.Capture(identity.DataRoot)); }
        catch (Exception error) when (WindowsUpdateService.Recoverable(error)) { }
        try
        {
            bool retry = false;
            // Record a failed patch before an automatic check can read the feed.
            if (session != null && updateState is { } state && !quitting)
            {
                try
                {
                    var result = await Task.Run(() => UpdateHandoff.ConsumeResult(identity, session, state,
                        WindowsUpdateVersion.Read(typeof(App).Assembly))).WaitAsync(TimeSpan.FromSeconds(3));
                    if (StartupPresentation.Resolve(null, result).Failure is { } failure) island?.SetStatus(ui.Text(failure));
                    retry = result is { Success: false, Incremental: true };
                }
                catch (Exception error) when (WindowsUpdateService.Recoverable(error)) { island?.SetStatus(ui.Text("windows.updates.install_failed")); }
            }
            if (quitting || channel == null) return;
            await service.InitializeAsync(channel, identity, ui.Language, preferences.AutomaticUpdates, Quit);
            if (!quitting && retry) _ = service.RetryAfterFailedPatchAsync();
        }
        finally { if (oldSessions.Length != 0) _ = CleanUpdateSessionsAsync(identity.DataRoot, oldSessions); }
    }
    // The helper that relaunched this app may still be exiting, so its
    // session can stay locked briefly; anything left goes at the next start.
    private static async Task CleanUpdateSessionsAsync(string dataRoot, string[] sessions)
    {
        for (int attempt = 0; attempt < 30; attempt++)
        {
            try { if (await Task.Run(() => UpdateSessions.Clean(dataRoot, sessions)) == 0) return; }
            catch (Exception error) when (WindowsUpdateService.Recoverable(error)) { return; }
            await Task.Delay(TimeSpan.FromSeconds(2));
        }
    }
    private void PresentUpdateCheck()
    {
        if (quitting || ui == null || updates == null) return;
        bool created = updateWindow == null;
        if (updateWindow == null)
        {
            var window = new UpdateWindow(ui, updates, updateVersion, demoDark, island?.AppearanceSource);
            window.Closed += (_, _) => { if (ReferenceEquals(updateWindow, window)) updateWindow = null; island?.SetUpdateInputSuspended(updates.Status.Busy || updateNotes != null); };
            updateWindow = window;
        }
        updateWindow.Checking();
        if (created) updateWindow.Show();
        updateWindow.Activate();
    }
    /// Brings the update window forward instead of opening something behind it.
    private bool FocusUpdateWindow()
    {
        if (updateWindow == null) return false;
        updateWindow.Activate(); return true;
    }
    private void ShowSignedUpdateNotes(string notes)
    {
        if (quitting || ui == null || updates == null) return;
        if (updateNotes != null) { updateNotes.Activate(); return; }
        var window = new Window { Title = ui.Text("whats_new.window_title"), Width = 580, Height = 460,
            WindowStartupLocation = WindowStartupLocation.CenterScreen, FontFamily = PacerFonts.Interface };
        WindowRendering.Prepare(window); updateNotes = window;
        window.Resources.MergedDictionaries.Add(new ResourceDictionary { Source = new Uri("/CodexPacer;component/SettingsStyles.xaml", UriKind.Relative) });
        var appearance = island?.AppearanceSource?.Current;
        SettingsPalette.Apply(window.Resources, demoDark ?? appearance?.Dark ?? false, true, appearance);
        window.SetResourceReference(Control.BackgroundProperty, "SettingsBackground");
        var viewer = UpdateWindow.NotesView(ui, notes); viewer.Margin = new Thickness(16); viewer.MaxHeight = double.PositiveInfinity;
        AutomationProperties.SetName(viewer, ui.Text("windows.updates.view_notes"));
        window.Content = viewer; island?.SetUpdateInputSuspended(true);
        window.PreviewKeyDown += (_, args) => { if (args.Key == Key.Escape) { window.Close(); args.Handled = true; } };
        window.Closed += (_, _) => { updateNotes = null; island?.SetUpdateInputSuspended(updates.Status.Busy); };
        window.Show(); window.Activate();
    }
}
