"""Measure a Release synthetic shell without saving screenshots or task bodies."""
import argparse
import json
import os
from pathlib import Path
import queue
import subprocess
import threading
import time


def run(args):
    if os.name != "nt" or not 5 <= args.seconds <= 600:
        raise ValueError("Use Windows and a 5-600 second sample")
    args.output.mkdir(parents=True, exist_ok=False)
    environment = dict(os.environ)
    if args.side:
        environment["PACER_IDLE_SIDE"] = args.side
    if args.snapshot:
        environment["PACER_IDLE_SNAPSHOT"] = str(args.snapshot.resolve(strict=True))
    process = subprocess.Popen([str(args.probe), "idle", str(args.output)], stdin=subprocess.PIPE, env=environment,
                               stdout=subprocess.PIPE, stderr=subprocess.PIPE, creationflags=subprocess.CREATE_NO_WINDOW,
                               text=True, encoding="utf-8")
    messages = queue.Queue()
    errors = {"stderrBytes": 0, "protocolErrors": 0}

    def read():
        for line in process.stdout:
            try:
                messages.put(json.loads(line))
            except ValueError:
                errors["protocolErrors"] += 1

    def discard():
        for line in process.stderr:
            errors["stderrBytes"] += len(line.encode("utf-8"))

    for target in (read, discard):
        threading.Thread(target=target, daemon=True).start()

    def expect(kind, timeout=30):
        value = messages.get(timeout=timeout)
        if value.get("type") != kind:
            raise RuntimeError("Unexpected diagnostic response")
        return value

    def send(command, **values):
        process.stdin.write(json.dumps(dict(command=command, **values)) + "\n")
        process.stdin.flush()

    try:
        ready = expect("ready")
        print(json.dumps(ready), flush=True)
        send("surface", value=args.appearance)
        expect("surface")
        time.sleep(args.warmup)
        if args.trace:
            command = [str(args.trace), "collect", "--process-id", str(ready["pid"]), "--profile", "dotnet-sampled-thread-time,dotnet-common",
                       "--duration", "00:00:20", "--output", str(args.output / "shell.nettrace")]
            with (args.output / "trace-tool.log").open("w", encoding="utf-8") as log:
                subprocess.run(command, check=True, stdout=log, stderr=subprocess.STDOUT, timeout=60)
            time.sleep(2)
        results = []
        for state in args.states:
            send("state", value=state)
            expect("state")
            for ablation in args.ablations:
                send("ablation", value=ablation)
                expect("ablation")
                time.sleep(2)
                send("inspect")
                print(json.dumps(expect("inspect")), flush=True)
                send("sample", seconds=args.seconds)
                value = expect("sample", args.seconds + 30)
                results.append(value)
                (args.output / "result.json").write_text(json.dumps(dict(samples=results, **errors), indent=2), encoding="utf-8")
                print(json.dumps(value), flush=True)
        send("quit")
        expect("stopped")
        process.wait(timeout=5)
        if process.returncode or errors["protocolErrors"]:
            raise RuntimeError("Shell diagnostic process failed")
    finally:
        if process.poll() is None:
            process.kill()
            process.wait(timeout=5)
        for stream in (process.stdin, process.stdout, process.stderr):
            stream.close()


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--probe", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--seconds", type=int, default=300)
    parser.add_argument("--warmup", type=int, default=60)
    parser.add_argument("--states", nargs="+", choices=["collapsed", "expanded", "hidden", "covered"], default=["collapsed", "expanded", "hidden", "covered"])
    parser.add_argument("--ablations", nargs="+", choices=["none", "badge", "quota", "all", "collected"], default=["none"])
    parser.add_argument("--trace", type=Path)
    parser.add_argument("--appearance", choices=["classic", "liquidGlass"], default="classic")
    parser.add_argument("--side", choices=["left", "center", "right"], help="Place simultaneous probes at the quarter, center, or three-quarter monitor position")
    parser.add_argument("--snapshot", type=Path, help="Reuse one synthetic reference snapshot across binaries")
    run(parser.parse_args())
