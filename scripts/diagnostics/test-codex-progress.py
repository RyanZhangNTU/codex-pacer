"""Run a real Codex CLI and a Pacer host (Windows engine or Mac app) against a loopback model fixture."""

import argparse
from contextlib import ExitStack
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import os
from pathlib import Path
import plistlib
import queue
import shutil
import subprocess
import tempfile
import threading
import time
import tomllib
import uuid


ROOT = Path(__file__).resolve().parents[2]
CREATE_NO_WINDOW = getattr(subprocess, "CREATE_NO_WINDOW", 0)
REPORTS = [63, 41]
MAC_QA_ID = "com.codexpacer.app.qa.codex-progress"
MAC_OWNER = {"PACER_CODEX_PROGRESS_OWNER": "codex-pacer-progress-v2"}
MAC_SETUP = {"ready": "Progress reporting is ready for new local Codex sessions.",
             "conflict": "The Codex MCP configuration already has an entry named pacer_progress."}
MAC_RING = {"working": "Self-reported progress about %d%%", "done": "Request done", "failed": "Failed at a self-reported %d%%"}
# Lists a process's windows, or prints the accessibility text of its windows
# one element per line. SwiftUI builds the tree once a client asks for it.
MAC_HELPER = r"""
import ApplicationServices
import CoreGraphics
import Foundation

let pid = Int32(CommandLine.arguments[2])!
if CommandLine.arguments[1] == "windows" {
    let list = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] ?? []
    for window in list where window[kCGWindowOwnerPID as String] as? Int32 == pid {
        let bounds = window[kCGWindowBounds as String] as? [String: Double] ?? [:]
        print(window[kCGWindowNumber as String] ?? 0, window[kCGWindowLayer as String] ?? 0,
              (window[kCGWindowIsOnscreen as String] as? Bool) == true, bounds["Width"] ?? 0, bounds["Height"] ?? 0)
    }
    exit(0)
}
let app = AXUIElementCreateApplication(pid)
AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue)
func value(_ element: AXUIElement, _ name: String) -> AnyObject? {
    var result: AnyObject?
    return AXUIElementCopyAttributeValue(element, name as CFString, &result) == .success ? result : nil
}
func walk(_ element: AXUIElement, depth: Int) {
    guard depth < 40 else { return }
    for name in [kAXDescriptionAttribute, kAXTitleAttribute, kAXValueAttribute] {
        if let text = value(element, name) as? String, !text.isEmpty { print(text.replacingOccurrences(of: "\n", with: " ")) }
    }
    for child in value(element, kAXChildrenAttribute) as? [AXUIElement] ?? [] { walk(child, depth: depth + 1) }
}
for window in value(app, kAXWindowsAttribute) as? [AXUIElement] ?? [] { walk(window, depth: 0) }
"""


class Lines:
    def __init__(self, argv, cwd, env):
        self.process = subprocess.Popen(argv, cwd=cwd, env=env, stdin=subprocess.PIPE,
                                        stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                                        text=True, encoding="utf-8", creationflags=CREATE_NO_WINDOW)
        self.queue = queue.Queue()
        self.sequence = 0
        self.snapshot = None
        self.reader = threading.Thread(target=self.read, daemon=True)
        self.reader.start()

    def read(self):
        for line in self.process.stdout:
            try:
                self.queue.put(json.loads(line))
            except ValueError:
                pass
        self.queue.put(None)

    def send(self, message):
        self.process.stdin.write(json.dumps(message) + "\n")
        self.process.stdin.flush()

    def rpc(self, method, params=None, engine=False, mcp=False):
        self.sequence += 1
        request_id = str(self.sequence) if engine else self.sequence
        message = {"id": request_id, "method": method}
        if engine:
            message["protocolVersion"] = 1
        if mcp:
            message["jsonrpc"] = "2.0"
        if params is not None:
            message["params"] = params
        self.send(message)
        deadline = time.monotonic() + 15
        while time.monotonic() < deadline:
            row = self.queue.get(timeout=max(0.01, deadline - time.monotonic()))
            if row is None:
                raise RuntimeError("The test subprocess exited during " + method)
            if row.get("type") == "snapshot":
                self.snapshot = row
            if row.get("id") == request_id:
                if "error" in row or row.get("ok") is False:
                    raise RuntimeError("The test subprocess rejected " + method)
                return row.get("result")
        raise RuntimeError("Timed out waiting for " + method)

    def __enter__(self):
        return self

    def __exit__(self, *_):
        if self.process.stdin:
            self.process.stdin.close()
        try:
            self.process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            self.process.kill()
            self.process.wait(timeout=5)
        self.process.stdout.close()


