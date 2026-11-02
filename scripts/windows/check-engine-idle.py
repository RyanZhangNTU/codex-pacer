"""Measure a live engine without recording protocol bodies or source paths."""
import argparse
import ctypes
from ctypes import wintypes
import json
import os
from pathlib import Path
import subprocess
import tempfile
import threading
import time


def cpu_seconds(process):
    kernel = ctypes.WinDLL("kernel32", use_last_error=True)
    kernel.GetProcessTimes.argtypes = [wintypes.HANDLE] + [ctypes.POINTER(wintypes.FILETIME)] * 4
    kernel.GetProcessTimes.restype = wintypes.BOOL
    values = [wintypes.FILETIME() for _ in range(4)]
    if not kernel.GetProcessTimes(wintypes.HANDLE(int(process._handle)), *(ctypes.byref(value) for value in values)):
        raise ctypes.WinError(ctypes.get_last_error())
    return sum((value.dwHighDateTime << 32) + value.dwLowDateTime for value in values[2:]) / 10_000_000


def check(engine, seconds, output, real_data=False):
    if os.name != "nt" or seconds < 120:
        raise ValueError("Run on Windows for at least 120 seconds")
    with tempfile.TemporaryDirectory(prefix="pacer-idle-") as temporary:
        root = Path(temporary)
        homes = {}
        for provider, folder in (("codex", "sessions"), ("claude", "projects"), ("deepseek", "sessions")):
            home = root / provider
            (home / folder).mkdir(parents=True)
            homes[provider + "Home"] = str(home)
        if real_data:
            if seconds < 300:
                raise ValueError("Real-data checks run for at least five minutes")
            user_home = Path.home()
            homes = {provider + "Home": str(Path(os.environ.get(variable) or user_home / folder))
                     for provider, variable, folder in (("codex", "CODEX_HOME", ".codex"),
                         ("claude", "CLAUDE_CONFIG_DIR", ".claude"), ("deepseek", "DSH_HOME", ".dsh"))}
        process = subprocess.Popen([str(engine)] + (["--read-only-diagnostics"] if real_data else []), stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                   creationflags=subprocess.CREATE_NO_WINDOW)
        hello, ready = threading.Event(), threading.Event()
        counts = {"frames": 0, "stderrBytes": 0, "protocolErrors": 0, "shutdownReplies": 0}

        def drain():
            for line in process.stdout:
                counts["frames"] += 1
                try:
                    message = json.loads(line)
                    if message.get("type") == "hello":
                        hello.set()
                    if message.get("type") == "snapshot":
                        ready.set()
                    if message.get("type") == "error":
                        counts["protocolErrors"] += 1
                    if message.get("type") == "result" and message.get("id") == "shutdown" and message.get("ok") is True:
                        counts["shutdownReplies"] += 1
                except (ValueError, TypeError):
                    counts["protocolErrors"] += 1

        def discard_stderr():
            while data := process.stderr.read(4096):
                counts["stderrBytes"] += len(data)

        def send(method, params=None):
            message = {"protocolVersion": 1, "id": method, "method": method}
            if params is not None:
                message["params"] = params
            process.stdin.write(json.dumps(message).encode() + b"\n")
            process.stdin.flush()

        readers = [threading.Thread(target=drain, daemon=True), threading.Thread(target=discard_stderr, daemon=True)]
        for reader in readers:
            reader.start()
        try:
            if not hello.wait(15):
                raise RuntimeError("Engine hello timed out")
            send("initialize", dict(homes, enabledProviders=["codex", "claude", "deepseek"], expanded=False,
                hideProjects=True, webAvailable=False, codexExecutable=str(root / "missing-codex.exe")))
            if not ready.wait(15):
                raise RuntimeError("Engine initialization timed out")
            time.sleep(5)
            started, cpu_started = time.monotonic(), cpu_seconds(process)
            print(f"Measuring initialized engine for {seconds} seconds; protocol bodies are discarded.", flush=True)
            until = time.monotonic() + seconds
            while time.monotonic() < until:
                time.sleep(min(10, max(0, until - time.monotonic())))
            elapsed, cpu = time.monotonic() - started, cpu_seconds(process) - cpu_started
            if process.poll() is not None:
                raise RuntimeError("Engine exited during idle measurement")
            if not real_data:
                # Only the isolated empty-home check changes a source.
                replacement = root / "codex-replacement"
                (replacement / "sessions").mkdir(parents=True)
                send("configure", {"codexHome": str(replacement)})
                time.sleep(1)
            shutdown = time.monotonic()
            send("shutdown")
            process.wait(timeout=3)
            shutdown = time.monotonic() - shutdown
            for reader in readers:
                reader.join(timeout=2)
            result = {"wallSeconds": round(elapsed, 3), "cpuSeconds": round(cpu, 4),
                "oneCorePercent": round(cpu / elapsed * 100, 3),
                "hostPercent": round(cpu / elapsed / (os.cpu_count() or 1) * 100, 3),
                "logicalProcessors": os.cpu_count(), "shutdownSeconds": round(shutdown, 4),
                "exitCode": process.returncode, "isolatedEmptyHomes": not real_data, "readOnlyRealData": real_data,
                "sourceMutationsRequested": not real_data, **counts}
            if output:
                output.parent.mkdir(parents=True, exist_ok=True)
                output.write_text(json.dumps(result, indent=2) + "\n", encoding="utf-8")
            print(json.dumps(result, sort_keys=True), flush=True)
            if process.returncode or counts["protocolErrors"] or counts["shutdownReplies"] != 1 or shutdown > 1:
                raise RuntimeError("Engine protocol or bounded shutdown check failed")
        finally:
            if process.poll() is None:
                process.kill()
                process.wait(timeout=5)
            for stream in (process.stdin, process.stdout, process.stderr):
                stream.close()


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--engine", required=True, type=Path)
    parser.add_argument("--seconds", type=int, default=120)
    parser.add_argument("--output", type=Path)
    parser.add_argument("--real-data", action="store_true", help="Read actual provider homes; disable quota clients and persistence")
    args = parser.parse_args()
    check(args.engine.resolve(), args.seconds, args.output, args.real_data)
