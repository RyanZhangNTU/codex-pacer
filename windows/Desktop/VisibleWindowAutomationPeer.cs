using System.Collections.Generic;
using System.Windows;
using System.Windows.Automation.Peers;

namespace CodexPacer.Windows;

internal sealed class VisibleWindowAutomationPeer(Window owner) : WindowAutomationPeer(owner)
{
    protected override List<AutomationPeer>? GetChildrenCore() => ((Window)Owner).IsVisible ? base.GetChildrenCore() : [];
}

internal sealed partial class SettingsWindow
{
    protected override AutomationPeer OnCreateAutomationPeer() => new VisibleWindowAutomationPeer(this);
}
