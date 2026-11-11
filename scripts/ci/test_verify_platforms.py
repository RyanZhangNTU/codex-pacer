import importlib.util
import io
import json
from pathlib import Path
import unittest
import zipfile


spec = importlib.util.spec_from_file_location("verify_platforms", Path(__file__).with_name("verify-platforms.py"))
platforms = importlib.util.module_from_spec(spec)
spec.loader.exec_module(platforms)


class PlatformsReceiptTests(unittest.TestCase):
    def test_documentation_skips_only_platform_jobs(self):
        needs = {job: {"result": "skipped"} for job in
                 ("macos", "windows-engine", "windows-build", "windows-tests", "windows-installer", "windows-arm64")}
        needs["changes"] = {"result": "success", "outputs": {"mac": "false", "windows": "false", "installer": "false"}}
        needs["contract"] = {"result": "success"}
        platforms.require_jobs(needs)
        needs["changes"]["outputs"]["windows"] = "true"
        with self.assertRaisesRegex(ValueError, "windows-engine must be success"):
            platforms.require_jobs(needs)
        del needs["changes"]["outputs"]["windows"]
        with self.assertRaisesRegex(ValueError, "did not report all platform flags"):
            platforms.require_jobs(needs)

    def setUp(self):
        self.tree, self.head, self.merge = ("a" * 40, "b" * 40, "c" * 40)
        self.repo = "repos/example/pacer"
        self.receipt = {"run": 123, "attempt": 2, "event": "pull_request", "base": "develop",
                        "ref": "refs/pull/12/merge", "commit": self.merge, "tree": self.tree}
        self.run = {"repository": {"id": 7}, "path": platforms.WORKFLOW, "event": "pull_request", "head_branch": "feature",
                    "status": "completed", "conclusion": "success", "run_attempt": 2, "head_sha": self.head}
        self.artifact = {"expired": False, "id": 1, "size_in_bytes": 240,
                         "workflow_run": {"id": 123, "repository_id": 7, "head_sha": self.head}}
        self.job = {"name": platforms.CHECK, "status": "completed", "conclusion": "success"}
        self.head_tree = self.merge_tree = self.tree

    def api(self, endpoint, *flags):
        path = endpoint.removeprefix(self.repo)
        if path == f"/actions/artifacts?name=platforms-tree-{self.tree}&per_page=100":
            assert flags == ("--paginate", "--slurp")
            value = [{"artifacts": [dict(self.artifact, expired=True)]}, {"artifacts": [self.artifact]}]
        elif path == "/actions/runs/123":
            value = self.run
        elif path == f"/git/commits/{self.head}":
            value = {"tree": {"sha": self.head_tree}}
        elif path == f"/git/commits/{self.merge}":
            value = {"tree": {"sha": self.merge_tree}}
        elif path == "/actions/runs/123/attempts/2/jobs?per_page=100":
            assert flags == ("--paginate", "--slurp")
            value = [{"jobs": []}, {"jobs": [self.job]}]
        elif path == "/actions/artifacts/1/zip":
            data = io.BytesIO()
            with zipfile.ZipFile(data, "w") as archive:
                archive.writestr(platforms.RECEIPT, json.dumps(self.receipt))
            return data.getvalue()
        else:
            raise AssertionError(endpoint)
        return json.dumps(value).encode()

    def require(self):
        return platforms.require_tree(self.api, self.repo, 7, self.tree)

    def test_same_tree_promoted_through_a_different_commit_passes(self):
        self.assertEqual(self.require(), 123)

    def test_manual_run_must_be_on_develop(self):
        self.run.update(event="workflow_dispatch", head_branch="other")
        self.receipt.update(event="workflow_dispatch", commit=self.head, ref="refs/heads/develop")
        with self.assertRaisesRegex(ValueError, "No successful Platforms"):
            self.require()
        self.run["head_branch"] = "develop"
        self.assertEqual(self.require(), 123)

    def test_wrong_head_or_merge_tree_fails(self):
        self.head_tree = "d" * 40
        with self.assertRaisesRegex(ValueError, "No successful Platforms"):
            self.require()
        self.head_tree, self.merge_tree = self.tree, "e" * 40
        with self.assertRaisesRegex(ValueError, "No successful Platforms"):
            self.require()

    def test_wrong_workflow_fails(self):
        self.run["path"] = ".github/workflows/anything.yml"
        with self.assertRaisesRegex(ValueError, "No successful Platforms"):
            self.require()

    def test_receipt_from_old_attempt_fails(self):
        self.receipt["attempt"] = 1
        with self.assertRaisesRegex(ValueError, "No successful Platforms"):
            self.require()

    def test_successful_run_without_a_successful_aggregate_fails(self):
        self.job["conclusion"] = "skipped"
        with self.assertRaisesRegex(ValueError, "No successful Platforms"):
            self.require()

    def test_stale_candidates_do_not_hide_a_valid_receipt(self):
        original = self.api
        stale = dict(self.artifact, id=2)
        malformed = dict(self.artifact, id=3)
        listing = f"{self.repo}/actions/artifacts?name=platforms-tree-{self.tree}&per_page=100"

        def api(endpoint, *flags):
            if endpoint == listing:
                return json.dumps([{"artifacts": [stale, malformed, self.artifact]}]).encode()
            if endpoint.endswith("/actions/artifacts/2/zip"):
                raise platforms.GitHubError(endpoint, 404)
            if endpoint.endswith("/actions/artifacts/3/zip"):
                return b"invalid archive"
            return original(endpoint, *flags)

        self.api = api
        self.assertEqual(self.require(), 123)

    def test_authentication_error_is_not_treated_as_an_expired_artifact(self):
        original = self.api

        def api(endpoint, *flags):
            if endpoint.endswith("/git/commits/" + self.merge):
                raise platforms.GitHubError(endpoint, 403)
            return original(endpoint, *flags)

        self.api = api
        with self.assertRaisesRegex(platforms.GitHubError, "HTTP 403"):
            self.require()


if __name__ == "__main__":
    unittest.main()
