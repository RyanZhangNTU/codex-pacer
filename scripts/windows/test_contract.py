import importlib.util
from pathlib import Path
import unittest

spec = importlib.util.spec_from_file_location("contract", Path(__file__).with_name("check-contract.py"))
contract = importlib.util.module_from_spec(spec)
spec.loader.exec_module(contract)


class CoreBoundaryTests(unittest.TestCase):
    def check(self, text, transition=None):
        return contract.source_contract("Fixture.swift", text, transition or {})

    def test_new_system_imports_are_rejected_with_attributes_or_declaration_imports(self):
        for text in ("import Darwin", "@_implementationOnly import WinSDK", "import struct Darwin.stat", "import CoreFoundation"):
            with self.subTest(text=text), self.assertRaises(ValueError):
                self.check(text)

    def test_existing_import_requires_its_exact_inventory_and_cleanup_owner(self):
        transition = {"systemImports": {"Darwin": 1}, "owner": "B4", "reason": "Move collector IO."}
        self.assertEqual(self.check("import Darwin", transition), (True, 0, 0))
        for text in ("import Darwin\nimport WinSDK", "import Darwin\nimport Darwin"):
            with self.assertRaises(ValueError):
                self.check(text, transition)
        with self.assertRaises(ValueError):
            self.check("import Darwin", {"systemImports": {"Darwin": 1}})

    def test_availability_whitelist_allows_only_the_guarded_import(self):
        self.assertEqual(self.check("#if canImport(FoundationNetworking)\nimport FoundationNetworking\n#endif"), (False, 1, 0))
        for text in ("import FoundationNetworking", "#if os(Windows)\nlet value = 1\n#endif",
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


if __name__ == "__main__":
    unittest.main()
