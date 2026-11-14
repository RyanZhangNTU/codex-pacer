"""Run one CI step with measured memory headroom; never restart failed work."""
import os
import re
import signal
import subprocess
import sys
import time

RESERVE = 1536 * 1024 * 1024


def windows_snapshot():
    # Native calls avoid starting a PowerShell/CIM provider every five seconds,
    # which can itself stall during ARM64 runner initialization.
    import ctypes as c
    from ctypes import wintypes as w
    kernel = c.WinDLL('kernel32', use_last_error=True)
    class Memory(c.Structure):
        _fields_ = [('length', w.DWORD), ('load', w.DWORD)] + [(key, c.c_ulonglong) for key in
            ('total', 'available', 'totalPage', 'availablePage', 'totalVirtual', 'availableVirtual', 'extended')]
    class Process(c.Structure):
        _fields_ = [('size', w.DWORD), ('usage', w.DWORD), ('pid', w.DWORD), ('heap', c.c_size_t),
                    ('module', w.DWORD), ('threads', w.DWORD), ('parent', w.DWORD), ('priority', w.LONG),
                    ('flags', w.DWORD), ('exe', w.WCHAR * 260)]
    class Counters(c.Structure):
        _fields_ = [('size', w.DWORD), ('faults', w.DWORD)] + [(key, c.c_size_t) for key in
            ('peakWorking', 'working', 'peakPaged', 'paged', 'peakNonPaged', 'nonPaged', 'pagefile', 'peakPagefile')]
    kernel.GlobalMemoryStatusEx.argtypes = [c.POINTER(Memory)]
    kernel.CreateToolhelp32Snapshot.argtypes = [w.DWORD, w.DWORD]
    kernel.CreateToolhelp32Snapshot.restype = w.HANDLE
    kernel.Process32FirstW.argtypes = kernel.Process32NextW.argtypes = [w.HANDLE, c.POINTER(Process)]
    kernel.OpenProcess.argtypes = [w.DWORD, w.BOOL, w.DWORD]
    kernel.OpenProcess.restype = w.HANDLE
    kernel.K32GetProcessMemoryInfo.argtypes = [w.HANDLE, c.POINTER(Counters), w.DWORD]
    kernel.GetExitCodeProcess.argtypes = [w.HANDLE, c.POINTER(w.DWORD)]
    kernel.CloseHandle.argtypes = [w.HANDLE]
    memory = Memory(); memory.length = c.sizeof(memory)
    if not kernel.GlobalMemoryStatusEx(c.byref(memory)):
        raise c.WinError(c.get_last_error())
    handle = kernel.CreateToolhelp32Snapshot(2, 0)
    if handle == w.HANDLE(-1).value:
        raise c.WinError(c.get_last_error())
    rows = []
    try:
        entry = Process(); entry.size = c.sizeof(entry)
        present = kernel.Process32FirstW(handle, c.byref(entry))
        while present:
            process = kernel.OpenProcess(0x1000 | 0x10, False, entry.pid)
            rss = None
            exited = not process and c.get_last_error() == 87
            if process:
                try:
                    counters = Counters(); counters.size = c.sizeof(counters)
                    if kernel.K32GetProcessMemoryInfo(process, c.byref(counters), counters.size):
                        rss = counters.working
                    else:
                        status = w.DWORD()
                        exited = bool(kernel.GetExitCodeProcess(process, c.byref(status))) and status.value != 259
                finally:
                    kernel.CloseHandle(process)
            if not exited:
                rows.append((entry.pid, entry.parent, rss))
            present = kernel.Process32NextW(handle, c.byref(entry))
        if c.get_last_error() != 18:  # ERROR_NO_MORE_FILES
            raise c.WinError(c.get_last_error())
    finally:
        kernel.CloseHandle(handle)
    return memory.available, rows


def snapshot():
    if os.name == 'nt':
        return windows_snapshot()
    data = subprocess.check_output(['vm_stat'], text=True, timeout=10)
    page = int(re.search(r'page size of (\d+) bytes', data)[1])
    counters = dict((k, int(v)) for k, v in re.findall(r'^([^:]+):\s+(\d+)\.', data, re.M))
    available = page * sum(counters[k] for k in ['Pages free', 'Pages inactive', 'Pages speculative'])
    rows = subprocess.check_output(['ps', '-axo', 'pid=,ppid=,rss='], text=True, timeout=10)
    return available, [(int(p), int(parent), int(rss) * 1024) for p, parent, rss in (line.split() for line in rows.splitlines())]


def footprint(root, rows):
    owned = {root}
    while True:
        found = {pid for pid, parent, _ in rows if parent in owned}
        if found.issubset(owned):
            break
        owned.update(found)
    memory = [rss for pid, _, rss in rows if pid in owned]
    if any(rss is None for rss in memory):
        raise RuntimeError('Could not read an owned process memory footprint')
    return sum(memory)


def main():
    available, _ = snapshot()  # A failed read fails before launching the step.
    if available < RESERVE:
        raise RuntimeError('Insufficient free memory to start this step')
    print(f'Memory before step: {available // 1048576} MiB available', flush=True)
    env = dict(os.environ, DOTNET_PROCESSOR_COUNT='1', DOTNET_GCHeapHardLimit='80000000', PACER_BUILD_JOBS='1')
    child = subprocess.Popen(sys.argv[1:], env=env, **({'creationflags': subprocess.CREATE_NO_WINDOW} if os.name == 'nt' else {'start_new_session': True}))
    last_report = time.monotonic()
    try:
        while child.poll() is None:
            available, rows = snapshot()
            rss = footprint(child.pid, rows)
            if available < RESERVE:
                raise RuntimeError('Memory reserve reached; stopping this step')
            if time.monotonic() - last_report >= 30:
                print(f'Memory: {available // 1048576} MiB available; owned processes {rss // 1048576} MiB RSS', flush=True)
                last_report = time.monotonic()
            try:
                return child.wait(timeout=5)
            except subprocess.TimeoutExpired:
                pass
        return child.returncode
    finally:
        # The live Popen handle establishes ownership; only this step's tree is stopped.
        if child.poll() is None:
            if os.name == 'nt':
                subprocess.run(['taskkill', '/PID', str(child.pid), '/T', '/F'], check=False, creationflags=subprocess.CREATE_NO_WINDOW)
            else:
                os.killpg(child.pid, signal.SIGKILL)
            child.wait(timeout=15)


if __name__ == '__main__':
    sys.exit(main())
