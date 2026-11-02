using System.Windows;
using System.Windows.Automation.Peers;

namespace CodexPacer.Windows;

internal sealed class IslandWindowAutomationPeer(IslandWindow owner) : WindowAutomationPeer(owner)
{
    protected override Rect GetBoundingRectangleCore() => ((IslandWindow)Owner).VisibleScreenBounds;
}
