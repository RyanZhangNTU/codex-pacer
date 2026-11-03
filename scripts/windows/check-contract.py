"""Enforce the shared Core and host-target boundary on every platform."""
import argparse
from collections import Counter
from hashlib import sha256
import json
from pathlib import Path
import re
import sys

ROOT = Path(__file__).resolve().parents[2]
SYSTEM_MODULES = {"AppKit", "SwiftUI", "Security", "LocalAuthentication", "CoreServices", "Darwin", "WinSDK", "CoreGraphics", "CoreFoundation", "Glibc", "Musl", "ucrt", "zlib"}
SHARED_MODULES = {"Foundation", "CryptoKit", "SQLite3", "CZstd", "CGzip"}
AVAILABILITY_MODULES = {"FoundationNetworking", "CoreGraphics"}
OWNERS = {"P1", "P2", "P3", "P4"}
IMPORT = re.compile(r"^\s*(?:@\w+(?:\([^)]*\))?\s+)*import\s+(?:(?:struct|class|enum|protocol|typealias|let|var|func)\s+)?(\w+)", re.M)
BRANCH = re.compile(r"^\s*#(?:if|elseif)\s+(.+)", re.M)
PLATFORM_TEST_CONDITION = re.compile(
    r"\b(?:os|targetEnvironment)\s*\(|\bcanImport\s*\(\s*(?:PacerMacSupport|PacerEngineSupport|"
    r"AppKit|SwiftUI|Security|LocalAuthentication|CoreServices|CoreGraphics|CoreFoundation|Darwin|Glibc|WinSDK)\s*\)")
GENERATED = ("ActivityNavigationTargetPortable.swift", "ClaudeCloudPortable.swift",
             "ClaudeDesktopRecordsPortable.swift", "ClaudeWebQuotaPortable.swift")


def content_digest(data):
    try:
        return sha256(data.decode("utf-8").replace("\r\n", "\n").encode()).hexdigest()
    except UnicodeDecodeError:
        return sha256(data).hexdigest()


def swift_code(text):
    """Ignore comments and literals, including embedded Python/helper programs."""
    result = list(text)
    cursor = 0
    while cursor < len(text):
        start = cursor
        if text.startswith("//", cursor):
            cursor = text.find("\n", cursor)
            if cursor < 0:
                cursor = len(text)
        elif text.startswith("/*", cursor):
            cursor += 2
            depth = 1
            while cursor < len(text) and depth:
                if text.startswith("/*", cursor):
                    depth += 1; cursor += 2
                elif text.startswith("*/", cursor):
                    depth -= 1; cursor += 2
                else:
                    cursor += 1
        else:
            match = re.match(r'(#+)?("""|")', text[cursor:])
            if not match:
                cursor += 1
                continue
            hashes, quote = match[1] or "", match[2]
            cursor += len(match[0])
            end = quote + hashes
            while cursor < len(text):
                if text.startswith(end, cursor):
                    cursor += len(end)
                    break
                if text.startswith("\\" + hashes, cursor):
                    cursor += 2 + len(hashes)
                else:
                    cursor += 1
        for index in range(start, cursor):
            if result[index] not in "\r\n":
                result[index] = " "
    return "".join(result)


def shared_test_contract(name, text):
    """Platform imports and fixture paths may vary; test functions may not."""
    groups = []
    for number, line in enumerate(swift_code(text).splitlines(), 1):
        directive = re.match(r"^\s*#(if|elseif|else|endif)\b(.*)", line)
        if directive:
            kind, expression = directive.groups()
            if kind == "if":
                groups.append(bool(PLATFORM_TEST_CONDITION.search(expression)))
            elif kind == "elseif" and groups:
                groups[-1] |= bool(PLATFORM_TEST_CONDITION.search(expression))
            elif kind == "endif" and groups:
                groups.pop()
        if any(groups) and re.search(r"\bfunc\s+test\w*\s*\(", line):
            raise ValueError(f"Platform-conditional test belongs in a host test target: {name}:{number}")


def shared_tests_contract(directory):
    for path in sorted(directory.rglob("*.swift")):
        shared_test_contract(path.relative_to(directory).as_posix(), path.read_text(encoding="utf-8"))