def wait_setup(engine, predicate):
    deadline = time.monotonic() + 20
    status = None
    while time.monotonic() < deadline:
        engine.rpc("refresh", {"discover": False}, engine=True)
        status = (engine.snapshot or {}).get("codexProgressSetup")
        if predicate(status):
            return
        time.sleep(.1)
    raise RuntimeError("Unexpected reporter setup status: " + str(status))


def configuration(codex_executable, profile, enabled):
    return {"enabledProviders": ["codex"], "codexHome": str(profile), "codexExecutable": str(codex_executable),
            "codexProgressRing": enabled, "monitorRemoteControl": False, "monitorSSH": False, "monitorWSL": False}


def configure_from_engine(executable, codex_executable, profile, work, env):
    config = profile / "config.toml"
    flag = profile / "pacer/codex-progress/native/enabled"
    with Lines([str(executable)], work, env) as engine:
        engine.rpc("initialize", configuration(codex_executable, profile, False), engine=True)
        engine.rpc("configure", {"codexProgressRing": True}, engine=True)
        wait_setup(engine, lambda status: status == "ready")
        if (profile / "hooks.json").exists() or flag.read_bytes() != b"on\n":
            raise RuntimeError("Unexpected file changes from MCP-only setup")
        ready = config.read_bytes()
        engine.rpc("retryCodexProgressSetup", engine=True)
        wait_setup(engine, lambda status: status == "ready")
        if config.read_bytes() != ready:
            raise RuntimeError("Retry rewrote the current registration")
        engine.rpc("configure", {"codexProgressRing": False}, engine=True)
        def servers():
            return tomllib.loads(config.read_text(encoding="utf-8"))["mcp_servers"]
        wait_setup(engine, lambda _: not flag.exists() and "pacer_progress" not in servers())
        if servers() != {"unrelated_fixture": {"command": "keep-existing-mcp", "enabled": False}}:
            raise RuntimeError("An unrelated MCP entry changed")
        clean = config.read_bytes()
        with config.open("a", encoding="utf-8") as output:
            output.write('\n[mcp_servers.pacer_progress]\ncommand = "fixture-owner"\n')
        conflict = config.read_bytes()
        engine.rpc("configure", {"codexProgressRing": True}, engine=True)
        wait_setup(engine, lambda status: status == "conflict")
        if config.read_bytes() != conflict or flag.exists():
            raise RuntimeError("Setup did not preserve a same-name user entry")
        config.write_bytes(clean)
        engine.rpc("retryCodexProgressSetup", engine=True)
        wait_setup(engine, lambda status: status == "ready")
        engine.rpc("shutdown", engine=True)


