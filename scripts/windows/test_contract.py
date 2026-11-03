import importlib.util
import json
from pathlib import Path
import re
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

    def test_shared_test_functions_cannot_hide_in_platform_conditionals(self):
        for text in (
            '#if canImport(PacerMacSupport)\nfunc testMacOnly() {}\n#endif',
            '#if os(macOS)\nfinal class Cases {\n@MainActor func testHost() {}\n}\n#endif',
            '#if !os(Windows)\nfunc testMissingOnWindows() {}\n#endif',
            '#if DEBUG\n#if canImport(AppKit)\nfunc testNested() {}\n#endif\n#endif',
            '#if DEBUG\n#elseif canImport(PacerMacSupport)\nfunc testElseIf() {}\n#endif',
            '#if !canImport(PacerMacSupport)\n#else\nfunc testMacElse() {}\n#endif',
        ):
            with self.subTest(text=text), self.assertRaises(ValueError):
                contract.shared_test_contract('Fixture.swift', text)

    def test_shared_test_imports_and_fixture_selection_remain_allowed(self):
        text = ('#if canImport(PacerMacSupport)\nimport PacerMacSupport\n#else\nimport PacerEngineSupport\n#endif\n'
                'func fixture() {\n#if canImport(PacerMacSupport)\nlet path = 1\n#else\nlet path = 2\n#endif\n}\n'
                'func testShared() {}\n#if DEBUG\nfunc testDebug() {}\n#endif\n'
                'let script = #"""\n#if os(macOS)\nfunc testNotSwift() {}\n#endif\n"""#\n')
        contract.shared_test_contract('Fixture.swift', text)

    def test_shared_test_scan_is_recursive(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / 'Nested').mkdir()
            (root / 'Shared.swift').write_text('func testShared() {}', encoding='utf-8')
            nested = root / 'Nested/NewTests.swift'
            nested.write_text('#if canImport(PacerMacSupport)\nfunc testHidden() {}\n#endif', encoding='utf-8')
            with self.assertRaisesRegex(ValueError, r'Nested/NewTests.swift:2'):
                contract.shared_tests_contract(root)
            nested.write_text('func testNowShared() {}', encoding='utf-8')
            contract.shared_tests_contract(root)

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


class WindowsLocalizationTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        source = importlib.util.spec_from_file_location("localization", Path(__file__).with_name("build-localization.py"))
        cls.localization = importlib.util.module_from_spec(source)
        source.loader.exec_module(cls.localization)
        cls.catalogs = cls.localization.catalogs()

    def test_both_generated_catalogs_match_the_authoritative_sources(self):
        for language, catalog in self.catalogs.items():
            path = contract.ROOT / f"windows/EngineSupport/Resources/Localization/Catalogs/{language}.json"
            self.assertEqual(json.loads(path.read_text(encoding="utf-8")), catalog)
            self.assertTrue(catalog["strings"])
        self.assertEqual(set(self.catalogs["en"]["strings"]), set(self.catalogs["zh-Hans"]["strings"]))

    def test_literal_ui_keys_exist_in_both_languages(self):
        references = set()
        for path in (contract.ROOT / "windows/Desktop").glob("*.cs"):
            references.update(re.findall(r'\bui\.Text\("([^"\n]+)"\)', path.read_text(encoding="utf-8")))
        self.assertGreater(len(references), 100)
        for language, catalog in self.catalogs.items():
            for key in references:
                with self.subTest(language=language, key=key):
                    self.assertIn(key, catalog["strings"])
                    self.assertTrue(catalog["strings"][key].strip())

    def test_settings_and_guide_literals_do_not_use_mac_only_instructions(self):
        for path in (contract.ROOT / "windows/Desktop").glob("*.cs"):
            if not path.name.startswith(("Settings", "Guide")):
                continue
            for key in re.findall(r'\bui\.Text\("([^"\n]+)"\)', path.read_text(encoding="utf-8")):
                for language, catalog in self.catalogs.items():
                    with self.subTest(file=path.name, language=language, key=key):
                        self.assertNotRegex(catalog["strings"][key], r"\bMac\b|macOS|Finder|⌘")

    def test_windows_text_does_not_override_the_mac_catalog(self):
        for language, catalog in self.catalogs.items():
            windows = json.loads((contract.ROOT / f"windows/EngineSupport/Resources/Localization/{language}.json").read_text(encoding="utf-8"))
            shared = self.localization.shared_strings((contract.ROOT / f"native/Sources/PacerCore/Resources/{language}.lproj/Localizable.strings").read_text(encoding="utf-8"))
            self.assertFalse(set(windows) & set(shared))
            self.assertTrue(all(key.startswith("windows.") and value.strip() for key, value in windows.items()))
            self.assertEqual({key: catalog["strings"][key] for key in windows}, windows)
            if language == "en":
                self.assertTrue(all(not re.search(r"[\u3400-\u9fff]", value) for value in windows.values()))

    def test_format_arguments_allow_translation_order_and_literal_percent(self):
        self.localization.validate_formats({"value": "%1$@ / %2$ld, {0}, 15%"}, {"value": "{0}，%2$ld / %1$@，15%"})
        self.assertEqual(self.localization.format_signature("100%%"), ([], []))
        self.assertEqual(self.localization.format_signature("{{0}}"), ([], []))

    def test_printf_type_index_and_duplicate_argument_changes_are_rejected(self):
        for text in ("%1$ld / %2$@", "%1$@ / %3$ld", "%1$@ / %2$ld / %2$ld"):
            with self.subTest(text=text), self.assertRaises(ValueError):
                self.localization.validate_formats({"value": "%1$@ / %2$ld"}, {"value": text})

    def test_composite_argument_removal_and_renumbering_are_rejected(self):
        for text in ("Restored", "Backup: {1}", "Backup: {0} {0}"):
            with self.subTest(text=text), self.assertRaises(ValueError):
                self.localization.validate_formats({"value": "Backup: {0}"}, {"value": text})


if __name__ == "__main__":
    unittest.main()
