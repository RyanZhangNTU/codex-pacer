using System;
using System.Runtime.InteropServices;
using Windows.ApplicationModel.DataTransfer;

namespace CodexPacer.Windows;

internal sealed record SupportSharePayload(Uri Link, string Title, string Message)
{
    internal static SupportSharePayload? Create(GuideCatalog catalog, UiText ui)
        => catalog.Links.TryGetValue("repository", out string? link)
            && Uri.TryCreate(link, UriKind.Absolute, out var uri)
            && uri.AbsoluteUri == "https://github.com/RyanZhangNTU/codex-pacer"
                ? new(uri, ui.Text("support.share.subject"), ui.Text("windows.support.share_message")) : null;
}

internal interface ISupportShareBackend : IDisposable
{
    bool Show(IntPtr owner, SupportSharePayload payload);
}

/// Only a public, fixed project link enters the system share sheet.
internal sealed class SupportShareSession(Func<ISupportShareBackend>? create = null) : IDisposable
{
    private ISupportShareBackend? backend;
    private bool disposed;
    internal bool Show(IntPtr owner, GuideCatalog catalog, UiText ui)
    {
        if (disposed || owner == IntPtr.Zero || SupportSharePayload.Create(catalog, ui) is not { } payload) return false;
        try { return (backend ??= (create?.Invoke() ?? new WindowsShareBackend())).Show(owner, payload); }
        catch (Exception error) when (error is COMException or InvalidOperationException or NotSupportedException) { return false; }
    }
    public void Dispose() { if (disposed) return; disposed = true; backend?.Dispose(); backend = null; }
}

internal sealed class WindowsShareBackend : ISupportShareBackend
{
    private DataTransferManager? manager;
    private SupportSharePayload? payload;
    private IntPtr owner;
    public bool Show(IntPtr owner, SupportSharePayload payload)
    {
        var interop = DataTransferManager.As<IDataTransferManagerInterop>();
        if (manager == null || this.owner != owner)
        {
            Dispose();
            Guid iid = new("A5CAEE9B-8708-49D1-8D36-67D25A8DA00C");
            IntPtr pointer = interop.GetForWindow(owner, ref iid);
            try { manager = WinRT.MarshalInterface<DataTransferManager>.FromAbi(pointer); }
            finally { Marshal.Release(pointer); }
            this.owner = owner; manager.DataRequested += DataRequested;
        }
        this.payload = payload; interop.ShowShareUIForWindow(owner); return true;
    }
    private void DataRequested(DataTransferManager sender, DataRequestedEventArgs args)
    {
        if (payload is not { } value) return;
        var data = args.Request.Data;
        data.Properties.Title = value.Title; data.Properties.Description = value.Message;
        data.SetWebLink(value.Link); data.SetText(value.Message + "\n" + value.Link.AbsoluteUri);
        data.RequestedOperation = DataPackageOperation.Copy;
    }
    public void Dispose()
    {
        if (manager != null) manager.DataRequested -= DataRequested;
        manager = null; payload = null; owner = IntPtr.Zero;
    }
    [ComImport, Guid("3A3DCD6C-3EAB-43DC-BCDE-45671CE800C8"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    private interface IDataTransferManagerInterop
    {
        IntPtr GetForWindow(IntPtr window, ref Guid iid);
        void ShowShareUIForWindow(IntPtr window);
    }
}
