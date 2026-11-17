using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.Diagnostics;
using System.IO;
using System.IO.Pipes;
using System.Runtime.InteropServices;
using System.Text;
using Microsoft.Win32.SafeHandles;

namespace CodexPacer.Windows;

/// <summary>A started engine and the three pipes the client talks through.</summary>
internal sealed class EngineChild : IDisposable
{
    private readonly Action closeInput;
    private readonly IDisposable[] owned;
    internal Process Process { get; }
    internal Stream Input { get; }
    internal Stream Output { get; }
    internal Stream Errors { get; }
    /// <summary>True when the engine was started with its low addresses reserved.</summary>
    internal bool Guarded { get; }

    internal EngineChild(Process process, Stream input, Stream output, Stream errors, Action closeInput, bool guarded, params IDisposable[] owned)
    {
        Process = process; Input = input; Output = output; Errors = errors;
        this.closeInput = closeInput; Guarded = guarded; this.owned = owned;
    }

    /// <summary>Ends the engine's input, which it reads as the request to leave.</summary>
    internal void CloseInput() => closeInput();
    public void Dispose()
    {
        foreach (IDisposable item in owned) item.Dispose();
        Process.Dispose();
    }
}

/// <summary>
/// Starts the engine so that no block of its heap lies below 2 GB.
///
/// Swift 6.4.2 keeps either a string's UTF-16 length or a pointer in one word of the
/// string's storage and takes any value up to <c>Int32.MaxValue</c> for a length
/// (swiftlang/swift#92199; no released toolchain has the fix yet). Windows places the
/// heap far above that while both bottom-up and high-entropy address randomization
/// apply to the process. Where either is turned off, the heap starts a few megabytes
/// up, a long non-ASCII string's length becomes a heap address, and Foundation stops
/// the engine.
///
/// Such an engine is created suspended, every free region below 2 GB is reserved in
/// it, and only then does it run: Windows creates its heap after the reservation.
/// Every other machine starts the engine as before.
/// </summary>
internal static class EngineLaunch
{
    // Windows maps nothing below 64 KB; a heap block at 2 GB or above is past Int32.MaxValue.
    private const ulong Lowest = 0x10000, Limit = 0x80000000, Granularity = 0x10000;
    private static readonly Lazy<bool> hostRandomized = new(() => { using var self = Process.GetCurrentProcess(); return Randomized(self.SafeHandle); });

    /// <param name="guard">Null decides by the address randomization in effect; tests force either way.</param>
    internal static EngineChild Start(ProcessStartInfo start, OwnedJob job, bool? guard = null)
    {
        // The app runs under the same system settings as its engine, so its own policy tells in advance.
        if (guard ?? !hostRandomized.Value) return Guarded(start, job);
        Process process = Process.Start(start) ?? throw new IOException("Could not start PacerEngine.");
        try
        {
            job.Attach(process);
            if (guard == null && !Randomized(process.SafeHandle))
            {
                // Only this program has randomization turned off. The engine has read nothing yet.
                try { process.Kill(); process.WaitForExit(); } catch (Exception error) when (error is InvalidOperationException or Win32Exception) { }
                process.Dispose();
                return Guarded(start, job);
            }
        }
        catch
        {
            try { process.Kill(); } catch (Exception error) when (error is InvalidOperationException or Win32Exception) { }
            process.Dispose();
            throw;
        }
        return new EngineChild(process, process.StandardInput.BaseStream, process.StandardOutput.BaseStream, process.StandardError.BaseStream,
            () => process.StandardInput.Close(), guarded: false);
    }

    /// <summary>True while Windows randomizes the process's heap far above 2 GB.</summary>
    internal static bool Randomized(SafeProcessHandle process)
    {
        // ProcessASLRPolicy: bit 0 is bottom-up randomization, bit 2 its high-entropy form.
        return GetProcessMitigationPolicy(process, 1, out uint flags, new IntPtr(sizeof(uint))) && (flags & 5) == 5;
    }

    /// <summary>The command line `CommandLineToArgvW` and the C runtime split back into these arguments.</summary>
    internal static string CommandLine(string executable, IEnumerable<string> arguments)
    {
        var text = new StringBuilder();
        Append(text, executable);
        foreach (string argument in arguments) { text.Append(' '); Append(text, argument); }
        return text.ToString();
    }

