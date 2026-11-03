"""Remove an unused x64 CRT shipped in upstream ARM64 runtime bundles."""
import argparse
import hashlib
import importlib.util
import json
from pathlib import Path

_source = importlib.util.spec_from_file_location("pacer_pe", Path(__file__).with_name("check-architecture.py"))
_pe = importlib.util.module_from_spec(_source)
_source.loader.exec_module(_pe)
CRT = "vcruntime140_1.dll"


def references(path):
    # Conservative scan: static/delay imports and literal LoadLibrary names
    # must all be absent. A diagnostic string also blocks removal safely.
    needles = [CRT.encode("ascii"), CRT.encode("utf-16-le")]
    tail = b""
    with path.open("rb") as stream:
        while block := stream.read(1024 * 1024):
            data = (tail + block).lower()
            if any(needle in data for needle in needles):
                return True
            tail = data[-max(map(len, needles)):]
    return False


def prune(root, architecture):
    if architecture != "arm64":
        return []
    root = root.resolve(strict=True)
    candidates = []
    images = []
    for path in root.rglob("*"):
        if not path.is_file() or path.suffix.lower() not in (".exe", ".dll", ".pyd"):
            continue
        if path.is_symlink() or not path.resolve().is_relative_to(root):
            raise ValueError("Linked runtime image is not allowed: " + path.name)
        images.append(path)
        if path.name.lower() == CRT:
            with path.open("rb") as stream:
                machine, neutral = _pe.inspect(stream.read(4 * 1024 * 1024))
            if machine == _pe.MACHINES["x64"] and not neutral:
                candidates.append(path)
    if not candidates:
        return []
    for path in images:
        if path not in candidates and references(path):
            raise ValueError("ARM64 image still references the x64 CRT: " + str(path.relative_to(root)))
    manifests = []
    for path in candidates:
        manifest = path.with_name("pacer-runtime.json")
        if not manifest.exists():
            continue
        if manifest.is_symlink() or not manifest.resolve().is_relative_to(root):
            raise ValueError("Linked runtime manifest is not allowed")
        value = json.loads(manifest.read_text(encoding="utf-8-sig"))
        entries = [item for item in value["files"] if item["name"].lower() == CRT]
        if (value["schemaVersion"] != 1 or value["architecture"] != "arm64" or len(entries) != 1
                or entries[0]["bytes"] != path.stat().st_size
                or entries[0]["sha256"] != hashlib.sha256(path.read_bytes()).hexdigest()):
            raise ValueError("The runtime manifest does not match the excluded CRT")
        value["files"] = [item for item in value["files"] if item["name"].lower() != CRT]
        manifests.append((manifest, value))
    # Finish validation before changing the disposable packaging directory.
    for manifest, value in manifests:
        manifest.write_text(json.dumps(value, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    for path in candidates:
        path.unlink()
    return [str(path.relative_to(root)) for path in candidates]


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", required=True, type=Path)
    parser.add_argument("--architecture", required=True, choices=_pe.MACHINES)
    args = parser.parse_args()
    removed = prune(args.root, args.architecture)
    print("ARM64 runtime selection: " + str(len(removed)) + " unreferenced x64 CRT files excluded")
