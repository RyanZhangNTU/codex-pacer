"""Read-only stdio MCP reporter for Windows Pacer."""

import json
import os
from pathlib import Path
import re
import stat
import sys
import tempfile
import time


LIMIT = 1024 * 1024
SERVER = "pacer_progress"
TOOL = "report_progress"
GUIDANCE = (
    "Report your best estimate of how much of the user's current request is done. "
    "Call this tool with your first useful tool batch, after meaningful progress, and before a long wait. "
    "Use an integer from 0 to 100 and revise it downward when needed. Skip reports for short replies that need no tools."
)
DEFINITION = {
    "name": TOOL, "description": GUIDANCE,
    "inputSchema": {"type": "object", "properties": {"percent": {"type": "integer", "minimum": 0, "maximum": 100}},
                    "required": ["percent"], "additionalProperties": False},
    "annotations": {"readOnlyHint": True, "openWorldHint": False},
}
PROTOCOLS = ("2024-11-05", "2025-03-26", "2025-06-18", "2025-11-25")
UUID = re.compile(r"[0-9a-fA-F]{8}(?:-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}")
CALL_ID = re.compile(r"[a-zA-Z0-9._:-]{1,256}")
MARKER = b"codex-pacer-durable-progress-v1\n"


def ordinary(path, kind):
    facts = path.lstat()
    return kind(facts.st_mode) and not getattr(facts, "st_file_attributes", 0) & 0x400


def identifier(value, pattern):
    return value if isinstance(value, str) and pattern.fullmatch(value) else None


def durable_receipt(params, percent):
    meta = params.get("_meta")
    context = meta.get("x-codex-turn-metadata") if isinstance(meta, dict) else None
    if not isinstance(context, dict):
        return None
    thread = identifier(meta.get("threadId"), UUID)
    context_thread = identifier(context.get("thread_id"), UUID)
    turn = identifier(context.get("turn_id"), UUID)
    call = identifier(meta.get("callId"), CALL_ID)
    if not thread or not context_thread or thread.lower() != context_thread.lower() or not turn or not call:
        return None
    return {"threadID": thread.lower(), "turnID": turn.lower(), "callID": call, "percent": percent,
            "at": time.time() - 978307200}  # Swift's Date reference epoch.


def record_receipt(receipt, flag):
    import msvcrt

    root = flag.parents[1] / "durable-marketplace"
    directory = root / "receipts"
    marker, lock, snapshot = root / ".pacer-owner", directory / "write.lock", directory / "latest.json"
    tmp = None
    try:
        if not directory.is_absolute() or any(not ordinary(p, stat.S_ISDIR) for p in (directory, *directory.parents)):
            return
        if not ordinary(marker, stat.S_ISREG) or not ordinary(lock, stat.S_ISREG):
            return
        with marker.open("rb") as source:
            if source.read(len(MARKER) + 1) != MARKER:
                return
        with lock.open("r+b") as lease:
            for attempt in range(6):
                try:
                    msvcrt.locking(lease.fileno(), msvcrt.LK_NBLCK, 1)
                    break
                except OSError:
                    if attempt == 5:
                        return
                    time.sleep(0.005)
            if not enabled(flag):
                return
            records = {}
            try:
                if not ordinary(snapshot, stat.S_ISREG):
                    return
                with snapshot.open("rb") as source:
                    data = source.read(65537)
                if len(data) <= 65536:
                    value = json.loads(data)
                    if isinstance(value, dict) and len(value) <= 64:
                        records = {k: v for k, v in value.items() if isinstance(v, dict)
                                   and type(v.get("at")) in (float, int) and -5 <= receipt["at"] - v["at"] <= 900}
            except FileNotFoundError:
                pass
            key = receipt["threadID"] + ":" + receipt["turnID"]
            previous = records.get(key)
            if previous and (previous.get("callID") == receipt["callID"] or previous["at"] > receipt["at"]):
                return
            records[key] = receipt
            recent = dict(sorted(records.items(), key=lambda pair: pair[1]["at"], reverse=True)[:64])
            data = json.dumps(recent, separators=(",", ":")).encode("utf-8")
            if len(data) > 65536:
                return
            with tempfile.NamedTemporaryFile(dir=directory, prefix=".receipt-", delete=False) as target:
                tmp = target.name
                target.write(data)
            if enabled(flag):
                os.replace(tmp, snapshot)
                tmp = None
    except (OSError, ValueError, RecursionError):
        pass
    finally:
        if tmp is not None:
            try:
                os.unlink(tmp)
            except OSError:
                pass


def enabled(flag):
    try:
        facts = flag.lstat()
        if not stat.S_ISREG(facts.st_mode) or facts.st_size != 3 or getattr(facts, "st_file_attributes", 0) & 0x400:
            return False
        with flag.open("rb") as source:
            return source.read(4) == b"on\n"
    except OSError:
        return False


def respond(message, flag, durable=False):
    if (not isinstance(message, dict) or message.get("jsonrpc") != "2.0"
            or type(message.get("id")) not in (str, int)):
        return None
    method = message.get("method")
    params = message.get("params")
    if not isinstance(params, dict):
        params = {}
    reply = {"jsonrpc": "2.0", "id": message["id"]}
    if method == "initialize":
        protocol = params.get("protocolVersion")
        result = {"protocolVersion": protocol if protocol in PROTOCOLS else "2025-06-18",
                  "capabilities": {"tools": {}}, "serverInfo": {"name": SERVER, "version": "2.0.0"}}
        if enabled(flag):
            result["instructions"] = GUIDANCE
    elif method == "ping":
        result = {}
    elif method == "tools/list":
        result = {"tools": [DEFINITION] if enabled(flag) else []}
    elif method == "tools/call":
        active = enabled(flag)
        args = params.get("arguments")
        percent = args.get("percent") if isinstance(args, dict) else None
        valid = active and params.get("name") == TOOL and type(percent) is int and 0 <= percent <= 100 and len(args) == 1
        if valid and durable:
            receipt = durable_receipt(params, percent)
            if receipt:
                record_receipt(receipt, flag)
        text = "pacer-progress:accepted" if valid else (
            "Expected an integer from 0 to 100." if active else "Pacer task progress is disabled."
        )
        result = {"content": [{"type": "text", "text": text}], "isError": not valid}
    else:
        reply["error"] = {"code": -32601, "message": "Method not found"}
        return reply
    reply["result"] = result
    return reply


def serve(flag, durable=False):
    while True:
        line = sys.stdin.buffer.readline(LIMIT + 1)
        if not line or len(line) > LIMIT:
            return
        try:
            reply = respond(json.loads(line), flag, durable)
        except (ValueError, UnicodeError, RecursionError):
            continue
        if reply is not None:
            print(json.dumps(reply, separators=(",", ":")), flush=True)


if __name__ == "__main__":
    if len(sys.argv) == 3 and sys.argv[1] == "--pacer-progress-flag":
        flag = Path(sys.argv[2])
        if flag.is_absolute():
            serve(flag)
    elif len(sys.argv) == 2 or (len(sys.argv) == 3 and sys.argv[2] == "--durable"):
        serve(Path(sys.argv[1]) / "pacer" / "codex-progress" / "native" / "enabled", len(sys.argv) == 3)
