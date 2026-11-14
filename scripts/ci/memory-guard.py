"""Run one CI step with measured memory headroom; never restart failed work."""
import json
import os
import re
import signal
import subprocess
import sys
import time

RESERVE = 1536 * 1024 * 1024


def snapshot():
    if os.name == 'nt':
        code = "$ErrorActionPreference='Stop'; $m=Get-CimInstance Win32_OperatingSystem; $p=Get-CimInstance Win32_Process; @{available=[long]$m.FreePhysicalMemory*1024; processes=@($p|Select-Object ProcessId,ParentProcessId,WorkingSetSize)}|ConvertTo-Json -Compress"
        raw = subprocess.check_output(['powershell.exe', '-NoProfile', '-NonInteractive', '-Command', code],
                                      creationflags=subprocess.CREATE_NO_WINDOW, timeout=15)
        data = json.loads(raw)
        return data['available'], [(p['ProcessId'], p['ParentProcessId'], int(p['WorkingSetSize'])) for p in data['processes']]
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
    return sum(rss for pid, _, rss in rows if pid in owned)


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
