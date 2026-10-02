#!/usr/bin/env python3
"""Bounded, opt-in exploration of Desktop IPC; never writes task state.

This private protocol is intentionally kept outside the production collector.
Only event counts, enum markers and numeric output counters leave this process.
"""
import argparse
import collections
import json
import os
import pathlib
import select
import socket
import stat
import struct
import time
import uuid

MAX_FRAME = 16 * 1024 * 1024
MAX_BYTES = 128 * 1024 * 1024
MAX_SUBSCRIPTIONS = 4
STREAM_VERSION = 11
KNOWN_METHODS = {
    "initialize", "thread-stream-state-changed", "thread-stream-following-changed",
    "thread-stream-following-status-requested", "client-status-changed",
    "client-discovery-request", "request", "response",
}
ITEM_TYPES = {
    "agentMessage", "reasoning", "commandExecution", "functionCall",
    "functionCallOutput", "mcpToolCall", "collabAgentToolCall", "webSearch",
    "fileChange", "userMessage", "plan",
}
STATUSES = {"active", "idle", "inProgress", "completed", "failed", "interrupted"}


def frame(message):
    body = json.dumps(message, separators=(",", ":")).encode()
    return struct.pack("<I", len(body)) + body


class Decoder:
    def __init__(self):
        self.buffer = bytearray()
        self.max_frame = 0

    def feed(self, data):
        self.buffer.extend(data)
        while len(self.buffer) >= 4:
            size = struct.unpack_from("<I", self.buffer)[0]
            if size == 0 or size > MAX_FRAME:
                raise ValueError("frame-limit")
            if len(self.buffer) < size + 4:
                return
            self.max_frame = max(self.max_frame, size)
            message = json.loads(self.buffer[4:size + 4])
            del self.buffer[:size + 4]
            if not isinstance(message, dict):
                raise ValueError("invalid-envelope")
            yield message, size


def valid_thread(value):
    try:
        return str(uuid.UUID(value)) == value.lower()
    except (ValueError, TypeError, AttributeError):
        return False


def output_count(usage):
    if not isinstance(usage, dict):
        return None
    total = usage.get("total")
    value = total.get("outputTokens") if isinstance(total, dict) else None
    return value if type(value) is int and 0 <= value < 2**63 else None


def is_review(state):
    model = state.get("latestModel")
    if isinstance(model, str) and model.lower().startswith("codex-auto-review"):
        return True
    for key in ("source", "threadSource", "agentRole"):
        value = state.get(key)
        if isinstance(value, str) and value.lower().replace("_", "") in {
            "guardian", "guardianreview", "autoreview", "subagentreview",
        }:
            return True
        if isinstance(value, dict):
            sub = value.get("subAgent")
            if sub == "review" or isinstance(sub, dict) and "review" in sub:
                return True
    return False


