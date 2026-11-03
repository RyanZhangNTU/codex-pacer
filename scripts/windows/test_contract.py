import importlib.util
from pathlib import Path
import unittest
import tempfile

spec = importlib.util.spec_from_file_location("contract", Path(__file__).with_name("check-contract.py"))
contract = importlib.util.module_from_spec(spec)
spec.loader.exec_module(contract)


class CoreBoundaryTests(unittest.TestCase):
    def check(self, text):
        return contract.source_contract("Fixture.swift", text)

    def test_new_system_imports_are_rejected_with_attributes_or_declaration_imports(self):
        for text in ("import Darwin", "@_implementationOnly import WinSDK", "import struct Darwin.stat", "import CoreFoundation", "import Glibc", "import PacerEngineSupport", "import PacerMacSupport"):
            with self.subTest(text=text), self.assertRaises(ValueError):
                self.check(text)

    def test_core_scan_includes_nested_sources_and_has_no_import_exceptions(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "Nested").mkdir()
            (root / "Shared.swift").write_text("import Foundation", encoding="utf-8")
            nested = root / "Nested/New.swift"
            nested.write_text("import Darwin", encoding="utf-8")
            with self.assertRaises(ValueError):
                contract.core_contract(root)
            nested.write_text("import Foundation", encoding="utf-8")
            sources, counts = contract.core_contract(root)
            self.assertEqual(len(sources), 2)
            self.assertEqual(counts, [0, 0, 0])

    def test_availability_whitelist_allows_only_the_guarded_import(self):
        self.assertEqual(self.check("#if canImport(FoundationNetworking)\nimport FoundationNetworking\n#endif"), (False, 1, 0))
        self.assertEqual(self.check("#if canImport(CoreGraphics)\nimport CoreGraphics\n#endif"), (False, 1, 0))
        for text in ("import FoundationNetworking", "import CoreGraphics", "#if os(Windows)\nlet value = 1\n#endif",
                     "#if canImport(FoundationNetworking)\nimport FoundationNetworking\nlet value = 1\n#endif",
                     "#if canImport(FoundationNetworking)\nimport FoundationNetworking\n#else\nlet value = 1\n#endif"):
            with self.assertRaises(ValueError):
                self.check(text)

    def test_embedded_helpers_comments_and_string_contents_are_not_swift_imports(self):
        text = 'import Foundation\nlet script = #"""\nimport os\nimport Darwin\n#if os(Windows)\n"""#\n/* import WinSDK */\n'
        self.assertEqual(self.check(text), (False, 0, 0))

    def test_package_wiring_describes_targets_and_dependencies_without_hashing_the_file(self):
        text = '.target(name: "PacerMacSupport", dependencies: ["PacerCore"]),\n' \
               '.executableTarget(name: "PacerIsland", dependencies: ["PacerCore", .product(name: "Sparkle", package: "Sparkle")])'
        expected = {"PacerMacSupport": {"kind": "target", "dependencies": ["PacerCore"]},
                    "PacerIsland": {"kind": "executableTarget", "dependencies": ["PacerCore", "Sparkle"]}}
        self.assertEqual(contract.native_package_wiring(text), expected)
        self.assertEqual(contract.native_package_wiring("// Comment only\n" + text), expected)
        self.assertNotEqual(contract.native_package_wiring(text.replace('"PacerCore"', '"WindowsHost"')), expected)

    def test_closed_c_phase_rejects_every_legacy_exception_inventory(self):
        contract.no_transition_inventories({}, {})
        for key in ("coreTransitions", "engineTransitions", "sourceSelectionRemoval", "macosJobSHA256"):
            with self.subTest(key=key), self.assertRaises(ValueError):
                contract.no_transition_inventories({key: {}}, {})
        for key in ("remainingCoreSources", "remainingCoreTests"):
            with self.subTest(key=key), self.assertRaises(ValueError):
                contract.no_transition_inventories({}, {key: {}})

    def test_core_and_host_target_boundary_is_checked_in_both_platform_branches(self):
        text = (contract.ROOT / "Package.swift").read_text(encoding="utf-8")
        contract.package_boundary(text)
        contract.package_boundary((contract.ROOT / "native/Package.swift").read_text(encoding="utf-8"), native=True)
        # Mutate each Core declaration independently; inspecting a dictionary
        # keyed by target name would silently miss the Windows declaration.
        occurrences = [body for name, body in contract.target_fragments(text) if name == "PacerCore"]
        self.assertEqual(len(occurrences), 2)
        for body in occurrences:
            with self.assertRaises(ValueError):
                contract.package_boundary(text.replace(body, body.replace('"CZstd"', '"PacerEngineSupport"'), 1))
            with self.assertRaises(ValueError):
                contract.package_boundary(text.replace(body, body.replace('dependencies: [', 'dependencies: hiddenHostDependencies + [', 1), 1))
            with self.assertRaises(ValueError):
                contract.package_boundary(text.replace(body, body + ', sources: ["One.swift"]', 1))
            with self.assertRaises(ValueError):
                contract.package_boundary(text.replace(body, body + ', exclude: ["One.swift"]', 1))
        for body in [body for name, body in contract.target_fragments(text) if name == "PacerCoreTests"]:
            with self.assertRaises(ValueError):
                contract.package_boundary(text.replace(body, body + ', sources: ["OneTests.swift"]', 1))
        with self.assertRaises(ValueError):
            contract.package_boundary(text.replace('name: "PacerEngineSupport"', 'name: "CombinedCore"'))

    def test_ci_checks_the_contract_on_mac_and_windows(self):
        workflow = (contract.ROOT / ".github/workflows/platforms.yml").read_text(encoding="utf-8")
        contract.workflow_boundary(workflow)
        with self.assertRaises(ValueError):
            contract.workflow_boundary(workflow.replace("python3 scripts/windows/check-contract.py", "true", 1))
        with self.assertRaises(ValueError):
            contract.workflow_boundary(workflow.replace("python scripts/windows/check-contract.py", "Write-Output skipped", 1))


if __name__ == "__main__":
    unittest.main()
