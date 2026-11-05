import importlib.util
import unittest
from pathlib import Path

spec = importlib.util.spec_from_file_location("changed_platforms", Path(__file__).with_name("changed-platforms.py"))
platforms = importlib.util.module_from_spec(spec)
spec.loader.exec_module(platforms)


class ChangedPlatformsTests(unittest.TestCase):
    def test_documentation_runs_nothing(self):
        self.assertEqual(platforms.classify(["docs/guide.md", "README.zh-CN.md", "CHANGELOG.md", "LICENSE",
            "docs/images/windows-composition/cpu.json", ".github/ISSUE_TEMPLATE/bug_report.yml",
            "native/Sources/CGzip/README.md"]), (False, False))

    def test_each_platform_runs_only_for_its_own_files(self):
        self.assertEqual(platforms.classify(["native/Sources/PacerIsland/PanelController.swift",
            "native/Tests/PacerMacSupportTests/TestWait.swift", "scripts/native/ci-test.py", "Makefile"]), (True, False))
        self.assertEqual(platforms.classify(["windows/Desktop/MainWindow.xaml.cs", "scripts/windows/test-engine.ps1",
            "global.json"]), (False, True))

    def test_shared_core_workflow_and_unknown_files_run_both(self):
        for path in ("native/Sources/PacerCore/IslandGeometry.swift", "native/Tests/PacerCoreTests/IslandPlacementTests.swift",
                     "native/Sources/PacerCore/Resources/en.lproj/Localizable.strings", "native/Info.plist", "Package.swift",
                     ".github/workflows/platforms.yml", "scripts/ci/changed-platforms.py", "scripts/performance/benchmark-events.py"):
            self.assertEqual(platforms.classify([path]), (True, True), path)


if __name__ == "__main__":
    unittest.main()
