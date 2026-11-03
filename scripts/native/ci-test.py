#!/usr/bin/env python3
"""Keep stalled test output and stacks available before the CI job is killed."""
import argparse
import os
from pathlib import Path
import re
import selectors
import signal
import subprocess
import sys
import time


def sample_tests(parent, prefix):
    rows = subprocess.check_output(["ps", "-axo", "pid=,ppid=,comm="], text=True).splitlines()
    processes = []
    for row in rows:
        fields = row.strip().split(None, 2)
        if len(fields) == 3:
            processes.append((int(fields[0]), int(fields[1]), fields[2]))
    owned = {parent}
    while True:
        found = {pid for pid, ppid, _ in processes if ppid in owned}
        if found.issubset(owned):
            break
        owned.update(found)
    tests = [pid for pid, _, name in processes if pid in owned and (".xctest" in name or "PackageTests" in name)]
    for pid in tests[:4]:
        path = str(prefix) + "-sample-" + str(pid) + ".txt"
        try:
            subprocess.run(["/usr/bin/sample", str(pid), "2", "-file", path],
                           stdout=subprocess.DEVNULL, stderr=subprocess.STDOUT, timeout=8, check=False)
            print("Test watchdog saved a stack sample for owned test PID " + str(pid), flush=True)
        except (OSError, subprocess.TimeoutExpired):
            print("Test watchdog could not sample owned test PID " + str(pid), flush=True)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--timeout-seconds", type=float, default=1200)
    parser.add_argument("--diagnostics-prefix", type=Path, required=True)
    args = parser.parse_args()
    environment = dict(os.environ)
    environment["NSUnbufferedIO"] = "YES"
    child = subprocess.Popen(["make", "test"], stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                             start_new_session=True, env=environment)
    os.set_blocking(child.stdout.fileno(), False)
    selector = selectors.DefaultSelector()
    selector.register(child.stdout, selectors.EVENT_READ)
    deadline = time.monotonic() + args.timeout_seconds
    pending = set()
    line = bytearray()
    expired = False
    eof = False
    try:
        while not eof:
            if not expired and time.monotonic() >= deadline:
                expired = True
                print("\nTest watchdog reached the test-step deadline.", flush=True)
                for test in sorted(pending):
                    print("Last unfinished test: " + test, flush=True)
                sample_tests(child.pid, args.diagnostics_prefix)
                try:
                    os.killpg(child.pid, signal.SIGTERM)
                except ProcessLookupError:
                    pass
                deadline = time.monotonic() + 2
            if expired and time.monotonic() >= deadline:
                try:
                    os.killpg(child.pid, signal.SIGKILL)
                except ProcessLookupError:
                    pass
                break
            for key, _ in selector.select(timeout=0.1):
                data = os.read(key.fd, 65536)
                if not data:
                    eof = True
                    break
                sys.stdout.buffer.write(data)
                sys.stdout.buffer.flush()
                line.extend(data)
                while b"\n" in line:
                    row, _, remaining = line.partition(b"\n")
                    line = bytearray(remaining)
                    match = re.search(r"Test Case '([^']+)' (started|passed|failed)", row.decode("utf-8", errors="replace"))
                    if match:
                        if match[2] == "started":
                            pending.add(match[1])
                        else:
                            pending.discard(match[1])
        try:
            status = child.wait(timeout=3)
        except subprocess.TimeoutExpired:
            child.kill()
            status = 124
        return 124 if expired else status
    finally:
        selector.close()
        child.stdout.close()


if __name__ == "__main__":
    raise SystemExit(main())
