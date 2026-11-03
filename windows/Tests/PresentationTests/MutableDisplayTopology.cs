using System;
using System.Collections.Generic;
using CodexPacer.Windows;

internal sealed class MutableDisplayTopology(params DisplayMonitor[] values) : IDisplayTopologySource
{
    public IReadOnlyList<DisplayMonitor> Current { get; private set; } = Array.AsReadOnly((DisplayMonitor[])values.Clone());
    public event Action? Changed;
    internal bool Disposed;
    public void Refresh() { }
    internal void Set(params DisplayMonitor[] next) { Current = Array.AsReadOnly((DisplayMonitor[])next.Clone()); Changed?.Invoke(); }
    public void Dispose() => Disposed = true;
}