def source_contract(name, text):
    text = swift_code(text)
    modules = Counter(IMPORT.findall(text))
    system = {module: count for module, count in modules.items() if module in SYSTEM_MODULES - AVAILABILITY_MODULES}
    if system:
        raise ValueError("System import is forbidden in PacerCore: " + name + ": " + ", ".join(sorted(system)))
    unknown = set(modules) - SHARED_MODULES - SYSTEM_MODULES - AVAILABILITY_MODULES
    if unknown:
        raise ValueError("Unreviewed PacerCore module: " + name + ": " + ", ".join(sorted(unknown)))
    branches = []
    availability = 0
    stack = []
    for line in text.splitlines():
        stripped = line.strip()
        if stripped.startswith("#if "):
            stack.append(stripped[4:])
        elif stripped.startswith("#elseif "):
            if stack:
                stack[-1] = stripped[8:]
        elif stripped == "#else":
            if stack:
                if stack[-1] in {"canImport(" + module + ")" for module in AVAILABILITY_MODULES}:
                    raise ValueError("Availability guard cannot fork business logic: " + name)
                stack[-1] = "else"
        elif stripped == "#endif":
            if stack:
                stack.pop()
        match = IMPORT.match(line)
        if stack and stack[-1] in {"canImport(" + module + ")" for module in AVAILABILITY_MODULES} and stripped and not stripped.startswith("#") and not match:
            raise ValueError("Availability guard may contain imports only: " + name)
        if match and match[1] in AVAILABILITY_MODULES and (not stack or stack[-1] != "canImport(" + match[1] + ")"):
            raise ValueError("Availability import needs its own canImport guard: " + name)
        match = BRANCH.match(line)
        if match:
            branch = match[1].strip()
            if branch in {"canImport(" + module + ")" for module in AVAILABILITY_MODULES}:
                availability += 1
            else:
                branches.append(branch)
    if branches:
        raise ValueError("Platform/business conditional is forbidden in PacerCore: " + name)
    return False, availability, 0


def native_package_wiring(text):
    code = swift_code(text)
    result = {}
    for match in re.finditer(r'\.(target|executableTarget|testTarget)\(\s*name:\s*"([^"]+)"', text):
        start = text.index("(", match.start())
        depth, end = 1, start + 1
        while depth and end < len(code):
            depth += (code[end] == "(") - (code[end] == ")")
            end += 1
        fragment = text[start:end]
        dependencies = re.search(r"dependencies:\s*\[([^\]]*)\]", fragment)
        names = list(dict.fromkeys(re.findall(r'"([^"]+)"', dependencies[1]))) if dependencies else []
        result[match[2]] = {"kind": match[1], "dependencies": names}
    return result


def core_contract(directory):
    sources = sorted(directory.rglob("*.swift"))
    counts = [0, 0, 0]
    for path in sources:
        result = source_contract(path.relative_to(directory).as_posix(), path.read_text(encoding="utf-8"))
        counts = [a + b for a, b in zip(counts, result)]
    return sources, counts


def target_fragments(text):
    """Retain every declaration, including both platform branches of a manifest."""
    code = swift_code(text)
    for match in re.finditer(r'\.(target|executableTarget|testTarget)\(\s*name:\s*"([^"]+)"', text):
        if not code[match.start():].startswith("." + match[1] + "("):
            continue
        start = text.index("(", match.start())
        depth, end = 1, start + 1
        while depth and end < len(code):
            depth += (code[end] == "(") - (code[end] == ")")
            end += 1
        yield match[2], text[start + 1:end - 1]


def target_arguments(fragment):
    code = swift_code(fragment)
    depth, start, parts = 0, 0, []
    for index, character in enumerate(code):
        if character in "([{": depth += 1
        elif character in ")]}": depth -= 1
        elif character == "," and depth == 0:
            parts.append((start, index)); start = index + 1
    parts.append((start, len(fragment)))
    result = {}
    for start, end in parts:
        match = re.match(r"\s*(\w+)\s*:", code[start:end])
        if match:
            result[match[1]] = fragment[start + match.end():end].strip()
    return result


def package_boundary(text, native=False):
    targets = list(target_fragments(text))
    cores = [target_arguments(body) for name, body in targets if name == "PacerCore"]
    tests = [target_arguments(body) for name, body in targets if name == "PacerCoreTests"]
    if not cores or not tests:
        raise ValueError("The complete PacerCore and PacerCoreTests targets are required")
    for arguments, directory in [(item, "Sources/PacerCore") for item in cores] + [(item, "Tests/PacerCoreTests") for item in tests]:
        expected = None if native else '"native/' + directory + '"'
        if arguments.get("path") != expected or {"sources", "exclude"} & arguments.keys():
            raise ValueError("Core source/test selection is forbidden; compile the complete directory")
    for item in cores:
        try:
            dependencies = json.loads(re.sub(r",\s*]$", "]", item.get("dependencies", "[]")))
        except ValueError as error:
            raise ValueError("Core dependencies must be an explicit shared-module array") from error
        if not isinstance(dependencies, list) or any(not isinstance(name, str) for name in dependencies) or set(dependencies) - {"CZstd", "CGzip", "SQLite3", "CryptoKit"}:
            raise ValueError("PacerCore cannot depend on host targets")
    if not native:
        support = [target_arguments(body) for name, body in targets if name == "PacerEngineSupport"]
        if len(support) != 1 or support[0].get("path") != '"windows/EngineSupport"' or '"PacerCore"' not in support[0].get("dependencies", ""):
            raise ValueError("EngineSupport must be a separate target depending on PacerCore")


