"""Check the engine-stage platform boundary without freezing presentation sources."""
import argparse
from collections import Counter
from hashlib import sha256
import json
from pathlib import Path
import re
import sys

ROOT = Path(__file__).resolve().parents[2]
SYSTEM_MODULES = {"AppKit", "SwiftUI", "Security", "LocalAuthentication", "CoreServices", "Darwin", "WinSDK", "CoreGraphics", "CoreFoundation", "zlib"}
SHARED_MODULES = {"Foundation", "CryptoKit", "SQLite3", "CZstd"}
AVAILABILITY_MODULES = {"FoundationNetworking", "CoreGraphics"}
OWNERS = {"B4", "B5a", "B5b", "B5c", "C2", "F1", "P1", "P2", "P3", "P4"}
IMPORT = re.compile(r"^\s*(?:@\w+(?:\([^)]*\))?\s+)*import\s+(?:(?:struct|class|enum|protocol|typealias|let|var|func)\s+)?(\w+)", re.M)
BRANCH = re.compile(r"^\s*#(?:if|elseif)\s+(.+)", re.M)
GENERATED = ("ActivityNavigationTargetPortable.swift", "ClaudeCloudPortable.swift",
             "ClaudeDesktopRecordsPortable.swift", "ClaudeWebQuotaPortable.swift")
AUTHORITATIVE = {"ClaudeQuotaClient.swift", "ClaudeWebQuotaClient.swift", "ClaudeCloudProjectMonitor.swift",
                 "ClaudeCloudReplyStreams.swift", "ClaudeDesktopRecords.swift", "ActivityNavigationTarget.swift", "DeepSeekWebScripts.swift"}


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


def source_contract(name, text, transition):
    text = swift_code(text)
    modules = Counter(IMPORT.findall(text))
    system = {module: count for module, count in modules.items() if module in SYSTEM_MODULES - AVAILABILITY_MODULES}
    expected = transition.get("systemImports", {})
    if system != expected:
        raise ValueError("New or unaccounted system import in PacerCore: " + name)
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
    if Counter(branches) != Counter(transition.get("branches", [])):
        raise ValueError("New or unaccounted conditional branch in PacerCore: " + name)
    if system or branches:
        if transition.get("owner") not in OWNERS or not transition.get("reason"):
            raise ValueError("Core transition needs a cleanup owner: " + name)
    return bool(system), availability, len(branches)


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


def check(root=ROOT, require_parity=False):
    read = lambda name: json.loads((root / name).read_text(encoding="utf-8"))
    contract = read("windows/platform-contract.json")
    shared = read("windows/shared-core.json")
    core = root / "native/Sources/PacerCore"
    sources = set(shared["sources"])
    if len(sources) != len(shared["sources"]) or not AUTHORITATIVE <= sources:
        raise ValueError("Windows must select each authoritative shared source exactly once")
    if any(not (core / name).is_file() for name in sources):
        raise ValueError("Selected shared source is missing")
    if any(not (root / "native/Tests/PacerCoreTests" / name).is_file() for name in shared["tests"]):
        raise ValueError("Selected shared test is missing")
    if (root / "scripts/windows/build-claude-core.py").exists() or any((root / "windows/EngineSupport" / name).exists() for name in GENERATED):
        raise ValueError("Generated Claude copies must be removed with their generator")
    for name in ("scripts/windows/build-engine.ps1", "scripts/windows/test-engine.ps1", "Package.swift"):
        text = (root / name).read_text(encoding="utf-8")
        if "build-claude-core" in text or any(copy in text for copy in GENERATED):
            raise ValueError("Build/test still invokes generated Claude sources: " + name)
    counts = [0, 0, 0]
    all_sources = {path.name for path in core.glob("*.swift")}
    transitions = contract["coreTransitions"]
    for name in sorted(all_sources):
        item = transitions.get(name, {})
        result = source_contract(name, (core / name).read_text(encoding="utf-8"), item)
        counts = [a + b for a, b in zip(counts, result)]
        if name not in sources and (item.get("owner") not in OWNERS or not item.get("reason")):
            raise ValueError("Excluded Core source needs a cleanup owner: " + name)
    if set(transitions) - all_sources:
        raise ValueError("Remove transition entries when their source is removed")
    for item in contract["engineTransitions"]:
        if item["owner"] not in OWNERS or not item["reason"] or any(not (root / name).is_file() for name in item["files"]):
            raise ValueError("Engine transition needs existing files and a cleanup owner")
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
    macos = workflow.split("  macos:\n", 1)[1].split("  windows:\n", 1)[0].rstrip() + "\n"
    if sha256(macos.encode()).hexdigest() != contract["macosJobSHA256"]:
        raise ValueError("C1 must preserve both Mac jobs")
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
          f"Core sources Windows={len(sources)}, Mac={len(all_sources)}; coverage={json.dumps(stats, sort_keys=True)}")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--require-parity", action="store_true")
    args = parser.parse_args()
    try:
        check(require_parity=args.require_parity)
    except (ValueError, OSError, KeyError, IndexError) as error:
        print(str(error), file=sys.stderr)
        sys.exit(1)
