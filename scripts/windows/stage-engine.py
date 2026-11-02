"""Build from a source snapshot outside OneDrive and the working tree."""
from hashlib import sha256
from pathlib import Path
import json
import tempfile

ROOT = Path(__file__).resolve().parents[2]
DIRECTORIES = (
    "native/Sources/PacerCore", "native/Sources/CZstd", "native/Tests/PacerCoreTests", "native/Tests/PresentationTables",
    "windows/Engine", "windows/EngineSupport", "windows/Native", "windows/Tests/EngineTests",
    "windows/Localization",
)


def stage():
    sources = [ROOT / "Package.swift", ROOT / "windows/shared-core.json", ROOT / "native/Info.plist"]
    if (ROOT / "Package.resolved").is_file():
        sources.append(ROOT / "Package.resolved")
    for name in DIRECTORIES:
        sources.extend(path for path in (ROOT / name).rglob("*") if path.is_file())
    digest = sha256()
    entries = []
    for path in sorted(sources):
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


if __name__ == "__main__":
    print(stage())
