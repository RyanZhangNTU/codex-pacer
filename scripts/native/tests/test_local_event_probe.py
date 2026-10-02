import argparse
import importlib.util
import json
import os
import pathlib
import socket
import struct
import tempfile
import threading
import unittest

SCRIPT = pathlib.Path(__file__).resolve().parents[1] / "probe-local-events.py"
spec = importlib.util.spec_from_file_location("local_probe", SCRIPT)
probe = importlib.util.module_from_spec(spec)
spec.loader.exec_module(probe)
CLIENT = "019a0000-0000-7000-8000-000000000010"
THREAD = "019a0000-0000-7000-8000-000000000001"
OTHER = "019a0000-0000-7000-8000-000000000002"


def initialized():
    return {"type": "response", "method": "initialize", "resultType": "success",
            "result": {"clientId": CLIENT}}


def following(thread=THREAD, host="local"):
    return {"type": "broadcast", "method": "thread-stream-following-changed", "version": 1,
            "params": {"hostId": host, "conversationId": thread, "following": True}}


def snapshot(state=None, thread=THREAD, version=11):
    return {"type": "broadcast", "method": "thread-stream-state-changed", "version": version,
            "params": {"hostId": "local", "conversationId": thread,
                       "change": {"type": "snapshot", "revision": 2, "conversationState": state or {}}}}


