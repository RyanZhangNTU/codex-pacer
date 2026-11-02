using System.Collections.Generic;
using System.Windows;
using System.Windows.Automation.Peers;
using System.Windows.Controls;

namespace CodexPacer.Windows;

public sealed class RevealHost : Grid
{
    private bool accessible;
    internal bool IsAccessible => accessible;
    internal void SetAccessible(bool value)
    {
        if (value == accessible) return;
        accessible = value;
        if (UIElementAutomationPeer.FromElement(this) is AutomationPeer peer)
        {
            peer.ResetChildrenCache();
            peer.InvalidatePeer();
        }
    }
    protected override AutomationPeer OnCreateAutomationPeer() => new RevealPeer(this);
    private sealed class RevealPeer(RevealHost host) : FrameworkElementAutomationPeer(host)
    {
        protected override AutomationControlType GetAutomationControlTypeCore() => AutomationControlType.Group;
        protected override string GetClassNameCore() => "PacerPanel";
        protected override bool IsControlElementCore() => host.accessible;
        protected override List<AutomationPeer>? GetChildrenCore() => host.accessible ? base.GetChildrenCore() : [];
    }
}
