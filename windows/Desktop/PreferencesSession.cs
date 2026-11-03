using System;
using System.Text.Json;
using System.Threading;
using System.Threading.Tasks;

namespace CodexPacer.Windows;

internal enum PreferencesApplyResult { Applied, Invalid, EngineFailed, SaveFailed, RecoveryRequired }

/// Serializes immediate settings edits against the acknowledged engine state.
internal sealed class PreferencesSession
{
    private readonly SemaphoreSlim changes = new(1, 1);
    private readonly Func<object, Task> configure;
    private readonly Func<DesktopPreferences, bool> save;
    private readonly Func<DesktopPreferences, Task<DesktopPreferences>>? acknowledge;
    internal DesktopPreferences Current { get; private set; }
    internal bool RequiresRestart { get; private set; }
    internal event Action<DesktopPreferences>? Changed;

    internal PreferencesSession(DesktopPreferences initial, Func<object, Task> configure, Func<DesktopPreferences, bool> save,
        Func<DesktopPreferences, Task<DesktopPreferences>>? acknowledge = null)
    {
        if (!initial.IsValid) throw new ArgumentException("Invalid initial preferences.");
        Current = initial; this.configure = configure; this.save = save; this.acknowledge = acknowledge;
    }

    internal Task<PreferencesApplyResult> ChangeAsync(Func<DesktopPreferences, DesktopPreferences> edit)
        => ChangeAsync(value => Task.FromResult(edit(value)));
    internal Task<PreferencesApplyResult> RecoverDefaultsAsync(Func<DesktopPreferences, bool> confirmedSave)
        => ChangeAsync(_ => Task.FromResult(new DesktopPreferences()), confirmedSave);
    internal async Task<PreferencesApplyResult> ChangeAsync(Func<DesktopPreferences, Task<DesktopPreferences>> edit, Func<DesktopPreferences, bool>? confirmedSave = null)
    {
        await changes.WaitAsync();
        try
        {
            if (RequiresRestart) return PreferencesApplyResult.RecoveryRequired;
            DesktopPreferences previous = Current, next;
            try { next = await edit(previous); }
            catch (Exception error) when (error is System.IO.IOException or OperationCanceledException or EngineCommandException)
            { return PreferencesApplyResult.EngineFailed; }
            if (!next.IsValid) return PreferencesApplyResult.Invalid;
            if (acknowledge != null)
            {
                try { next = await acknowledge(next); }
                catch (Exception error) when (error is System.IO.IOException or OperationCanceledException or EngineCommandException or TimeoutException)
                { return PreferencesApplyResult.EngineFailed; }
                if (!next.IsValid) return PreferencesApplyResult.Invalid;
            }
            bool engineChanged = JsonSerializer.Serialize(previous.EngineConfiguration()) != JsonSerializer.Serialize(next.EngineConfiguration());
            if (engineChanged)
            {
                try { await configure(next.EngineConfiguration()); }
                catch (EngineCommandException) { return PreferencesApplyResult.EngineFailed; }
                catch (Exception error) when (error is System.IO.IOException or OperationCanceledException)
                {
                    // A lost acknowledgement may follow an applied command.
                    if (!await Restore(previous)) return PreferencesApplyResult.RecoveryRequired;
                    return PreferencesApplyResult.EngineFailed;
                }
            }
            if (!await Task.Run(() => (confirmedSave ?? save)(next)))
            {
                if (engineChanged)
                {
                    if (!await Restore(previous)) return PreferencesApplyResult.RecoveryRequired;
                }
                return PreferencesApplyResult.SaveFailed;
            }
            Current = next;
            Changed?.Invoke(next);
            return PreferencesApplyResult.Applied;
        }
        finally { changes.Release(); }
    }

    private async Task<bool> Restore(DesktopPreferences previous)
    {
        try { await configure(previous.EngineConfiguration()); return true; }
        catch (Exception error) when (error is System.IO.IOException or OperationCanceledException or EngineCommandException)
        { RequiresRestart = true; return false; }
    }

    internal async Task WaitForChangesAsync() { await changes.WaitAsync(); changes.Release(); }
}
