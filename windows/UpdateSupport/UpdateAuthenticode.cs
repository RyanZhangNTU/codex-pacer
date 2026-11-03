using System;
using System.IO;
using System.Runtime.InteropServices;
using System.Security.Cryptography;

namespace CodexPacer.Windows;

internal static class UpdateAuthenticode
{
    internal static bool Verify(string path, string expectedSigner)
    {
        UpdateFiles.Check(path);
        IntPtr name = Marshal.StringToCoTaskMemUni(Path.GetFullPath(path)), infoPointer = IntPtr.Zero;
        var policy = new Guid("00aac56b-cd44-11d0-8cc2-00c04fc295ee");
        var data = new TrustData();
        try
        {
            var info = new FileInfoData { Size = (uint)Marshal.SizeOf<FileInfoData>(), Path = name };
            infoPointer = Marshal.AllocHGlobal(Marshal.SizeOf<FileInfoData>()); Marshal.StructureToPtr(info, infoPointer, false);
            data = new TrustData { Size = (uint)Marshal.SizeOf<TrustData>(), UI = 2, Choice = 1, File = infoPointer, Action = 1,
                // Use cached OS trust without causing certificate-network or
                // system permission prompts. Ed25519 and the signer pin are
                // required independently; no trust store is modified.
                Flags = 0x1000 | 0x10 };
            if (WinVerifyTrust(new IntPtr(-1), ref policy, ref data) != 0) return false;
            IntPtr provider = WTHelperProvDataFromStateData(data.State);
            IntPtr signer = WTHelperGetProvSignerFromChain(provider, 0, false, 0);
            IntPtr cert = WTHelperGetProvCertFromChain(signer, 0);
            if (cert == IntPtr.Zero) return false;
            var wrapper = Marshal.PtrToStructure<ProviderCert>(cert);
            var context = Marshal.PtrToStructure<CertContext>(wrapper.Cert);
            if (context.Length is 0 or > 65536) return false;
            byte[] encoded = new byte[context.Length]; Marshal.Copy(context.Encoded, encoded, 0, encoded.Length);
            return string.Equals(Convert.ToHexString(SHA256.HashData(encoded)), expectedSigner, StringComparison.OrdinalIgnoreCase);
        }
        finally
        {
            if (data.State != IntPtr.Zero) { data.Action = 2; _ = WinVerifyTrust(new IntPtr(-1), ref policy, ref data); }
            if (infoPointer != IntPtr.Zero) Marshal.FreeHGlobal(infoPointer); Marshal.FreeCoTaskMem(name);
        }
    }
    [StructLayout(LayoutKind.Sequential)] private struct FileInfoData { internal uint Size; internal IntPtr Path, Handle, KnownSubject; }
    [StructLayout(LayoutKind.Sequential)] private struct TrustData
    {
        internal uint Size; internal IntPtr PolicyCallback, SIP;
        internal uint UI, Revocation, Choice; internal IntPtr File; internal uint Action;
        internal IntPtr State, URL; internal uint Flags, Context; internal IntPtr SignatureSettings;
    }
    [StructLayout(LayoutKind.Sequential)] private struct ProviderCert { internal uint Size; internal IntPtr Cert; }
    [StructLayout(LayoutKind.Sequential)] private struct CertContext { internal uint Encoding; internal IntPtr Encoded; internal uint Length; internal IntPtr Info, Store; }
    [DllImport("wintrust.dll", ExactSpelling = true)] private static extern int WinVerifyTrust(IntPtr window, ref Guid action, ref TrustData data);
    [DllImport("wintrust.dll")] private static extern IntPtr WTHelperProvDataFromStateData(IntPtr state);
    [DllImport("wintrust.dll")] private static extern IntPtr WTHelperGetProvSignerFromChain(IntPtr data, uint index, [MarshalAs(UnmanagedType.Bool)] bool counterSigner, uint counterIndex);
    [DllImport("wintrust.dll")] private static extern IntPtr WTHelperGetProvCertFromChain(IntPtr signer, uint index);
}