class Metrics:
    def __init__(self):
        self.methods = collections.Counter()
        self.markers = collections.Counter()
        self.snapshot_item_types = collections.Counter()
        self.patch_item_types = collections.Counter()
        self.item_statuses = collections.Counter()
        self.statuses = collections.Counter()
        self.snapshots = 0
        self.patches = 0
        self.snapshot_bytes = 0
        self.patch_bytes = 0
        self.version_mismatches = 0
        self.output_counters = []

    def observe(self, message, size):
        method = message.get("method", message.get("type"))
        self.methods[method if method in KNOWN_METHODS else "other"] += 1

    def usage(self, usage):
        value = output_count(usage)
        if value is not None:
            self.markers["output-counter"] += 1
            if len(self.output_counters) < 64:
                self.output_counters.append(value)

    def item(self, item, snapshot=False):
        if isinstance(item, dict) and item.get("type") in ITEM_TYPES:
            counts = self.snapshot_item_types if snapshot else self.patch_item_types
            counts[item["type"]] += 1
            status = item.get("status")
            if isinstance(status, str) and status in STATUSES:
                self.item_statuses[item["type"] + "." + status] += 1

    def snapshot(self, state, size):
        self.snapshots += 1
        self.snapshot_bytes += size
        self.usage(state.get("latestTokenUsageInfo"))
        runtime = state.get("threadRuntimeStatus")
        if isinstance(runtime, dict) and runtime.get("type") in STATUSES:
            self.statuses[runtime["type"]] += 1
        # Examine only active turns. Historical bodies are never retained.
        turns = state.get("turns", [])
        history = state.get("turnHistory")
        if isinstance(history, dict) and history.get("kind") == "canonical":
            entities = history.get("history", {}).get("entitiesByKey", {})
            turns = entities.values() if isinstance(entities, dict) else []
        for turn in turns:
            if isinstance(turn, dict) and turn.get("status") == "inProgress":
                self.statuses["inProgress"] += 1
                for item in turn.get("items", []):
                    self.item(item, snapshot=True)

    def patch(self, change, size):
        self.patches += 1
        self.patch_bytes += size
        # Paths are inspected in memory, never printed: they can contain UUIDs.
        for patch in change.get("patches", []):
            if not isinstance(patch, dict) or not isinstance(patch.get("path"), list):
                continue
            path = patch["path"]
            value = patch.get("value")
            if not path:
                continue
            if path[0] == "latestTokenUsageInfo":
                if len(path) == 1:
                    self.usage(value)
                elif path == ["latestTokenUsageInfo", "total", "outputTokens"]:
                    self.usage({"total": {"outputTokens": value}})
            if "commandExecutionStartedAtMsById" in path:
                self.markers["command-start"] += 1
            if "items" in path:
                self.markers["item-update"] += 1
                self.item(value)
            if path[-1] == "status" and isinstance(value, str) and value in STATUSES:
                self.statuses[value] += 1
            if path[0] == "threadRuntimeStatus":
                self.markers["runtime-status"] += 1
                kind = value.get("type") if isinstance(value, dict) else value
                if isinstance(kind, str) and kind in STATUSES:
                    self.statuses[kind] += 1
        changes = change.get("acceptedTextChanges")
        if isinstance(changes, list):
            self.markers["accepted-text-change"] += len(changes)

    def report(self):
        return {
            "eventCounts": dict(self.methods), "snapshots": self.snapshots,
            "patches": self.patches, "snapshotBytes": self.snapshot_bytes,
            "patchBytes": self.patch_bytes, "versionMismatches": self.version_mismatches,
            "markers": dict(self.markers), "snapshotItemTypes": dict(self.snapshot_item_types),
            "patchItemTypes": dict(self.patch_item_types), "itemStatusEnums": dict(self.item_statuses),
            "statusEnums": dict(self.statuses), "outputCounters": self.output_counters,
        }


class Observer:
    def __init__(self, follow=False, threads=()):
        self.follow = follow
        self.threads = set(threads)
        self.client_id = None
        self.subscribed = set()
        self.excluded = set()
        self.received_streams = set()
        self.pending_following = []
        self.metrics = Metrics()

    def following(self, thread, following):
        return {"type": "broadcast", "method": "thread-stream-following-changed",
                "sourceClientId": self.client_id, "version": 1,
                "params": {"hostId": "local", "conversationId": thread, "following": following}}

    def consume(self, message, size, observe=True):
        if observe:
            self.metrics.observe(message, size)
        kind, method = message.get("type"), message.get("method")
        if kind == "response" and method == "initialize" and message.get("resultType") == "success":
            value = message.get("result", {}).get("clientId")
            if valid_thread(value):
                self.client_id = value
            pending, self.pending_following = self.pending_following, []
            return [reply for queued in pending for reply in self.consume(queued, 0, observe=False)]
        # Refuse every routed operation; this observer owns no task.
        if kind == "client-discovery-request":
            return [{"type": "client-discovery-response", "requestId": message.get("requestId"),
                     "response": {"canHandle": False}}]
        if kind == "request":
            return [{"type": "response", "requestId": message.get("requestId"),
                     "resultType": "error", "error": "no-handler-for-request"}]
        if kind != "broadcast":
            return []
        if not self.client_id:
            params, targets = message.get("params"), message.get("targetClientIds")
            if (self.follow and method == "thread-stream-following-changed" and message.get("version") == 1
                    and isinstance(params, dict) and params.get("hostId") == "local"
                    and params.get("following") is True and valid_thread(params.get("conversationId"))
                    and len(self.pending_following) < MAX_SUBSCRIPTIONS
                    and (targets is None or isinstance(targets, list) and len(targets) <= 64
                         and all(isinstance(target, str) and len(target) <= 64 for target in targets))):
                self.pending_following.append({"type": kind, "method": method, "version": 1,
                    "targetClientIds": targets, "params": {"hostId": "local", "following": True,
                    "conversationId": params["conversationId"]}})
            return []
        targets = message.get("targetClientIds")
        if targets is not None and (not isinstance(targets, list) or self.client_id not in targets):
            return []
        params = message.get("params")
        if not isinstance(params, dict) or params.get("hostId") != "local":
            return []
        thread = params.get("conversationId")
        if not valid_thread(thread):
            return []
        if method == "thread-stream-following-changed" and message.get("version") == 1:
            if (self.follow and params.get("following") is True and thread not in self.excluded
                    and thread not in self.subscribed and len(self.subscribed) < MAX_SUBSCRIPTIONS
                    and (not self.threads or thread in self.threads)):
                self.subscribed.add(thread)
                return [self.following(thread, True)]
        if method != "thread-stream-state-changed" or thread not in self.subscribed:
            return []
        if message.get("version") != STREAM_VERSION:
            self.metrics.version_mismatches += 1
            return []
        change = params.get("change")
        if not isinstance(change, dict):
            return []
        if change.get("type") == "snapshot":
            state = change.get("conversationState")
            if not isinstance(state, dict):
                return []
            if is_review(state):
                self.subscribed.discard(thread)
                self.excluded.add(thread)
                return [self.following(thread, False)]
            self.received_streams.add(thread)
            self.metrics.snapshot(state, size)
        elif change.get("type") == "patches" and thread in self.received_streams:
            self.metrics.patch(change, size)
        return []


