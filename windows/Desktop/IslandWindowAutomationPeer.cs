using System.Windows;
using System.Windows.Automation;
using System.Windows.Automation.Peers;
using System.Windows.Automation.Provider;

namespace CodexPacer.Windows;

internal sealed class IslandWindowAutomationPeer(IslandWindow owner) : WindowAutomationPeer(owner), IExpandCollapseProvider
{
    protected override Rect GetBoundingRectangleCore() => ((IslandWindow)Owner).VisibleScreenBounds;
    public override object? GetPattern(PatternInterface patternInterface)
        => patternInterface == PatternInterface.ExpandCollapse ? this : base.GetPattern(patternInterface);
    ExpandCollapseState IExpandCollapseProvider.ExpandCollapseState
        => owner.IsExpandedForAutomation ? ExpandCollapseState.Expanded : ExpandCollapseState.Collapsed;
    void IExpandCollapseProvider.Expand() => owner.Reveal();
    void IExpandCollapseProvider.Collapse() => owner.CollapseForAutomation();
}
