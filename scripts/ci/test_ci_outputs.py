import importlib.util
import io
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import Mock, patch
from urllib.error import HTTPError

SCRIPTS = Path(__file__).resolve().parents[1]


def load(name):
    path = SCRIPTS / name
    spec = importlib.util.spec_from_file_location(path.stem, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


gate = load("ci/check-results.py")
stage = load("windows/stage-engine.py")
updates = load("windows/fetch-update-base.py")


class GateTests(unittest.TestCase):
    def test_skips_failure_cancellation_and_matrix_attempts(self):
        plan = dict(draft=False, commit="candidate", head="source", tree="tree", jobs=["windows_desktop"], shards=[{"shard": "providers"}])
        needs = {name: {"result": "success" if name in ("windows-build", "windows-tests") else "skipped"} for name in gate.JOBS}
        needs.update(changes={"result": "success"}, contract={"result": "success"})
        steps = [{"name": name, "conclusion": status} for name, status in (
            ("Functional presentation tests", "success"), ("Engine idle and shutdown protocol", "success"),
            ("Desktop integration tests", "skipped"), ("Claude runtime without user Python", "skipped"))]
        job = dict(name="Windows tests (providers)", run_attempt=2, conclusion="success", steps=steps)
        gate.check(plan, needs, [job, dict(job, conclusion="failure", run_attempt=1)])
        for key, status in (("contract", "skipped"), ("changes", "failure"), ("windows-tests", "cancelled"), ("windows-build", "skipped")):
            with self.assertRaises(ValueError):
                gate.check(plan, {**needs, key: {"result": status}}, [job])
        for actual in ([], [dict(job, steps=[])], [job, dict(job, name="Windows tests (settings)")]):
            with self.assertRaises(ValueError):
                gate.check(plan, needs, actual)
        draft = dict(plan, draft=True, jobs=[], shards=[])
        gate.check(draft, {name: {"result": "success" if name in ("changes", "contract") else "skipped"} for name in needs}, [])
        with self.assertRaises(ValueError):
            gate.check(dict(draft, tree=""), needs, [])


class ProductTests(unittest.TestCase):
    def test_only_production_inputs_change_the_key(self):
        with tempfile.TemporaryDirectory() as folder, patch.object(stage, "ROOT", Path(folder)):
            root = stage.ROOT
            for name in (*stage.BUILD_INPUTS, "Package.swift", "Package.resolved", "native/Info.plist",
                         "windows/Engine/main.swift", "windows/Tests/EngineTests/Test.swift"):
                file = root / name
                file.parent.mkdir(parents=True, exist_ok=True)
                file.write_bytes(b"one")
            key = stage.product_key("x64", "release")
            (root / "windows/Tests/EngineTests/Test.swift").write_bytes(b"two")
            self.assertEqual(stage.product_key("x64", "release"), key)
            self.assertNotEqual(stage.product_key("arm64", "release"), key)
            self.assertNotEqual(stage.product_key("x64", "debug"), key)
            for name in ("windows/toolchain-lock.json", "Package.resolved", "windows/Engine/main.swift"):
                file = root / name
                file.write_bytes(b"different")
                self.assertNotEqual(stage.product_key("x64", "release"), key, name)
                file.write_bytes(b"one")
            (root / "windows/Engine/main.swift").rename(root / "windows/Engine/renamed.swift")
            self.assertNotEqual(stage.product_key("x64", "release"), key)

    def test_cache_rejects_corrupt_missing_and_stale_products(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            cache, binary = root / "cache", root / "binary"
            binary.mkdir()
            for name in stage.BINARIES:
                (binary / name).write_bytes(b"compiled")
            for name in stage.BUNDLES:
                (binary / name).mkdir()
                (binary / name / "resource").write_bytes(b"resource")
            self.assertIsNone(stage.cached_products(cache, "key"))
            stage.save_products(cache, binary, "key")
            directory = stage.cached_products(cache, "key")
            self.assertIsNotNone(directory)
            self.assertIsNone(stage.cached_products(cache, "another key"))
            (directory / stage.BINARIES[0]).write_bytes(b"broken")
            self.assertIsNone(stage.cached_products(cache, "key"))
            stage.save_products(cache, binary, "key")
            (stage.cached_products(cache, "key") / stage.BUNDLES[0] / "resource").unlink()
            self.assertIsNone(stage.cached_products(cache, "key"))


class ReleaseDownloadTests(unittest.TestCase):
    @staticmethod
    def error(code, headers=None):
        return HTTPError("https://example.invalid/release", code, "fixture", headers or {}, io.BytesIO())

    def test_transient_get_restarts_and_terminal_errors_do_not_retry(self):
        payload = io.BytesIO(b"healthy")
        payload.headers = {"Content-Length": "7"}
        sleep = Mock()
        get = Mock(side_effect=[self.error(504), self.error(429, {"Retry-After": "3"}), payload])
        self.assertEqual(updates.download("url", open_url=get, sleep=sleep), b"healthy")
        self.assertEqual([value.args for value in sleep.call_args_list], [(1,), (3,)])
        for error, attempts in ((self.error(503), 3), (TimeoutError(), 3), (self.error(403), 1),
                                (self.error(404), 1), (self.error(429, {"Retry-After": "300"}), 1)):
            get = Mock(side_effect=error)
            with self.assertRaises(RuntimeError):
                updates.download("url", open_url=get, sleep=Mock())
            self.assertEqual(get.call_count, attempts)
        self.assertIsNone(updates.download("url", optional=True, open_url=Mock(side_effect=self.error(404))))

    def test_only_publish_a_verified_base(self):
        spark = updates.SPARKLE[1:-1]
        pacer = updates.PACER[1:-1]
        def feed(digest):
            return (f'signature\n<rss xmlns:s="{spark}" xmlns:p="{pacer}"><channel><item>'
                    f'<enclosure s:os="windows-x64" {digest}/><s:shortVersionString>1.2.3</s:shortVersionString>'
                    '<s:version>1.2.3.12</s:version></item></channel></rss>').encode()
        with tempfile.TemporaryDirectory() as folder:
            output = Path(folder) / "base.json"
            for architecture, build, expected in (("x64", 12, True), ("arm64", 12, False), ("x64", 11, False)):
                data = json.dumps(dict(architecture=architecture, version="1.2.3", build=build)).encode()
                fetch = Mock(side_effect=[feed('p:manifestSHA256="' + updates.sha256(data).hexdigest() + '"'), data])
                if expected:
                    self.assertEqual(updates.fetch(output, "x64", "1.2.4.13", fetch), str(output.resolve()))
                    self.assertEqual(output.read_bytes(), data)
                    output.unlink()
                else:
                    with self.assertRaisesRegex(ValueError, "another architecture or build"):
                        updates.fetch(output, "x64", "1.2.4.13", fetch)
                    self.assertFalse(output.exists())
            with self.assertRaisesRegex(ValueError, "differs"):
                updates.fetch(output, "x64", "1.2.4.13", Mock(side_effect=[feed('p:manifestSHA256="' + '0'*64 + '"'), b"invalid"]))
            self.assertIn("No patch base", updates.fetch(output, "x64", "1.2.4.13", Mock(return_value=feed(""))))
            self.assertIn("No patch base", updates.fetch(output, "arm64", "1.2.4.13", Mock(return_value=feed(""))))
            self.assertFalse(output.exists())