def checked_endpoint(home):
    directory = pathlib.Path(home) / "ipc"
    path = directory / "ipc.sock"
    for item, expected in ((directory, stat.S_ISDIR), (path, stat.S_ISSOCK)):
        info = item.lstat()
        if info.st_uid != os.getuid() or info.st_mode & 0o077 or not expected(info.st_mode):
            raise ValueError("unsafe-endpoint")
    return path


def run(args):
    observer = Observer(args.follow_local, args.thread)
    decoder = Decoder()
    started, cpu = time.monotonic(), time.process_time()
    received = loops = 0
    reason = "duration"
    connection = None
    try:
        path = checked_endpoint(args.codex_home)
        connection = socket.socket(socket.AF_UNIX)
        connection.settimeout(2)
        connection.connect(str(path))
        connection.sendall(frame({"type": "request", "method": "initialize", "version": 0,
                                  "requestId": str(uuid.uuid4()), "sourceClientId": "initializing-client",
                                  "params": {"clientType": "codex-pacer-probe"}}))
        deadline = started + args.seconds
        while time.monotonic() < deadline:
            ready, _, _ = select.select([connection], [], [], max(0, deadline - time.monotonic()))
            loops += 1
            if not ready:
                break
            data = connection.recv(65536)
            if not data:
                reason = "peer-closed"
                break
            received += len(data)
            if received > MAX_BYTES:
                reason = "byte-limit"
                break
            for message, size in decoder.feed(data):
                for reply in observer.consume(message, size):
                    connection.sendall(frame(reply))
    except KeyboardInterrupt:
        reason = "interrupted"
    except (OSError, ValueError, TypeError, KeyError, AttributeError, RecursionError):
        reason = "endpoint-or-protocol-error"
    finally:
        if connection is not None:
            try:
                for thread in observer.subscribed:
                    connection.sendall(frame(observer.following(thread, False)))
            except OSError:
                pass
            connection.close()
    return {"seconds": round(time.monotonic() - started, 3), "initialized": bool(observer.client_id),
            "mode": "follow-local" if args.follow_local else "passive", "closeReason": reason,
            "subscriptionsRequested": len(observer.subscribed), "streamsReceived": len(observer.received_streams),
            "excludedReviews": len(observer.excluded), "receivedBytes": received,
            "maxFrameBytes": decoder.max_frame, "helperCpuSeconds": round(time.process_time() - cpu, 6),
            "eventLoopIterations": loops, **observer.metrics.report()}


def main():
    parser = argparse.ArgumentParser(description="短时检查本机 Desktop IPC；只输出事件计数。")
    parser.add_argument("--seconds", type=int, choices=range(5, 61), default=20, metavar="5..60")
    parser.add_argument("--codex-home", default=os.environ.get("CODEX_HOME", str(pathlib.Path.home() / ".codex")))
    parser.add_argument("--follow-local", action="store_true", help="订阅最多四个已广播的本机会话流")
    parser.add_argument("--thread", action="append", default=[], help="仅订阅指定 UUID；可重复")
    args = parser.parse_args()
    if any(not valid_thread(thread) for thread in args.thread):
        parser.error("thread 必须是 UUID")
    args.thread = [thread.lower() for thread in args.thread]
    print(json.dumps(run(args), ensure_ascii=False, separators=(",", ":")))


if __name__ == "__main__":
    main()
