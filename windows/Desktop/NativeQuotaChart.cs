using System;
using System.Threading.Tasks;
namespace CodexPacer.Windows;
internal sealed class NativeQuotaChart
{
    internal NativeQuotaChart(string directory) { }
    internal QuotaChartMarker[] Layout(QuotaChartPresentation chart, double plotWidth)
    {
        if (!double.IsFinite(plotWidth) || plotWidth < 43 || plotWidth > 10000) throw new ArgumentOutOfRangeException(nameof(plotWidth));
        return ShellProjection.Read<QuotaChartMarker[]>("layoutQuotaChart", new { chart, plotWidth }).Value ?? [];
    }
    internal Task<QuotaChartMarker[]> LayoutAsync(QuotaChartPresentation chart, double plotWidth)
        => ShellProjection.QueryAsync<QuotaChartMarker[]>("layoutQuotaChart", new { chart, plotWidth });
}
