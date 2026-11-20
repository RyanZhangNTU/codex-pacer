"""Build from a source snapshot outside OneDrive and the working tree."""
from hashlib import sha256
from pathlib import Path
import argparse
import json
import shutil
import tempfile

ROOT = Path(__file__).resolve().parents[2]
PRODUCT_DIRECTORIES = (
    "native/Sources/PacerCore", "native/Sources/CZstd", "native/Sources/CGzip",
    "windows/Engine", "windows/EngineSupport", "windows/Native",
    "windows/Bridge", "windows/InstallerSupport", "windows/InstallerHooks",
)

TEST_DIRECTORIES = ("native/Tests/PacerCoreTests", "native/Tests/PresentationTables", "windows/Tests/EngineTests")
BUILD_INPUTS = ("windows/toolchain-lock.json", "scripts/windows/stage-engine.py", "scripts/windows/build-engine.ps1",
                "scripts/windows/build-adapters.ps1", "scripts/windows/setup-swift.ps1", "scripts/windows/environment.ps1",
                "scripts/windows/architecture.ps1")
BINARIES = ("PacerEngine.exe", "PacerWindowsBridge.dll", "PacerInstallerHooks.exe")
BUNDLES = tuple("CodexPacerPortable_" + target + ".resources" for target in ("PacerCore", "PacerEngineSupport", "WindowsInstallerSupport"))


def inputs(directories):
    sources = [ROOT / "Package.swift", ROOT / "native/Info.plist"]
    if (ROOT / "Package.resolved").is_file():
        sources.append(ROOT / "Package.resolved")
    for name in directories:
        sources.extend(path for path in (ROOT / name).rglob("*") if path.is_file())
    return sorted(sources)


def stage():
    digest = sha256()
    entries = []
    for path in inputs(PRODUCT_DIRECTORIES + TEST_DIRECTORIES):
        relative = path.relative_to(ROOT).as_posix()
        data = path.read_bytes()
        digest.update(relative.encode() + b"\0" + sha256(data).digest())
        entries.append((relative, data))
    fingerprint = digest.hexdigest()
    directory = Path(tempfile.gettempdir()) / "codex-pacer-windows" / fingerprint[:24]
    directory.mkdir(parents=True, exist_ok=True)
    for relative, data in entries:
        target = directory / relative
        target.parent.mkdir(parents=True, exist_ok=True)
        if target.is_symlink():
            raise RuntimeError("Source snapshot contains an unexpected symbolic link")
        if not target.exists() or target.read_bytes() != data:
            target.write_bytes(data)
    (directory / "source-receipt.json").write_text(json.dumps({
        "sha256": fingerprint,
        "files": {name: sha256(data).hexdigest() for name, data in entries},
    }, indent=2) + "\n", encoding="utf-8")
    return directory


def product_key(architecture, configuration):
    digest = sha256()
    for path in sorted(inputs(PRODUCT_DIRECTORIES) + [ROOT / name for name in BUILD_INPUTS]):
        digest.update(path.relative_to(ROOT).as_posix().encode() + b"\0" + sha256(path.read_bytes()).digest())
    return f"windows-engine-v2-{architecture}-{configuration}-{digest.hexdigest()}"


def inventory(directory):
    files = [directory / name for name in BINARIES]
    for name in BUNDLES:
        if not any(path.is_file() for path in (directory / name).rglob("*")):
            raise ValueError("Missing Windows engine resource bundle " + name)
    for bundle in sorted(directory.glob("*.resources")):
        files.extend(path for path in sorted(bundle.rglob("*")) if path.is_file())
    return {path.relative_to(directory).as_posix(): sha256(path.read_bytes()).hexdigest() for path in files}


def cached_products(products, key):
    try:
        receipt = json.loads((products / "products.json").read_text(encoding="utf-8"))
        directory = products / receipt["directory"]
        if directory.parent == products and directory.name.startswith("payload-") and receipt["key"] == key:
            if inventory(directory) == receipt["files"]:
                return directory
    except (OSError, KeyError, TypeError, ValueError):
        pass
    return None


def save_products(products, binary, key):
    files = inventory(binary)
    products.mkdir(parents=True, exist_ok=True)
    directory = Path(tempfile.mkdtemp(dir=products, prefix="payload-"))
    for name in files:
        target = directory / name
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(binary / name, target)
    receipt = directory / "receipt.tmp"
    receipt.write_text(json.dumps(dict(key=key, directory=directory.name, files=files)), encoding="utf-8")
    receipt.replace(products / "products.json")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    action = parser.add_mutually_exclusive_group()
    action.add_argument("--product-key", action="store_true")
    action.add_argument("--restore", type=Path, metavar="PRODUCTS")
    action.add_argument("--save", type=Path, metavar="PRODUCTS")
    parser.add_argument("--binary", type=Path)
    parser.add_argument("--architecture", choices=("x64", "arm64"), default="x64")
    parser.add_argument("--configuration", choices=("debug", "release"), default="release")
    args = parser.parse_args()
    if args.product_key or args.restore or args.save:
        key = product_key(args.architecture, args.configuration)
        if args.restore:
            print(cached_products(args.restore.resolve(), key) or "")
        elif args.save:
            if not args.binary:
                parser.error("--save needs --binary")
            save_products(args.save, args.binary, key)
        else:
            print(key)
    else:
        print(stage())