    private static void Append(StringBuilder text, string argument)
    {
        bool plain = argument.Length != 0;
        foreach (char character in argument) if (char.IsWhiteSpace(character) || character == '"') { plain = false; break; }
        if (plain) { text.Append(argument); return; }
        text.Append('"');
        for (int index = 0; index < argument.Length;)
        {
            char character = argument[index++];
            if (character == '\\')
            {
                int backslashes = 1;
                while (index < argument.Length && argument[index] == '\\') { index++; backslashes++; }
                // Backslashes are literal unless a quote follows them, the closing one included.
                if (index == argument.Length) text.Append('\\', backslashes * 2);
                else if (argument[index] == '"') { text.Append('\\', backslashes * 2 + 1).Append('"'); index++; }
                else text.Append('\\', backslashes);
            }
            else if (character == '"') text.Append('\\').Append('"');
            else text.Append(character);
        }
        text.Append('"');
    }

    /// <summary>Reserves every free region below 2 GB. Returns the bytes reserved and the regions that refused.</summary>
    internal static (ulong Reserved, int Failures) ReserveLowAddresses(SafeProcessHandle process)
    {
        ulong reserved = 0; int failures = 0;
        foreach (var (low, high) in FreeLowRegions(process))
        {
            // MEM_RESERVE, PAGE_NOACCESS: address space only, no memory and no page-file charge.
            if (VirtualAllocEx(process, new IntPtr((long)low), new IntPtr((long)(high - low)), 0x2000, 0x01) != IntPtr.Zero) reserved += high - low;
            else failures++;
        }
        return (reserved, failures);
    }

    /// <summary>The bytes below 2 GB that an allocation could still be given.</summary>
    internal static ulong FreeLowAddresses(SafeProcessHandle process)
    {
        ulong free = 0;
        foreach (var (low, high) in FreeLowRegions(process)) free += high - low;
        return free;
    }

    private static List<(ulong Low, ulong High)> FreeLowRegions(SafeProcessHandle process)
    {
        var regions = new List<(ulong, ulong)>();
        ulong address = Lowest;
        while (address < Limit)
        {
            if (VirtualQueryEx(process, new IntPtr((long)address), out MemoryInformation information, new IntPtr(Marshal.SizeOf<MemoryInformation>())) == IntPtr.Zero) break;
            ulong start = (ulong)information.BaseAddress.ToInt64(), end = start + (ulong)information.RegionSize.ToInt64();
            if (information.State == 0x10000) // MEM_FREE
            {
                // An allocation starts on a 64 KB boundary, so the free tail of a used block is out of reach.
                ulong low = (start + Granularity - 1) & ~(Granularity - 1), high = Math.Min(end, Limit);
                if (high > low) regions.Add((low, high));
            }
            if (end <= address) break;
            address = end;
        }
        return regions;
    }