class LocalProbeTests(unittest.TestCase):
    def observer(self, **kwargs):
        observer = probe.Observer(**kwargs)
        observer.consume(initialized(), 100)
        return observer

    def test_fragmented_and_coalesced_length_frames(self):
        decoder = probe.Decoder()
        data = probe.frame(initialized()) + probe.frame(following())
        self.assertEqual(list(decoder.feed(data[:3])), [])
        self.assertEqual(list(decoder.feed(data[3:8])), [])
        self.assertEqual([m for m, _ in decoder.feed(data[8:])], [initialized(), following()])

    def test_zero_and_oversized_frames_stop_before_payload(self):
        for size in (0, probe.MAX_FRAME + 1):
            with self.assertRaises(ValueError):
                list(probe.Decoder().feed(struct.pack("<I", size)))

    def test_passive_mode_never_requests_a_subscription(self):
        observer = self.observer()
        self.assertEqual(observer.consume(following(), 100), [])
        self.assertEqual(observer.subscribed, set())

    def test_following_notification_before_initialize_response_is_not_lost(self):
        observer = probe.Observer(follow=True)
        self.assertEqual(observer.consume(following(), 100), [])
        replies = observer.consume(initialized(), 100)
        self.assertEqual(len(replies), 1)
        self.assertEqual(replies[0]["params"]["conversationId"], THREAD)
        self.assertEqual(observer.metrics.methods["thread-stream-following-changed"], 1)

    def test_follow_accepts_only_local_selected_uuid_and_correct_target(self):
        observer = self.observer(follow=True, threads=[THREAD])
        for message in (following(host="remote-ssh-discovered:host"), following(OTHER), following("PRIVATE")):
            self.assertEqual(observer.consume(message, 100), [])
        wrong_target = following()
        wrong_target["targetClientIds"] = [OTHER]
        self.assertEqual(observer.consume(wrong_target, 100), [])
        replies = observer.consume(following(), 100)
        self.assertEqual(len(replies), 1)
        self.assertTrue(replies[0]["params"]["following"])
        self.assertEqual(observer.consume(following(), 100), [])

    def test_unknown_protocol_version_cannot_provide_stream_evidence(self):
        observer = self.observer(follow=True)
        observer.consume(following(), 100)
        observer.consume(snapshot(version=12), 100)
        self.assertEqual(observer.received_streams, set())
        self.assertEqual(observer.metrics.version_mismatches, 1)

    def test_review_source_unsubscribes_and_never_counts_as_stream(self):
        for state in ({"source": {"subAgent": "review"}}, {"threadSource": "guardian_review"},
                      {"latestModel": "codex-auto-review-v1"}):
            observer = self.observer(follow=True)
            observer.consume(following(), 100)
            replies = observer.consume(snapshot(state), 200)
            self.assertFalse(replies[0]["params"]["following"])
            self.assertEqual(observer.received_streams, set())
            self.assertEqual(observer.consume(following(), 100), [])

    def test_projection_discards_all_task_content_and_identifiers(self):
        observer = self.observer(follow=True)
        observer.consume(following(), 100)
        observer.consume(snapshot({"title": "PRIVATE TITLE", "cwd": "PRIVATE PATH",
            "latestTokenUsageInfo": {"total": {"outputTokens": 42, "inputTokens": 999}},
            "threadRuntimeStatus": {"type": "active"}, "turnHistory": {"kind": "canonical",
                "history": {"entitiesByKey": {"PRIVATE KEY": {"status": "inProgress", "items": [
                    {"type": "agentMessage", "text": "PRIVATE REPLY"},
                    {"type": "commandExecution", "command": "PRIVATE COMMAND", "aggregatedOutput": "PRIVATE OUTPUT"},
                    {"type": "automaticApprovalReview", "text": "PRIVATE REVIEW"}]}}}}}), 2000)
        report = json.dumps(observer.metrics.report())
        self.assertNotIn("PRIVATE", report)
        self.assertNotIn(THREAD, report)
        self.assertNotIn("inputTokens", report)
        self.assertNotIn("automaticApprovalReview", report)
        self.assertEqual(observer.metrics.output_counters, [42])
        self.assertEqual(observer.metrics.snapshot_item_types, {"agentMessage": 1, "commandExecution": 1})

    def test_patches_before_snapshot_and_unsubscribed_stream_are_ignored(self):
        observer = self.observer(follow=True)
        observer.consume(following(), 100)
        message = snapshot()
        message["params"]["change"] = {"type": "patches", "patches": []}
        observer.consume(message, 100)
        observer.consume(snapshot(thread=OTHER), 100)
        self.assertEqual(observer.metrics.patches, 0)
        self.assertEqual(observer.metrics.snapshots, 0)

    def test_numeric_usage_and_tool_markers_survive_patch_projection(self):
        observer = self.observer(follow=True)
        observer.consume(following(), 100)
        observer.consume(snapshot(), 100)
        message = snapshot()
        message["params"]["change"] = {"type": "patches", "patches": [
            {"path": ["latestTokenUsageInfo", "total", "outputTokens"], "value": 99},
            {"path": ["turnHistory", "history", "entitiesByKey", "PRIVATE KEY", "commandExecutionStartedAtMsById", "PRIVATE ID"], "value": 123},
            {"path": ["turns", 0, "items", 2], "value": {"type": "mcpToolCall", "arguments": "PRIVATE ARGS"}},
            {"path": ["turns", 0, "status"], "value": "completed"}],
            "acceptedTextChanges": [{"text": "PRIVATE DELTA"}]}
        observer.consume(message, 400)
        self.assertEqual(observer.metrics.output_counters, [99])
        self.assertEqual(observer.metrics.markers["command-start"], 1)
        self.assertEqual(observer.metrics.statuses["completed"], 1)
        self.assertNotIn("PRIVATE", json.dumps(observer.metrics.report()))

    def test_routed_operations_are_always_refused(self):
        observer = self.observer(follow=True)
        reply = observer.consume({"type": "client-discovery-request", "requestId": "req",
                                  "request": {"method": "thread-follower-start-turn"}}, 100)[0]
        self.assertEqual(reply["response"], {"canHandle": False})
        reply = observer.consume({"type": "request", "requestId": "req", "method": "thread-follower-interrupt-turn"}, 100)[0]
        self.assertEqual(reply["resultType"], "error")

    def test_endpoint_requires_private_owned_socket_and_directory(self):
        with tempfile.TemporaryDirectory(dir="/private/tmp") as home:
            directory = pathlib.Path(home) / "ipc"
            directory.mkdir(mode=0o700)
            with socket.socket(socket.AF_UNIX) as server:
                server.bind(str(directory / "ipc.sock"))
                os.chmod(directory / "ipc.sock", 0o600)
                self.assertEqual(probe.checked_endpoint(home), directory / "ipc.sock")
                os.chmod(directory, 0o755)
                with self.assertRaises(ValueError):
                    probe.checked_endpoint(home)

    def test_real_private_socket_receives_snapshot_and_only_sends_observer_messages(self):
        with tempfile.TemporaryDirectory(dir="/private/tmp") as home:
            directory = pathlib.Path(home) / "ipc"
            directory.mkdir(mode=0o700)
            with socket.socket(socket.AF_UNIX) as server:
                server.bind(str(directory / "ipc.sock"))
                os.chmod(directory / "ipc.sock", 0o600)
                server.listen(1)
                sent = []
                errors = []

                def worker():
                    try:
                        connection, _ = server.accept()
                        with connection:
                            connection.settimeout(2)
                            decoder = probe.Decoder()
                            while len(sent) < 2:
                                data = connection.recv(65536)
                                if not data:
                                    return
                                for message, _ in decoder.feed(data):
                                    sent.append(message)
                                    if message.get("method") == "initialize":
                                        payload = probe.frame(initialized()) + probe.frame(following())
                                        connection.sendall(payload[:2])
                                        connection.sendall(payload[2:])
                                    else:
                                        connection.sendall(probe.frame(snapshot({"title": "PRIVATE", "latestTokenUsageInfo": {"total": {"outputTokens": 7}}})))
                    except Exception as error:
                        errors.append(type(error).__name__)

                thread = threading.Thread(target=worker, daemon=True)
                thread.start()
                report = probe.run(argparse.Namespace(codex_home=home, follow_local=True, thread=[], seconds=5))
                thread.join(timeout=3)
                self.assertFalse(thread.is_alive())
                self.assertEqual(errors, [])
                self.assertTrue(report["initialized"])
                self.assertEqual(report["streamsReceived"], 1)
                self.assertEqual(report["outputCounters"], [7])
                self.assertNotIn("PRIVATE", json.dumps(report))
                self.assertEqual([m["method"] for m in sent], ["initialize", "thread-stream-following-changed"])


if __name__ == "__main__":
    unittest.main()
