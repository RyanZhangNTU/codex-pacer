using System.Collections.Generic;
using System.Windows.Automation.Peers;
using System.Windows.Controls;

namespace CodexPacer.Windows;

/// A reading is announced once; its drawn values and caption are decorative.
internal class QuotaReadingHost : StackPanel
{
    protected override AutomationPeer OnCreateAutomationPeer() => new ReadingPeer(this);
    private sealed class ReadingPeer(QuotaReadingHost owner) : FrameworkElementAutomationPeer(owner)
    {
        protected override AutomationControlType GetAutomationControlTypeCore() => AutomationControlType.Text;
        protected override string GetClassNameCore() => "PacerQuotaReading";
        protected override List<AutomationPeer>? GetChildrenCore() => null;
    }
}
