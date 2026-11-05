import base64
import importlib.util
import json
from pathlib import Path
import plistlib
import re
import struct
import unittest
import tempfile
import xml.etree.ElementTree as ET

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
            sources, availability = contract.core_contract(root)
            self.assertEqual(len(sources), 2)
            self.assertEqual(availability, 0)

    def test_availability_whitelist_allows_only_the_guarded_import(self):
        self.assertEqual(self.check("#if canImport(FoundationNetworking)\nimport FoundationNetworking\n#endif"), 1)
        self.assertEqual(self.check("#if canImport(CoreGraphics)\nimport CoreGraphics\n#endif"), 1)
        for text in ("import FoundationNetworking", "import CoreGraphics", "#if os(Windows)\nlet value = 1\n#endif",
                     "#if canImport(FoundationNetworking)\nimport FoundationNetworking\nlet value = 1\n#endif",
                     "#if canImport(FoundationNetworking)\nimport FoundationNetworking\n#else\nlet value = 1\n#endif"):
            with self.assertRaises(ValueError):
                self.check(text)

    def test_embedded_helpers_comments_and_string_contents_are_not_swift_imports(self):
        text = 'import Foundation\nlet script = #"""\nimport os\nimport Darwin\n#if os(Windows)\n"""#\n/* import WinSDK */\n'
        self.assertEqual(self.check(text), 0)

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

    def test_toolchain_lock_names_the_pinned_sdk_and_packages(self):
        workflows = contract.ROOT / ".github/workflows"
        platforms, release = ((workflows / name).read_text(encoding="utf-8") for name in ("platforms.yml", "release.yml"))
        workflow = platforms + release
        contract.toolchain_pins(contract.ROOT, workflow)
        drift = lambda text: re.sub(r"(dotnet-version:\s*)\S+", r"\g<1>0.0.1", text, count=1)
        for drifted in (drift(platforms) + release, platforms + drift(release)):
            with self.assertRaises(ValueError):
                contract.toolchain_pins(contract.ROOT, drifted)
        lock = json.loads((contract.ROOT / "windows/toolchain-lock.json").read_text(encoding="utf-8"))
        project = (contract.ROOT / "windows/Desktop/Pacer.Windows.csproj").read_text(encoding="utf-8")
        exact = '"[' + lock["webView2"] + ']"'
        self.assertIn(exact, project)
        for loose in ('"' + lock["webView2"] + '"', '"[' + lock["webView2"] + ',)"', '"0.0.1"'):
            with self.subTest(version=loose), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                (root / "windows/Desktop").mkdir(parents=True)
                for name in ("global.json", "windows/toolchain-lock.json"):
                    (root / name).write_bytes((contract.ROOT / name).read_bytes())
                (root / "windows/Desktop/Pacer.Windows.csproj").write_text(project.replace(exact, loose), encoding="utf-8")
                with self.assertRaises(ValueError):
                    contract.toolchain_pins(root, workflow)

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

    def test_ci_checks_the_contract_on_every_run(self):
        workflow = (contract.ROOT / ".github/workflows/platforms.yml").read_text(encoding="utf-8")
        contract.workflow_boundary(workflow)
        for script in ("check-contract.py", "test_contract.py"):
            with self.assertRaises(ValueError):
                contract.workflow_boundary(workflow.replace("python3 scripts/windows/" + script, "true", 1))
        with self.assertRaises(ValueError):
            contract.workflow_boundary(workflow.replace("\n  contract:\n", "\n  checks:\n", 1))
        name = "    name: Platform contract\n"
        self.assertIn(name, workflow)
        for gate in ("    needs: changes\n    if: needs.changes.outputs.windows == 'true'\n",
                     "    if: github.event_name == 'pull_request'\n"):
            with self.subTest(gate=gate), self.assertRaises(ValueError):
                contract.workflow_boundary(workflow.replace(name, name + gate, 1))

    def test_release_windows_jobs_build_the_installers_without_secrets(self):
        release = (contract.ROOT / ".github/workflows/release.yml").read_text(encoding="utf-8")
        contract.release_boundary(release)
        x64 = "  windows-x64:\n    name: Windows installer (x64)\n"
        for broken in (release.replace("name: windows-installer-arm64-unsigned", "name: windows-installer-arm64", 1),
                       release.replace("\n  windows-x64:\n", "\n  windows-amd64:\n", 1),
                       release.replace(x64, x64 + "    environment: release\n", 1),
                       release.replace("      PACER_ARCHITECTURE: arm64\n",
                                       "      PACER_ARCHITECTURE: arm64\n      TOKEN: ${{ secrets.SPARKLE_PRIVATE_KEY }}\n", 1),
                       release.replace("cancel-in-progress: false", "cancel-in-progress: true", 1)):
            self.assertNotEqual(broken, release)
            with self.assertRaises(ValueError):
                contract.release_boundary(broken)


class WindowsArchitectureTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        source = importlib.util.spec_from_file_location("architecture", Path(__file__).with_name("check-architecture.py"))
        cls.architecture = importlib.util.module_from_spec(source)
        source.loader.exec_module(cls.architecture)
        source = importlib.util.spec_from_file_location("arm_runtime", Path(__file__).with_name("prune-arm64-runtime.py"))
        cls.arm_runtime = importlib.util.module_from_spec(source)
        source.loader.exec_module(cls.arm_runtime)

    def runtime_fixture(self, root, architecture="arm64"):
        import hashlib
        native = root / "python.exe"; native.write_bytes(self.image(self.architecture.MACHINES[architecture]))
        crt = root / self.arm_runtime.CRT; crt.write_bytes(self.image(0x8664))
        license = root / "LICENSE.txt"; license.write_text("Synthetic license")
        manifest = {"schemaVersion": 1, "architecture": architecture, "archiveSHA256": "a" * 64,
                    "files": [{"name": path.name, "bytes": path.stat().st_size,
                               "sha256": hashlib.sha256(path.read_bytes()).hexdigest()} for path in (native, crt, license)]}
        (root / "pacer-runtime.json").write_text(json.dumps(manifest))
        return crt, native, manifest

    def test_arm64_excludes_only_unreferenced_x64_crt_and_updates_its_manifest(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory); crt, native, before = self.runtime_fixture(root)
            foreign = root / "Vendor.dll"; foreign.write_bytes(self.image(0x8664))
            self.assertEqual(self.arm_runtime.prune(root, "arm64"), [crt.name])
            self.assertFalse(crt.exists()); self.assertTrue(native.exists()); self.assertTrue(foreign.exists())
            after = json.loads((root / "pacer-runtime.json").read_text())
            self.assertEqual(after, {**before, "files": [item for item in before["files"] if item["name"] != crt.name]})
            self.architecture.verify(native, "arm64", required_native=True)
            with self.assertRaises(ValueError): self.architecture.verify(foreign, "arm64")
            self.assertEqual(self.arm_runtime.prune(root, "arm64"), [])

    def test_referenced_crt_rejects_removal_without_mutating_payload(self):
        for encoding in ("ascii", "utf-16-le"):
            with self.subTest(encoding=encoding), tempfile.TemporaryDirectory() as directory:
                root = Path(directory); crt, native, _ = self.runtime_fixture(root)
                native.write_bytes(native.read_bytes() + "VCRUNTIME140_1.DLL".encode(encoding))
                original = (root / "pacer-runtime.json").read_bytes()
                with self.assertRaises(ValueError): self.arm_runtime.prune(root, "arm64")
                self.assertTrue(crt.exists()); self.assertEqual((root / "pacer-runtime.json").read_bytes(), original)

    def test_runtime_selection_leaves_x64_and_native_arm64_crt_unchanged(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory); crt, _, _ = self.runtime_fixture(root, "x64")
            original = (root / "pacer-runtime.json").read_bytes()
            self.assertEqual(self.arm_runtime.prune(root, "x64"), []); self.assertTrue(crt.exists())
            self.assertEqual((root / "pacer-runtime.json").read_bytes(), original)
            crt.write_bytes(self.image(0xAA64))
            self.assertEqual(self.arm_runtime.prune(root, "arm64"), []); self.assertTrue(crt.exists())

    def test_runtime_manifest_mismatch_aborts_before_removal(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory); crt, _, before = self.runtime_fixture(root)
            before["files"][1]["sha256"] = "0" * 64
            manifest = root / "pacer-runtime.json"; manifest.write_text(json.dumps(before)); original = manifest.read_bytes()
            with self.assertRaises(ValueError): self.arm_runtime.prune(root, "arm64")
            self.assertTrue(crt.exists()); self.assertEqual(manifest.read_bytes(), original)

    def image(self, machine, flags=None):
        data = bytearray(1024); data[:2] = b"MZ"; struct.pack_into("<I", data, 60, 128)
        data[128:132] = b"PE\0\0"; struct.pack_into("<HH", data, 132, machine, 1)
        optional = 152; size = 224 if machine == 0x14C else 240
        struct.pack_into("<H", data, 148, size); struct.pack_into("<H", data, optional, 0x10B if machine == 0x14C else 0x20B)
        struct.pack_into("<IIII", data, optional + size + 8, 512, 0x2000, 512, 512)
        if flags is not None:
            directory = optional + (96 if machine == 0x14C else 112)
            struct.pack_into("<II", data, directory + 14 * 8, 0x2000, 72)
            struct.pack_into("<I", data, 512 + 16, flags)
        return bytes(data)

    def test_native_machine_and_neutral_managed_images(self):
        for name, machine in self.architecture.MACHINES.items():
            with tempfile.TemporaryDirectory() as directory:
                image = Path(directory) / "synthetic.dll"; image.write_bytes(self.image(machine))
                self.architecture.verify(image, name, required_native=True)
                other = "arm64" if name == "x64" else "x64"
                with self.assertRaises(ValueError): self.architecture.verify(image, other)
                image.write_bytes(self.image(0x14C, 1)); self.architecture.verify(image, name)
                with self.assertRaises(ValueError): self.architecture.verify(image, name, required_native=True)
                for flags in (3, 0x11, 0):
                    image.write_bytes(self.image(0x14C, flags))
                    with self.subTest(flags=flags), self.assertRaises(ValueError): self.architecture.verify(image, name)

    def test_malformed_pe_headers_are_rejected_without_execution(self):
        data = self.image(0x8664)
        for broken in (b"", b"MZ", data[:100], data[:200], b"no" + data[2:]):
            with self.subTest(size=len(broken)), self.assertRaises(ValueError): self.architecture.inspect(broken)

    def test_complete_payload_rejects_one_wrong_native_dependency(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            for name in ["CodexPacer.exe", "PacerCompositionBackdrop.dll", "Engine/PacerEngine.exe", "Engine/PacerWindowsBridge.dll",
                         "Engine/PacerInstallerHooks.exe", "Maintenance/PacerMaintenance.exe", "Engine/Python/python.exe", "Engine/Python/python3.dll", "Engine/Python/python314.dll"]:
                target = root / name; target.parent.mkdir(parents=True, exist_ok=True); target.write_bytes(self.image(0xAA64))
            self.architecture.check(root, "arm64")
            (root / "Vendor.dll").write_bytes(self.image(0x8664))
            with self.assertRaises(ValueError): self.architecture.check(root, "arm64")

    def test_architecture_pins_and_minimum_build_declarations(self):
        lock = json.loads((contract.ROOT / "windows/toolchain-lock.json").read_text())
        self.assertEqual(set(lock["architectures"]), {"x64", "arm64"}); self.assertEqual(lock["minimumWindowsBuild"], 19041)
        self.assertRegex(lock["swiftArm64InstallerSHA256"], r"^[0-9a-f]{64}$")
        for suffix, arch in [("", "x64"), ("-arm64", "arm64")]:
            pin = json.loads((contract.ROOT / f"windows/InstallerSupport/Resources/python-runtime-lock{suffix}.json").read_text())
            self.assertEqual(pin["architecture"], arch); self.assertRegex(pin["sha256"], r"^[0-9a-f]{64}$")
            self.assertTrue(pin["url"].startswith("https://www.python.org/ftp/python/"))
        props = (contract.ROOT / "windows/desktop-platform.props").read_text()
        self.assertIn("win-$(PacerArchitecture)", props); self.assertIn("10.0.19041.0</SupportedOSPlatformVersion>", props)
        self.assertIn("MinVersion=10.0.19041", (contract.ROOT / "windows/Installer/CodexPacer.iss").read_text(encoding="utf-8-sig"))

    def test_arm64_ci_only_builds_and_packages(self):
        workflows = contract.ROOT / ".github/workflows"
        # Pull requests compile ARM64; the release packages it. Neither runs it.
        compile_only = contract.workflow_job((workflows / "platforms.yml").read_text(encoding="utf-8"), "windows-arm64")
        self.assertIn("runs-on: windows-11-arm", compile_only)
        self.assertNotRegex(compile_only, r"scripts/windows/(test|package)-")
        job = contract.workflow_job((workflows / "release.yml").read_text(encoding="utf-8"), "windows-arm64")
        self.assertIn("runs-on: windows-11-arm", job)
        self.assertIn("-Architecture arm64 -BuildOnly", job)
        for artifact in ("windows-app-arm64-unsigned", "windows-installer-arm64-unsigned"):
            self.assertIn(artifact, job)
        self.assertNotRegex(job, r"scripts/windows/test-(engine|desktop|presentation|preview|installer)\.ps1")


class WindowsReleaseTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        path = contract.ROOT / "scripts/release/prepare-windows-update.py"
        spec = importlib.util.spec_from_file_location("windows_release", path)
        cls.release = importlib.util.module_from_spec(spec); spec.loader.exec_module(cls.release)

    @staticmethod
    def image(version, plus=False):
        """A minimal PE whose RT_VERSION resource carries a fixed file version."""
        major, minor, patch, build = version
        fixed = struct.pack("<IIII", 0xFEEF04BD, 0x10000, (major << 16) | minor, (patch << 16) | build) + bytes(36)
        block = bytes(6) + "VS_VERSION_INFO".encode("utf-16-le") + bytes(4) + fixed
        def directory(identifier, target): return struct.pack("<IIHHHH", 0, 0, 0, 0, 0, 1) + struct.pack("<II", identifier, target)
        tree = directory(16, 0x80000000 | 24) + directory(1, 0x80000000 | 48) + directory(0, 72)
        tree += struct.pack("<IIII", 0x1000 + 88, len(block), 0, 0) + block
        size = 240 if plus else 224
        optional = bytearray(size); struct.pack_into("<H", optional, 0, 0x20B if plus else 0x10B)
        struct.pack_into("<II", optional, (112 if plus else 96) + 16, 0x1000, len(tree))
        section = b".rsrc\0\0\0" + struct.pack("<IIII", len(tree), 0x1000, 0x200, 0x200) + bytes(16)
        image = b"MZ" + bytes(0x3A) + struct.pack("<I", 0x40) + b"PE\0\0" + struct.pack("<HHIIIHH", 0x14C, 1, 0, 0, 0, size, 0) + bytes(optional) + section
        return image + bytes(0x200 - len(image)) + tree

    def test_windows_updates_share_the_mac_release_key_and_latest_release(self):
        source = (contract.ROOT / "windows/UpdateSupport/UpdateCatalog.cs").read_text(encoding="utf-8")
        info = plistlib.loads((contract.ROOT / "native/Info.plist").read_bytes())
        feed = re.search(r'ReleaseFeed = "([^"]+)"', source).group(1)
        key = re.search(r'Production \{ get; \} = new\(new Uri\(ReleaseFeed\), "([^"]+)", null\)', source).group(1)
        self.assertEqual(key, info["SUPublicEDKey"])
        self.assertEqual(feed, info["SUFeedURL"].replace("/appcast.xml", "/appcast-windows.xml"))
        self.assertEqual(json.loads((contract.ROOT / "scripts/release/windows-release.json").read_text())["schemaVersion"], 1)

    def test_release_feed_matches_the_windows_client_rules(self):
        release = self.release
        self.assertEqual(release.minimum_windows(), "10.0.19041")
        signature = base64.b64encode(bytes(range(64))).decode()
        assets = [(arch, release.asset_name("1.2.3", arch), 1000 + index, signature) for index, arch in enumerate(release.ARCHITECTURES)]
        notes = [("en", "English notes"), ("zh-Hans", "中文说明")]
        body = release.build_feed("1.2.3", "45", notes, assets, "10.0.19041")
        release.validate_feed(body, "1.2.3", "45", assets, "10.0.19041")
        item = ET.fromstring(body).find("./channel/item")
        enclosure = item.find("enclosure")
        self.assertEqual(enclosure.get("url"), "https://github.com/RyanZhangNTU/codex-pacer/releases/download/v1.2.3/Codex-Pacer-1.2.3-windows-x64-setup.exe")
        self.assertEqual(enclosure.get(f"{{{release.NAMESPACE}}}os"), "windows-x64")
        self.assertEqual(item.findtext(f"{{{release.NAMESPACE}}}version"), "1.2.3.45")
        for broken in (assets[:1], [(arch, name, length + 1, sig) for arch, name, length, sig in assets]):
            with self.assertRaises((ValueError, KeyError)): release.validate_feed(release.build_feed("1.2.3", "45", notes, broken, "10.0.19041"), "1.2.3", "45", assets, "10.0.19041")
        with self.assertRaises(ValueError): release.validate_feed(release.build_feed("1.2.3", "45", notes[:1], assets, "10.0.19041"), "1.2.3", "45", assets, "10.0.19041")
        signed = release.SIGNATURE_PREFIX + signature.encode() + b" -->\n" + body
        self.assertEqual(release.split_feed(signed), (signature, body))
        for invalid in (body, b"<!-- pacer-feed-ed25519:short -->\n" + body, signed.replace(b" -->\n", b"\n", 1)):
            with self.assertRaises(ValueError): release.split_feed(invalid)

    def test_installer_version_comes_from_its_own_version_resource(self):
        for plus in (False, True):
            self.assertEqual(self.release.file_version(self.image((4, 2, 1, 73), plus)), "4.2.1.73")
        with self.assertRaises(ValueError): self.release.file_version(b"MZ" + bytes(0x3A) + struct.pack("<I", 0x40) + b"NE\0\0" + bytes(64))

    def test_patches_live_inside_deltas_where_4_2_2_never_looks(self):
        release = self.release
        signature = base64.b64encode(bytes(range(64))).decode()
        manifest = "ab" * 32
        patch = {"name": release.patch_name("1.2.4", "x64", "1.2.3"), "length": 500, "signature": signature,
                 "from": "1.2.3.45", "baseManifestSHA256": "cd" * 32}
        assets = [("x64", release.asset_name("1.2.4", "x64"), 1000, signature, manifest, patch),
                  ("arm64", release.asset_name("1.2.4", "arm64"), 1001, signature, manifest, None)]
        notes = [("en", "English notes"), ("zh-Hans", "中文说明")]
        body = release.build_feed("1.2.4", "46", notes, assets, "10.0.19041")
        release.validate_feed(body, "1.2.4", "46", assets, "10.0.19041")
        items = ET.fromstring(body).findall("./channel/item")
        for item in items:
            # Windows 4.2.2 reads only the direct enclosure: still exactly the full installer.
            direct = item.findall("enclosure")
            self.assertEqual(len(direct), 1)
            self.assertTrue(direct[0].get("url").endswith("-setup.exe"))
            self.assertEqual(direct[0].get(f"{{{release.PACER_NAMESPACE}}}manifestSHA256"), manifest)
        nested = items[0].find(f"{{{release.NAMESPACE}}}deltas/enclosure")
        self.assertEqual(nested.get(f"{{{release.NAMESPACE}}}deltaFrom"), "1.2.3.45")
        self.assertEqual(nested.get(f"{{{release.PACER_NAMESPACE}}}baseManifestSHA256"), "cd" * 32)
        self.assertEqual(nested.get("url"), "https://github.com/RyanZhangNTU/codex-pacer/releases/download/v1.2.4/Codex-Pacer-1.2.4-windows-x64-update-from-1.2.3.exe")
        self.assertIsNone(items[1].find(f"{{{release.NAMESPACE}}}deltas"))
        for broken in ([assets[0][:5] + (dict(patch, length=501),), assets[1]], [assets[0][:5] + (None,), assets[1]],
                       [assets[0][:4] + ("ef" * 32, patch), assets[1]]):
            with self.subTest(broken=broken[0][4:]), self.assertRaises(ValueError):
                release.validate_feed(body, "1.2.4", "46", broken, "10.0.19041")

    def test_a_patch_is_kept_only_for_the_latest_published_base(self):
        release = self.release
        commit = "abcdef1" + "0" * 33
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            (directory / "x64").mkdir()
            stem = "CodexPacer-1.2.4-windows-x64-patch-abcdef1"
            data = self.image((1, 2, 4, 46))
            digest = __import__("hashlib").sha256(data).hexdigest()
            (directory / "x64" / (stem + ".exe")).write_bytes(data)
            (directory / "x64" / (stem + ".exe.sha256")).write_text(f"{digest}  {stem}.exe\n", encoding="utf-8")
            info = {"sha256": digest, "manifestSHA256": "ab" * 32, "architecture": "x64", "build": "1.2.4.46",
                    "baseVersion": "1.2.3", "baseBuild": "1.2.3.45", "baseManifestSHA256": "cd" * 32}
            (directory / "x64" / (stem + ".json")).write_text(json.dumps(info), encoding="utf-8")
            latest = {"x64": ("1.2.3.45", "cd" * 32)}
            self.assertEqual(release.patch(directory, "1.2.4", "46", commit, "x64", "ab" * 32, latest)[2]["baseBuild"], "1.2.3.45")
            for bases in ({"x64": ("1.2.3.44", "cd" * 32)}, {"x64": ("1.2.3.45", "ef" * 32)}, {}):
                with self.subTest(bases=bases):
                    self.assertIsNone(release.patch(directory, "1.2.4", "46", commit, "x64", "ab" * 32, bases))
            with self.assertRaises(ValueError):
                release.patch(directory, "1.2.4", "46", commit, "x64", "ef" * 32, latest)
            self.assertIsNone(release.patch(directory, "1.2.4", "46", "1234567" + "0" * 33, "x64", "ab" * 32, latest))
            metadata = {"feed": release.FEED, "installers": [
                {"name": release.asset_name("1.2.4", "x64"), "manifest": release.manifest_name("1.2.4", "x64"), "patch": {"name": release.patch_name("1.2.4", "x64", "1.2.3")}},
                {"name": release.asset_name("1.2.4", "arm64"), "manifest": release.manifest_name("1.2.4", "arm64"), "patch": None}]}
            (directory / "windows-update.json").write_text(json.dumps(metadata))
            self.assertEqual(release.asset_names(directory), [
                "Codex-Pacer-1.2.4-windows-x64-setup.exe", "Codex-Pacer-1.2.4-windows-x64-manifest.json", "Codex-Pacer-1.2.4-windows-x64-update-from-1.2.3.exe",
                "Codex-Pacer-1.2.4-windows-arm64-setup.exe", "Codex-Pacer-1.2.4-windows-arm64-manifest.json", "appcast-windows.xml"])


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
