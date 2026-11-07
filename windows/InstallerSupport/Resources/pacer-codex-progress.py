"""Read-only stdio MCP reporter for Windows Pacer."""

import json
from pathlib import Path
import stat
import sys


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


def enabled(flag):
    try:
        facts = flag.lstat()
        if not stat.S_ISREG(facts.st_mode) or facts.st_size != 3 or getattr(facts, "st_file_attributes", 0) & 0x400:
            return False
        with flag.open("rb") as source:
            return source.read(4) == b"on\n"
    except OSError:
        return False


def respond(message, flag):
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
        text = "pacer-progress:accepted" if valid else (
            "Expected an integer from 0 to 100." if active else "Pacer task progress is disabled."
        )
        result = {"content": [{"type": "text", "text": text}], "isError": not valid}
    else:
        reply["error"] = {"code": -32601, "message": "Method not found"}
        return reply
    reply["result"] = result
    return reply


def serve(home):
    flag = Path(home) / "pacer" / "codex-progress" / "native" / "enabled"
    while True:
        line = sys.stdin.buffer.readline(LIMIT + 1)
        if not line or len(line) > LIMIT:
            return
        try:
            reply = respond(json.loads(line), flag)
        except (ValueError, UnicodeError, RecursionError):
            continue
        if reply is not None:
            print(json.dumps(reply, separators=(",", ":")), flush=True)


if __name__ == "__main__" and len(sys.argv) == 2:
    serve(sys.argv[1])
