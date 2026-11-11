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
    def test_documentation_runs_nothing(self):
        self.assertEqual(platforms.classify(["docs/guide.md", "README.zh-CN.md", "CHANGELOG.md", "LICENSE",
            "docs/images/windows-composition/cpu.json", ".github/ISSUE_TEMPLATE/bug_report.yml",
            "native/Sources/CGzip/README.md"]), (False, False, False))

    def test_each_platform_runs_only_for_its_own_files(self):
        self.assertEqual(platforms.classify(["native/Sources/PacerIsland/PanelController.swift",
            "native/Tests/PacerMacSupportTests/TestWait.swift", "native/Tests/PacerTestSupport/TestDefaults.swift",
            "scripts/native/ci-test.py", "Makefile"]), (True, False, False))
        self.assertEqual(platforms.classify(["windows/Desktop/MainWindow.xaml.cs", "scripts/windows/test-engine.ps1"]),
            (False, True, False))

    def test_installer_checks_run_only_for_what_the_installers_are_built_from(self):
        for path in ("windows/Installer/CodexPacer.iss", "windows/Maintenance/Program.cs", "windows/UpdateSupport/Patch.cs",
                     "scripts/windows/package-installer.ps1", "scripts/windows/test-patch.ps1", "windows/toolchain-lock.json",
                     "global.json", "windows/Desktop/App.xaml.cs", "windows/Desktop/WindowsSystemNotifications.cs",
                     "scripts/windows/build-desktop.ps1", "scripts/windows/environment.ps1", "scripts/windows/architecture.ps1",
                     "scripts/windows/version.ps1", "scripts/windows/fetch-update-base.ps1", "scripts/windows/test-update-base.ps1"):
            self.assertEqual(platforms.classify([path]), (False, True, True), path)

    def test_shared_core_runs_both_platforms_without_the_installers(self):
        for path in ("native/Sources/PacerCore/IslandGeometry.swift", "native/Tests/PacerCoreTests/IslandPlacementTests.swift",
                     "native/Sources/PacerCore/Resources/en.lproj/Localizable.strings", "Package.swift"):
            self.assertEqual(platforms.classify([path]), (True, True, False), path)
        self.assertEqual(platforms.classify(["native/Info.plist"]), (True, True, True))

    def test_the_workflow_ci_scripts_and_unknown_files_run_everything(self):
        for path in (".github/workflows/platforms.yml", "scripts/ci/changed-platforms.py", "scripts/performance/benchmark-events.py"):
            self.assertEqual(platforms.classify([path]), (True, True, True), path)

    def test_ci_keeps_the_removed_side_of_a_rename_and_preserves_spaces(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)

            def git(*args):
                subprocess.run(["git", *args], cwd=root, check=True, capture_output=True)

            git("init", "-q")
            git("config", "user.name", "Pacer CI fixture")
            git("config", "user.email", "pacer-ci@example.invalid")
            before = root / "windows/Desktop/Panel view.xaml"
            before.parent.mkdir(parents=True)
            before.write_text("synthetic XAML\n", encoding="utf-8")
            git("add", ".")
            git("commit", "-qm", "Add view")
            after = root / "docs/Panel view.md"
            after.parent.mkdir()
            before.rename(after)
            git("add", "-A")
            git("commit", "-qm", "Move view")
            env = dict(os.environ, GITHUB_EVENT_NAME="pull_request", GITHUB_OUTPUT=str(root / "result"))
            subprocess.run([sys.executable, platforms.__file__], cwd=root, env=env, check=True, capture_output=True)
            self.assertEqual((root / "result").read_text(encoding="utf-8"), "mac=false\nwindows=true\ninstaller=false\n")


if __name__ == "__main__":
    unittest.main()