    private static EngineChild Guarded(ProcessStartInfo start, OwnedJob job)
    {
        var input = new AnonymousPipeServerStream(PipeDirection.Out, HandleInheritability.Inheritable);
        var output = new AnonymousPipeServerStream(PipeDirection.In, HandleInheritability.Inheritable);
        var errors = new AnonymousPipeServerStream(PipeDirection.In, HandleInheritability.Inheritable);
        IntPtr attributes = IntPtr.Zero, handles = IntPtr.Zero;
        bool attributesReady = false;
        try
        {
            // Only these three handles reach the engine, whatever else the app has open.
            IntPtr[] inherited =
            {
                input.ClientSafePipeHandle.DangerousGetHandle(), output.ClientSafePipeHandle.DangerousGetHandle(),
                errors.ClientSafePipeHandle.DangerousGetHandle()
            };
            int handleBytes = IntPtr.Size * inherited.Length;
            handles = Marshal.AllocHGlobal(handleBytes);
            Marshal.Copy(inherited, 0, handles, inherited.Length);
            IntPtr size = IntPtr.Zero;
            InitializeProcThreadAttributeList(IntPtr.Zero, 1, 0, ref size);
            attributes = Marshal.AllocHGlobal(size);
            if (!InitializeProcThreadAttributeList(attributes, 1, 0, ref size)) throw new Win32Exception(Marshal.GetLastWin32Error());
            attributesReady = true;
            // PROC_THREAD_ATTRIBUTE_HANDLE_LIST
            if (!UpdateProcThreadAttribute(attributes, 0, new IntPtr(0x00020002), handles, new IntPtr(handleBytes), IntPtr.Zero, IntPtr.Zero))
                throw new Win32Exception(Marshal.GetLastWin32Error());
            var startup = new StartupInformation
            {
                Size = Marshal.SizeOf<StartupInformation>(), Flags = 0x100, // STARTF_USESTDHANDLES
                StandardInput = inherited[0], StandardOutput = inherited[1], StandardError = inherited[2], Attributes = attributes
            };
            // The engine gets the app's own environment, as it does from Process.Start; the start's environment table is not read.
            var command = new StringBuilder(CommandLine(start.FileName, start.ArgumentList));
            // CREATE_SUSPENDED | CREATE_UNICODE_ENVIRONMENT | EXTENDED_STARTUPINFO_PRESENT, and CREATE_NO_WINDOW
            uint flags = 0x4 | 0x400 | 0x00080000 | (start.CreateNoWindow ? 0x08000000u : 0);
            string? directory = string.IsNullOrEmpty(start.WorkingDirectory) ? null : start.WorkingDirectory;
            if (!CreateProcessW(start.FileName, command, IntPtr.Zero, IntPtr.Zero, true, flags, IntPtr.Zero, directory, ref startup, out ProcessInformation created))
                throw new Win32Exception(Marshal.GetLastWin32Error());
            using var handle = new SafeProcessHandle(created.Process, ownsHandle: true);
            Process? opened = null;
            try
            {
                // The first thread has not run: the process has no heap yet, and it gets none below the limit now.
                ReserveLowAddresses(handle);
                opened = Process.GetProcessById(created.ProcessId);
                // The object keeps a handle of its own, so the exit code outlives the process.
                _ = opened.SafeHandle;
                job.Attach(opened);
                if (ResumeThread(created.Thread) == uint.MaxValue) throw new Win32Exception(Marshal.GetLastWin32Error());
            }
            catch
            {
                TerminateProcess(handle, 1);
                opened?.Dispose();
                throw;
            }
            finally { CloseHandle(created.Thread); }
            Process process = opened;
            input.DisposeLocalCopyOfClientHandle(); output.DisposeLocalCopyOfClientHandle(); errors.DisposeLocalCopyOfClientHandle();
            return new EngineChild(process, input, output, errors, input.Dispose, guarded: true, input, output, errors);
        }
        catch
        {
            input.Dispose(); output.Dispose(); errors.Dispose();
            throw;
        }
        finally
        {
            if (attributesReady) DeleteProcThreadAttributeList(attributes);
            if (attributes != IntPtr.Zero) Marshal.FreeHGlobal(attributes);
            if (handles != IntPtr.Zero) Marshal.FreeHGlobal(handles);
        }
    }

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    private struct StartupInformation
    {
        public int Size;
        public string? Reserved, Desktop, Title;
        public int X, Y, Width, Height, ColumnCount, RowCount, FillAttribute, Flags;
        public short ShowWindow, ReservedSize;
        public IntPtr ReservedData, StandardInput, StandardOutput, StandardError;
        // STARTUPINFOEX
        public IntPtr Attributes;
    }
    [StructLayout(LayoutKind.Sequential)]
    private struct ProcessInformation { public IntPtr Process, Thread; public int ProcessId, ThreadId; }
    [StructLayout(LayoutKind.Sequential)]
    private struct MemoryInformation
    {
        public IntPtr BaseAddress, AllocationBase;
        public uint AllocationProtect;
        public ushort PartitionId;
        public IntPtr RegionSize;
        public uint State, Protect, Type;
    }

    [DllImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool GetProcessMitigationPolicy(SafeProcessHandle process, int policy, out uint flags, IntPtr length);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool CreateProcessW(string application, StringBuilder command, IntPtr processAttributes, IntPtr threadAttributes,
        [MarshalAs(UnmanagedType.Bool)] bool inherit, uint flags, IntPtr environment, string? directory, ref StartupInformation startup, out ProcessInformation information);
    [DllImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool InitializeProcThreadAttributeList(IntPtr list, int count, int flags, ref IntPtr size);
    [DllImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool UpdateProcThreadAttribute(IntPtr list, uint flags, IntPtr attribute, IntPtr value, IntPtr size, IntPtr previous, IntPtr returned);
    [DllImport("kernel32.dll")]
    private static extern void DeleteProcThreadAttributeList(IntPtr list);
    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern IntPtr VirtualQueryEx(SafeProcessHandle process, IntPtr address, out MemoryInformation information, IntPtr length);
    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern IntPtr VirtualAllocEx(SafeProcessHandle process, IntPtr address, IntPtr size, uint type, uint protect);
    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern uint ResumeThread(IntPtr thread);
    [DllImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool TerminateProcess(SafeProcessHandle process, uint code);
    [DllImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool CloseHandle(IntPtr handle);
}