class Fixture:
    def __init__(self, terminal):
        self.terminal = terminal
        self.requests = 0
        self.guidance_seen = False
        self.sent = []
        self.received = [threading.Event(), threading.Event()]
        self.resume = [threading.Event(), threading.Event()]

    def handler(self):
        fixture = self

        class Responses(BaseHTTPRequestHandler):
            def log_message(self, *_):
                pass

            def do_GET(self):
                self.send_error(404)

            def do_POST(self):
                length = int(self.headers.get("Content-Length", "0"))
                if not self.path.endswith("/responses") or not 0 < length <= 3 * 1024 * 1024:
                    self.send_error(404)
                    return
                request = json.loads(self.rfile.read(length))
                fixture.requests += 1
                index = fixture.requests
                if index == 1:
                    fixture.guidance_seen = "first useful tool batch" in json.dumps(request.get("tools", []))
                if 2 <= index <= 3:
                    fixture.received[index - 2].set()
                    if not fixture.resume[index - 2].wait(90):
                        self.send_error(408)
                        return
                if index == 3 and fixture.terminal == "failed":
                    self.write_response(400, "application/json", json.dumps({"error": {
                        "message": "Synthetic terminal error", "type": "invalid_request_error"
                    }}).encode())
                    return
                if index <= 2:
                    tools = request.get("tools", [])
                    namespace = next((tool for tool in tools if tool.get("type") == "namespace"
                                      and tool.get("name") == "mcp__pacer_progress"
                                      and any(t.get("name") == "report_progress" for t in tool.get("tools", []))), None)
                    name = "report_progress" if namespace else "mcp__pacer_progress__report_progress"
                    if namespace is None and not any(tool.get("name") == name for tool in tools):
                        self.send_error(422)
                        return
                    percent = REPORTS[index - 1]
                    fixture.sent.append(percent)
                    item = {"type": "function_call", "id": "fc_" + str(index), "call_id": "call_" + str(index),
                            "name": name, "arguments": json.dumps({"percent": percent}), "status": "completed"}
                    if namespace:
                        item["namespace"] = namespace["name"]
                else:
                    item = {"id": "msg_" + str(index), "type": "message", "role": "assistant", "status": "completed",
                            "content": [{"type": "output_text", "text": "Synthetic progress check done.", "annotations": []}]}
                response = {"id": "resp_" + str(index), "model": request.get("model"), "object": "response",
                            "output": [], "status": "in_progress"}
                finished = dict(response, output=[item], status="completed", usage={
                    "input_tokens": 100, "output_tokens": 10, "total_tokens": 110,
                    "input_tokens_details": {"cached_tokens": 0}, "output_tokens_details": {"reasoning_tokens": 0}})
                events = [("response.created", {"response": response}),
                          ("response.output_item.added", {"output_index": 0, "item": item}),
                          ("response.output_item.done", {"output_index": 0, "item": item}),
                          ("response.completed", {"response": finished})]
                body = "".join("event: %s\ndata: %s\n\n" % (event, json.dumps(dict(fields, type=event)))
                               for event, fields in events).encode()
                self.write_response(200, "text/event-stream", body)

            def write_response(self, status, content_type, data):
                self.send_response(status)
                self.send_header("Content-Type", content_type)
                self.send_header("Content-Length", str(len(data)))
                self.end_headers()
                self.wfile.write(data)

        return Responses


def check_ring(engine, profile, mode, fraction):
    deadline = time.monotonic() + 12
    last = []
    while time.monotonic() < deadline:
        engine.rpc("refresh", {"discover": True}, engine=True)
        files = list((profile / "sessions").glob("**/rollout-*.jsonl"))
        if len(files) == 1:
            expected = "local:" + files[0].stem[-36:].lower()
            rows = ((engine.snapshot or {}).get("presentation") or {}).get("rows", [])
            last = [(row.get("progressMode"), row.get("progressFraction")) for row in rows if row.get("id") == expected]
            if (mode, fraction) in last:
                return
        time.sleep(0.1)
    raise RuntimeError("Expected ring %s at %.2f; observed %s" % (mode, fraction, last))


def wait_turn(server, thread):
    deadline = time.monotonic() + 18
    while time.monotonic() < deadline:
        row = server.queue.get(timeout=max(0.01, deadline - time.monotonic()))
        if row is None:
            raise RuntimeError("Codex exited during the test turn")
        if row.get("method") == "turn/completed" and row["params"]["threadId"] == thread:
            return row["params"]["turn"]["status"]
    raise RuntimeError("Timed out waiting for the Codex turn")