def no_transition_inventories(contract, coverage):
    if {"coreTransitions", "engineTransitions", "sourceSelectionRemoval", "macosJobSHA256"} & contract.keys():
        raise ValueError("The closed C phase cannot retain source/target exception inventories")
    if {"remainingCoreSources", "remainingCoreTests"} & coverage.keys():
        raise ValueError("The closed C phase cannot retain Core source/test selection inventories")


def workflow_boundary(workflow):
    macos = workflow.split("  macos:\n", 1)[1].split("  windows:\n", 1)[0]
    windows = workflow.split("  windows:\n", 1)[1]
    for job in (macos, windows):
        for script in ("scripts/windows/check-contract.py", "scripts/windows/test_contract.py"):
            if not re.search(r"^\s+python3? " + re.escape(script) + r"\s*$", job, re.M):
                raise ValueError("Every platform job must run the strict contract and its tests")


def check(root=ROOT, require_parity=False):
    read = lambda name: json.loads((root / name).read_text(encoding="utf-8"))
    contract = read("windows/platform-contract.json")
    core = root / "native/Sources/PacerCore"
    coverage = read("windows/platform-coverage.json")
    no_transition_inventories(contract, coverage)
    if (root / "windows/shared-core.json").exists():
        raise ValueError("The closed C phase cannot retain shared-core.json")
    package_boundary((root / "Package.swift").read_text(encoding="utf-8"))
    package_boundary((root / "native/Package.swift").read_text(encoding="utf-8"), native=True)
    if (root / "scripts/windows/build-claude-core.py").exists() or any((root / "windows/EngineSupport" / name).exists() for name in GENERATED):
        raise ValueError("Generated Claude copies must be removed with their generator")
    for name in ("scripts/windows/build-engine.ps1", "scripts/windows/test-engine.ps1", "Package.swift"):
        text = (root / name).read_text(encoding="utf-8")
        if "build-claude-core" in text or any(copy in text for copy in GENERATED):
            raise ValueError("Build/test still invokes generated Claude sources: " + name)
    all_sources, counts = core_contract(core)
    shared_tests_contract(root / "native/Tests/PacerCoreTests")
    gzip = root / "native/Sources/CGzip"
    provenance = read("native/Sources/CGzip/provenance.json")
    for name, digest in provenance["sha256"].items():
        if sha256((gzip / "vendor" / name).read_bytes()).hexdigest() != digest:
            raise ValueError("Vendored gzip source differs from its pinned upstream: " + name)
    for name, digest in contract["protectedFiles"].items():
        if content_digest((root / name).read_bytes()) != digest:
            raise ValueError("Protected shipping file differs from develop: " + name)
    # Package target wiring may change after review; shipping identity and the
    # dependency, deployment and loader invariants stay explicit.
    package = (root / "native/Package.swift").read_text(encoding="utf-8")
    for invariant in contract["nativePackageInvariants"]:
        if invariant not in package:
            raise ValueError("Shipping package invariant changed: " + invariant)
    if re.findall(r'\.package\(url:\s*"([^"]+)",\s*exact:\s*"([^"]+)"\)', package) != [("https://github.com/sparkle-project/Sparkle", "2.10.0")]:
        raise ValueError("Shipping package dependencies changed")
    if native_package_wiring(package) != contract["nativeTargets"]:
        raise ValueError("Shipping target wiring needs explicit review in platform-contract.json")
    workflow = (root / ".github/workflows/platforms.yml").read_text(encoding="utf-8")
    workflow_boundary(workflow)
    features = read("windows/platform-coverage.json")["features"]
    if len(features) != 47 or len({item["id"] for item in features}) != 47 or {item["id"] for item in features} != set(contract["featureIDs"]):
        raise ValueError("The 47-feature acceptance inventory must stay complete")
    for item in features:
        for name in item["evidence"]:
            if not (root / name).is_file():
                raise ValueError("Acceptance evidence is missing: " + name)
        if item["status"] != "verified" and item.get("cleanupOwner") not in OWNERS:
            raise ValueError("Incomplete feature needs an owner: " + item["id"])
    pending = [item["id"] for item in features if item["status"] != "verified"]
    if require_parity and pending:
        raise ValueError("Windows acceptance remains incomplete: " + ", ".join(pending))
    stats = dict(Counter(item["status"] for item in features))
    print(f"Platform contract passed: Core system-import files={counts[0]}, canImport branches={counts[1]}, other branches={counts[2]}; "
          f"Core sources Windows={len(all_sources)}, Mac={len(all_sources)}; coverage={json.dumps(stats, sort_keys=True)}")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--require-parity", action="store_true")
    args = parser.parse_args()
    try:
        check(require_parity=args.require_parity)
    except (ValueError, OSError, KeyError, IndexError) as error:
        print(str(error), file=sys.stderr)
        sys.exit(1)
