using System;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Runtime.InteropServices;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Threading;

namespace CodexPacer.Windows;

public partial class App
{
    private WindowsUpdateService? updates;
    private WindowsUpdateState? updateState;
    private WindowsUpdateChannel? updateChannel;
    private WindowsInstallationIdentity? updateIdentity;
    private Window? updateNotes;
    private async Task CreateWindowsUpdaterAsync(string[] arguments, Guid? qa, bool reference)
    {
        Action<Action> post = action => Dispatcher.BeginInvoke(action);
        updates = new WindowsUpdateService(post);
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
            updateState = new WindowsUpdateState(Path.Combine(identity.DataRoot, "Updates", "state-v1.json"));
            if (channel == null) return;
            channel.Validate();
            string arch = RuntimeInformation.ProcessArchitecture == Architecture.Arm64 ? "arm64" : "x64";
            var build = channel.TestCurrentBuild ?? WindowsUpdateVersion.Read(typeof(App).Assembly);
            var state = updateState;
            var creation = Task.Run(() =>
            {
                var backend = new WinSparkleNative(AppContext.BaseDirectory, state);
                try { return (backend, proxy: new UpdateFeedProxy(channel, arch, build, Environment.OSVersion.Version, ui!.Language)); }
                catch { backend.Dispose(); throw; }
            });
            (WinSparkleNative backend, UpdateFeedProxy proxy) created;
            try { created = await creation.WaitAsync(TimeSpan.FromSeconds(3)); }
            catch
            {
                _ = creation.ContinueWith(async value =>
                {
                    if (value.IsCompletedSuccessfully) { value.Result.backend.Dispose(); await value.Result.proxy.DisposeAsync(); }
                    _ = value.Exception;
                }, TaskScheduler.Default).Unwrap();
                throw;
            }
            updates = new WindowsUpdateService(post, created.backend, created.proxy, state: state);
            updates.Changed += value => island?.SetUpdateInputSuspended(value.Busy);
            updateChannel = channel;
        }
        catch (Exception error) when (WindowsUpdateService.Recoverable(error)) { /* Fixed placeholder; never expose a feed path or key. */ }
    }
    private async Task StartWindowsUpdaterAsync(string[] arguments)
    {
        if (quitting || updates == null || ui == null) return;
        if (arguments.Contains("--update-failed")) island?.SetStatus(ui.Text("windows.updates.install_failed"));
        if (updateChannel != null && updateIdentity != null)
        {
            var build = updateChannel.TestCurrentBuild ?? WindowsUpdateVersion.Read(typeof(App).Assembly);
            await updates.InitializeAsync(updateChannel, build.ToString(3), build.ToString(), ui.Language,
                preferences.AutomaticUpdates, updateIdentity, Quit);
        }
        int resultIndex = Array.IndexOf(arguments, "--update-result");
        if (resultIndex < 0 || resultIndex + 1 >= arguments.Length || updateIdentity == null || updateState == null) return;
        try
        {
            var result = await Task.Run(() => UpdateHandoff.ConsumeResult(updateIdentity, arguments[resultIndex + 1], updateState, WindowsUpdateVersion.Read(typeof(App).Assembly))).WaitAsync(TimeSpan.FromSeconds(3));
            if (result == null || quitting) return;
            if (!result.Success) { island?.SetStatus(ui.Text("windows.updates.install_failed")); return; }
            // Notes are signed inline text, selected from the same build's
            // English/Chinese feed entries. No browser or remote notes page.
            updateNotes = new Window { Title = ui.Text("whats_new.window_title"), Width = 580, Height = 460,
                WindowStartupLocation = WindowStartupLocation.CenterScreen, FontFamily = PacerFonts.Interface };
            WindowRendering.Prepare(updateNotes);
            var text = new TextBox { Text = result.Notes, IsReadOnly = true, TextWrapping = TextWrapping.Wrap, BorderThickness = new Thickness(0), Margin = new Thickness(20),
                VerticalScrollBarVisibility = ScrollBarVisibility.Auto };
            updateNotes.Content = text; island?.SetUpdateInputSuspended(true);
            updateNotes.Closed += (_, _) => { updateNotes = null; island?.SetUpdateInputSuspended(updates.Status.Busy); };
            updateNotes.Show(); updateNotes.Activate();
        }
        catch (Exception error) when (WindowsUpdateService.Recoverable(error)) { island?.SetStatus(ui.Text("windows.updates.install_failed")); }
    }
}