class MacHost:
    """A disposable copy of the built Mac app with its own preferences domain.

    Pacer allows one instance per user, so the copy needs every other Pacer to
    be quit. Launch arguments point it at the fixture profile with only the
    Codex module, and its Settings window opens on the Codex pane.
    """

    def __init__(self, source, workspace, profile, codex, env, shots):
        self.profile, self.codex, self.env, self.shots = profile, codex, env, shots
        self.config = profile / "config.toml"
        self.flag = profile / "pacer/codex-progress/native/enabled"
        self.app = workspace / "Codex Pacer QA.app"
        self.process = None
        others = [row for row in subprocess.run(["ps", "-axo", "args="], capture_output=True, text=True).stdout.splitlines()
                  if "Contents/MacOS/CodexPacerIsland" in row and "--codex-progress-mcp" not in row]
        if others:
            raise RuntimeError("Quit Pacer before the macOS check; it allows one instance per user")
        shutil.copytree(source, self.app, symlinks=True)
        info_path = self.app / "Contents/Info.plist"
        info = plistlib.loads(info_path.read_bytes())
        info.update(CFBundleIdentifier=MAC_QA_ID, CFBundleName="Codex Pacer QA")
        info.pop("SUFeedURL", None)
        info_path.write_bytes(plistlib.dumps(info))
        subprocess.run(["codesign", "--force", "--sign", "-", str(self.app)], check=True, capture_output=True)
        self.executable = self.app / "Contents/MacOS/CodexPacerIsland"
        self.helper = workspace / "pacer-ui"
        (workspace / "pacer-ui.swift").write_text(MAC_HELPER, encoding="utf-8")
        subprocess.run(["xcrun", "swiftc", "-O", "-o", str(self.helper), str(workspace / "pacer-ui.swift")],
                       check=True, capture_output=True)
        subprocess.run(["defaults", "delete", MAC_QA_ID], capture_output=True)

    def __enter__(self):
        return self

    def __exit__(self, *_):
        self.quit()
        subprocess.run(["defaults", "delete", MAC_QA_ID], capture_output=True)

    def launch(self, enabled):
        self.quit()
        # Flags follow the defaults pairs so each `-key value` parses as one setting.
        argv = [str(self.executable), "-appLanguage", "en", "-settingsPane", "codex",
                "-codexHome", str(self.profile), "-codexExecutable", self.codex,
                "-codexProgressRing", "YES" if enabled else "NO", "-providerModule.codex", "enabled",
                "-providerModule.claude", "disabled", "-providerModule.deepseek", "disabled",
                "-monitorSSH", "NO", "-monitorRemoteControl", "NO", "--settings", "--expanded"]
        self.process = subprocess.Popen(argv, env=self.env, stdin=subprocess.DEVNULL,
                                        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        time.sleep(2)
        if self.process.poll() is not None:
            raise RuntimeError("The macOS copy exited at launch")

    def quit(self):
        if self.process and self.process.poll() is None:
            self.process.terminate()
            try:
                self.process.wait(timeout=10)
            except subprocess.TimeoutExpired:
                self.process.kill()
                self.process.wait(timeout=5)
        self.process = None

    def labels(self):
        result = subprocess.run([str(self.helper), "ax", str(self.process.pid)], capture_output=True, text=True, timeout=15)
        return result.stdout.splitlines()

    def wait_label(self, accept, description, timeout=20):
        deadline = time.monotonic() + timeout
        seen = []
        while time.monotonic() < deadline:
            seen = self.labels()
            if any(accept(label) for label in seen):
                return
            time.sleep(0.25)
        self.capture("failure")
        if self.shots:
            (self.shots / "failure-labels.txt").write_text("\n".join(seen), encoding="utf-8")
        rows = [label for label in seen if label.startswith("Codex, ") or "progress" in label.lower()]
        raise RuntimeError("The macOS app did not show %s; saw %s" % (description, rows))

    def capture(self, name):
        if not self.shots:
            return
        rows = [line.split() for line in subprocess.run([str(self.helper), "windows", str(self.process.pid)],
                                                         capture_output=True, text=True).stdout.splitlines()]
        shown = [row for row in rows if len(row) == 5 and row[2] == "true"]
        for kind, layer in (("island", "25"), ("settings", "0")):
            match = [row for row in shown if row[1] == layer]
            if match:
                window = max(match, key=lambda row: float(row[3]) * float(row[4]))[0]
                subprocess.run(["screencapture", "-x", "-o", "-l", window, str(self.shots / ("%s-%s.png" % (name, kind)))])

    def entry(self):
        return tomllib.loads(self.config.read_text(encoding="utf-8")).get("mcp_servers", {}).get("pacer_progress")

    def wait_setup(self, state):
        self.wait_label(lambda label: label == MAC_SETUP[state], "setup " + state)

    def registered(self):
        # Pacer standardizes paths, so /private/tmp may come back as /tmp.
        entry = self.entry() or {}
        args = entry.get("args") or []
        return (set(entry) == {"command", "args", "env"} and entry["env"] == MAC_OWNER and len(args) == 2
                and args[0] == "--codex-progress-mcp" and Path(args[1]).resolve() == self.profile.resolve()
                and Path(entry["command"]).resolve() == self.executable.resolve())

    def check_setup(self):
        self.launch(True)
        self.wait_setup("ready")
        self.capture("setup-ready")
        if not self.registered() or self.flag.read_bytes() != b"on\n" or (self.profile / "hooks.json").exists():
            raise RuntimeError("Unexpected registration from the macOS switch: %s" % self.entry())
        ready = self.config.read_bytes()
        self.launch(True)
        self.wait_setup("ready")
        if self.config.read_bytes() != ready:
            raise RuntimeError("A relaunch rewrote the current registration")
        self.launch(False)
        deadline = time.monotonic() + 20
        while time.monotonic() < deadline and (self.flag.exists() or self.entry() is not None):
            time.sleep(0.2)
        if self.flag.exists() or self.entry() is not None:
            raise RuntimeError("Turning the macOS switch off left the registration")
        if tomllib.loads(self.config.read_text(encoding="utf-8"))["mcp_servers"] != {
                "unrelated_fixture": {"command": "keep-existing-mcp", "enabled": False}}:
            raise RuntimeError("An unrelated MCP entry changed")
        clean = self.config.read_bytes()
        with self.config.open("a", encoding="utf-8") as output:
            output.write('\n[mcp_servers.pacer_progress]\ncommand = "fixture-owner"\n')
        conflict = self.config.read_bytes()
        self.launch(True)
        self.wait_setup("conflict")
        self.capture("setup-conflict")
        if self.config.read_bytes() != conflict or self.flag.exists():
            raise RuntimeError("Setup did not preserve a same-name user entry")
        self.config.write_bytes(clean)
        self.launch(True)
        self.wait_setup("ready")
        print("PASS macOS switch: register, keep, disable, conflict and recover", flush=True)

    def check_ring(self, mode, fraction):
        text = MAC_RING[mode] % round(fraction * 100) if "%" in MAC_RING[mode] else MAC_RING[mode]
        self.wait_label(lambda label: label.startswith("Codex, ") and text in label, repr(text), timeout=75)
        self.capture("ring-%s-%d" % (mode, round(fraction * 100)))


def run(args, workspace):
    profile = workspace / "profile"
    work = workspace / "work"
    profile.mkdir()
    work.mkdir()
    env = {key: value for key, value in os.environ.items() if key.upper() not in
           {"OPENAI_API_KEY", "CODEX_API_KEY", "HTTP_PROXY", "HTTPS_PROXY", "ALL_PROXY"}}
    appdata = workspace / "appdata"
    appdata.mkdir()
    env.update(CODEX_HOME=str(profile), LOCALAPPDATA=str(appdata), APPDATA=str(appdata), NO_PROXY="127.0.0.1,localhost")
    fixture = Fixture(args.terminal)
    with ThreadingHTTPServer(("127.0.0.1", 0), fixture.handler()) as server, ExitStack() as processes:
        threading.Thread(target=server.serve_forever, daemon=True).start()
        processes.callback(server.shutdown)
        config = profile / "config.toml"
        config.write_text("""model = "pacer-fixture"
model_provider = "pacer_test"
approval_policy = "never"
sandbox_mode = "read-only"
web_search = "disabled"
[mcp_servers.unrelated_fixture]
command = "keep-existing-mcp"
enabled = false
[features]
tool_search = false
code_mode = false
plugins = false
[model_providers.pacer_test]
name = "Pacer synthetic model"
base_url = "http://127.0.0.1:%d/v1"
wire_api = "responses"
request_max_retries = 0
stream_max_retries = 0
""" % server.server_port, encoding="utf-8")
        exe = str(args.codex.resolve())
        app = None
        if args.client == "app-server":
            app = processes.enter_context(Lines([exe, "app-server"], work, env))
            app.rpc("initialize", {"clientInfo": {"name": "pacer_progress_fixture", "version": "1"}})
            app.send({"method": "initialized"})
        engine = None
        if args.mac_app:
            host = processes.enter_context(MacHost(args.mac_app.resolve(), workspace, profile, exe, env, args.screenshots))
            host.check_setup()
            check = host.check_ring
        else:
            executable = args.engine.resolve()
            configure_from_engine(executable, exe, profile, work, env)
            engine = processes.enter_context(Lines([str(executable), "--read-only-diagnostics"], work, env))
            engine.rpc("initialize", {"enabledProviders": ["codex"], "codexHome": str(profile), "codexProgressRing": True,
                                      "monitorRemoteControl": False, "monitorSSH": False, "monitorWSL": False}, engine=True)
            def check(mode, fraction):
                check_ring(engine, profile, mode, fraction)
        codex = None
        try:
            prompt = "Run the synthetic progress check."
            if app:
                thread = app.rpc("thread/start", {"cwd": str(work)})["thread"]["id"]
                app.rpc("turn/start", {"threadId": thread, "input": [{"type": "text", "text": prompt, "text_elements": []}]})
            else:
                codex = subprocess.Popen([exe, "exec", "--skip-git-repo-check", "--json", prompt], cwd=work, env=env,
                                         stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                                         creationflags=CREATE_NO_WINDOW)
            for index, percent in enumerate(REPORTS):
                if not fixture.received[index].wait(15):
                    raise RuntimeError("Codex did not execute the expected reporter call")
                check("working", percent / 100)
                print("PASS live report: %d%%" % percent, flush=True)
                fixture.resume[index].set()
            success = wait_turn(app, thread) == "completed" if app else codex.wait(timeout=18) == 0
            if success != (args.terminal == "done"):
                raise RuntimeError("Unexpected Codex terminal outcome")
            check(args.terminal, 1 if args.terminal == "done" else REPORTS[-1] / 100)
            if not fixture.guidance_seen or fixture.sent != REPORTS:
                raise RuntimeError("The tool metadata did not supply the progress guidance")
        finally:
            for event in fixture.resume:
                event.set()
            if codex and codex.poll() is None:
                codex.kill()
                codex.wait(timeout=5)
        if engine:
            engine.rpc("shutdown", engine=True)
    print("PASS %s %s: automatic MCP setup, model guidance, %s, cleanup and ownership"
          % ("macOS app" if args.mac_app else "engine", args.client, args.terminal))


def installer_fixture(engine, codex):
    app = engine.parent.parent
    identity = json.loads((app / "installation-identity.json").read_bytes())
    scope = uuid.UUID(identity["qaScope"]).hex
    if not app.parent.parent.name.startswith("pacer-install-check-"):
        raise RuntimeError("The reporter fixture requires an isolated QA installation")
    data = app.parent / ("CodexPacer-QA-" + scope)
    runtime = data / "CodexProgressRuntime"
    for name in ("codex", "Codex secondary profile"):
        profile = data / name
        profile.mkdir()
        config = profile / "config.toml"
        config.write_text('[mcp_servers.unrelated_fixture]\ncommand = "preserve"\nenabled = false\n', encoding="utf-8")
        env = dict(os.environ, CODEX_HOME=str(profile), APPDATA=str(data), LOCALAPPDATA=str(data))
        with Lines([str(engine), "--codex-progress-runtime-root", str(runtime)], profile, env) as host:
            host.rpc("initialize", configuration(codex, profile, True), engine=True)
            wait_setup(host, lambda status: status == "ready")
            host.rpc("shutdown", engine=True)
        entry = tomllib.loads(config.read_text(encoding="utf-8"))["mcp_servers"]["pacer_progress"]
        if not Path(entry["command"]).resolve().is_relative_to(runtime.resolve()):
            raise RuntimeError("The installed reporter executable must live outside the application payload")
        if name == "codex":
            primary = entry
    print(json.dumps(primary))


def check_mac_reporter(executable, home):
    flag = home / "pacer/codex-progress/native/enabled"
    flag.parent.mkdir(parents=True)
    flag.write_bytes(b"on\n")
    with Lines([str(executable), "--codex-progress-mcp", str(home)], home, os.environ) as reporter:
        initialized = reporter.rpc("initialize", {"protocolVersion": "2025-06-18"}, mcp=True)
        tools = reporter.rpc("tools/list", mcp=True)["tools"]
        if initialized["serverInfo"]["name"] != "pacer_progress" or tools[0]["name"] != "report_progress":
            raise RuntimeError("The bundled macOS reporter did not initialize")
        args = {"name": "report_progress", "arguments": {"percent": 41}}
        if reporter.rpc("tools/call", args, mcp=True)["isError"]:
            raise RuntimeError("The bundled macOS reporter rejected a valid estimate")
        flag.unlink()
        if not reporter.rpc("tools/call", args, mcp=True)["isError"]:
            raise RuntimeError("The bundled macOS reporter kept reporting after disable")
    print("PASS macOS app bundle: stdio reporter starts, reports and respects disable")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--codex", type=Path)
    parser.add_argument("--engine", type=Path)
    parser.add_argument("--installer-fixture", action="store_true")
    parser.add_argument("--mac-reporter", type=Path)
    parser.add_argument("--mac-app", type=Path, help="a built Codex Pacer.app; the check runs a disposable copy of it")
    parser.add_argument("--screenshots", type=Path, help="with --mac-app, save island and Settings captures here")
    parser.add_argument("--terminal", choices=("done", "failed"), default="done")
    parser.add_argument("--client", choices=("cli", "app-server"), default="cli")
    parser.add_argument("--output", type=Path, default=ROOT / "output/codex-progress-tests")
    args = parser.parse_args()
    if not args.mac_reporter and not (args.codex and (args.engine or args.mac_app)):
        parser.error("Provide --mac-reporter, or --codex with --engine or --mac-app.")
    if args.engine and args.mac_app:
        parser.error("Choose either the Windows engine or the macOS app.")
    if args.screenshots:
        args.screenshots.mkdir(parents=True, exist_ok=True)
        args.screenshots = args.screenshots.resolve()
    if args.installer_fixture:
        if args.mac_reporter or args.mac_app:
            parser.error("The installer fixture needs a Windows engine and Codex CLI.")
        installer_fixture(args.engine.resolve(), args.codex.resolve())
        return
    args.output.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="fixture-", dir=args.output.resolve()) as workspace:
        if args.mac_reporter:
            check_mac_reporter(args.mac_reporter.resolve(), Path(workspace))
        else:
            run(args, Path(workspace))


if __name__ == "__main__":
    main()
