import importlib.util
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

spec = importlib.util.spec_from_file_location("changed_platforms", Path(__file__).with_name("changed-platforms.py"))
platforms = importlib.util.module_from_spec(spec)
spec.loader.exec_module(platforms)


class ChangedPlatformsTests(unittest.TestCase):
    def test_documentation_selects_no_platform_jobs(self):
        self.assertEqual(platforms.classify(["docs/guide.md", "README.zh-CN.md", "CHANGELOG.md", "LICENSE",
            "docs/images/windows-composition/cpu.json", ".github/ISSUE_TEMPLATE/bug_report.yml",
            "native/Sources/CGzip/README.md"]), set())

    def test_each_platform_runs_only_for_its_own_files(self):
        self.assertEqual(platforms.classify(["native/Sources/PacerIsland/PanelController.swift",
            "native/Tests/PacerMacSupportTests/TestWait.swift", "native/Tests/PacerTestSupport/TestDefaults.swift",
            "scripts/native/ci-test.py", "Makefile"]), {"mac", "mac_bundle"})
        self.assertEqual(platforms.classify(["windows/Desktop/MainWindow.xaml.cs", "scripts/windows/test-engine.ps1"]),
            {"windows_desktop", "windows_engine", "windows_integration", "windows_arm64"})

    def test_installer_checks_run_only_for_what_the_installers_are_built_from(self):
        for path in ("windows/Installer/CodexPacer.iss", "windows/Maintenance/Program.cs", "windows/UpdateSupport/Patch.cs",
                     "scripts/windows/package-installer.ps1", "scripts/windows/test-patch.ps1", "windows/toolchain-lock.json",
                     "global.json", "windows/Desktop/App.xaml.cs", "windows/Desktop/WindowsSystemNotifications.cs",
                     "scripts/windows/build-desktop.ps1"):
            self.assertEqual(platforms.classify([path]), platforms.WINDOWS_JOBS | {"installer"}, path)

    def test_shared_core_runs_both_platforms_without_the_installers(self):
        for path in ("native/Sources/PacerCore/IslandGeometry.swift", "native/Tests/PresentationTables/compact.json",
                     "native/Sources/PacerCore/Resources/en.lproj/Localizable.strings", "native/Info.plist", "Package.swift"):
            self.assertEqual(platforms.classify([path]), platforms.PRODUCT_JOBS, path)

    def test_test_only_changes_run_their_targets_and_combine_with_product_changes(self):
        cases = {
            "native/Tests/PacerMacSupportTests/TestWait.swift": {"mac"},
            "native/Tests/PacerIslandTests/UpdateFlowTests.swift": {"mac"},
            "native/Tests/PacerTestSupport/TestDefaults.swift": {"mac"},
            "native/Tests/PacerCoreTests/IslandPlacementTests.swift": {"mac", "windows_engine"},
            "windows/Tests/EngineTests/CodexDesktopMonitorTests.swift": {"windows_engine"},
            "windows/Tests/PresentationTests/Program.cs": {"windows_desktop"},
        }
        for path, jobs in cases.items():
            self.assertEqual(platforms.classify([path]), jobs, path)
        self.assertEqual(platforms.classify(cases), {"mac", "windows_engine", "windows_desktop"})
        self.assertEqual(platforms.classify([*cases, "native/Info.plist"]), platforms.PRODUCT_JOBS)

    def test_moving_a_windows_test_into_docs_keeps_its_old_target(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            def git(*args):
                subprocess.run(["git", "-c", "user.name=CI", "-c", "user.email=ci@example.invalid",
                                "-c", "commit.gpgsign=false", *args], cwd=root, check=True, capture_output=True)
            git("init", "-q")
            source = Path("windows/Tests/EngineTests/示例 case.swift")
            (root / source.parent).mkdir(parents=True)
            (root / source).write_text("// fixture\n", encoding="utf-8")
            git("add", ".")
            git("commit", "-qm", "base")
            (root / "docs").mkdir()
            git("mv", str(source), "docs/moved case.md")
            git("commit", "-qm", "move")
            output = root / "job-output"
            env = dict(os.environ, GITHUB_EVENT_NAME="pull_request", GITHUB_OUTPUT=str(output))
            subprocess.run([sys.executable, platforms.__file__], cwd=root, env=env, check=True, capture_output=True)
            self.assertEqual(dict(line.split("=") for line in output.read_text().splitlines()),
                             {job: str(job == "windows_engine").lower() for job in platforms.ALL_JOBS})

    def test_the_workflow_ci_scripts_and_unknown_files_run_everything(self):
        for path in (".github/workflows/platforms.yml", "scripts/ci/changed-platforms.py", "scripts/performance/benchmark-events.py"):
            self.assertEqual(platforms.classify([path]), platforms.ALL_JOBS, path)


if __name__ == "__main__":
    unittest.main()
