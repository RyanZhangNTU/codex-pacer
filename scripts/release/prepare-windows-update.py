#!/usr/bin/env python3
"""Fetch, sign and verify the Windows installers and feed for a GitHub release.

The Release workflow builds both Windows installers on the release commit and
passes them to this script with --artifacts; a local release downloads them from
that workflow's newest run on the commit. The script checks their name, checksum
and version resource, and signs them and appcast-windows.xml with the Sparkle
Ed25519 key that already signs the Mac appcast. The installers are not
Authenticode signed.

Each release also publishes its file manifest. When CI built a patch installer
from the latest published build, and that build is still the latest in the
signed public feed, the patch is signed and listed inside <sparkle:deltas>,
which Windows 4.2.2 and earlier never read. Otherwise the patch is dropped.
"""
import argparse
import base64
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import shutil
import struct
import subprocess
import sys
import tempfile
from urllib.parse import quote
import xml.etree.ElementTree as ET

# The contract tests load this file by path, so its directory is not always on sys.path.
sys.path.insert(0, str(Path(__file__).resolve().parent))
import sparkle_key  # noqa: E402

ROOT = Path(__file__).resolve().parents[2]
REPOSITORY = "RyanZhangNTU/codex-pacer"
NAMESPACE = "http://www.andymatuschak.org/xml-namespaces/sparkle"
PACER_NAMESPACE = "urn:codex-pacer:windows-update"
XML_LANGUAGE = "{http://www.w3.org/XML/1998/namespace}lang"
FEED = "appcast-windows.xml"
SIGNATURE_PREFIX = b"<!-- pacer-feed-ed25519:"
ARCHITECTURES = ("x64", "arm64")
# The Windows client selects notes by its own UI language names.
LANGUAGES = (("en", "en"), ("zh-Hans", "zh-CN"))
ET.register_namespace("sparkle", NAMESPACE)
ET.register_namespace("pacer", PACER_NAMESPACE)


def enabled():
    """Windows joins releases once its first version ships; afterwards every release must carry it."""
    return json.loads((ROOT / "scripts/release/windows-release.json").read_text())["publish"] is True


def asset_name(version, architecture):
    return f"Codex-Pacer-{version}-windows-{architecture}-setup.exe"


def manifest_name(version, architecture):
    return f"Codex-Pacer-{version}-windows-{architecture}-manifest.json"


def patch_name(version, architecture, base_version):
    return f"Codex-Pacer-{version}-windows-{architecture}-update-from-{base_version}.exe"


def unpack(asset):
    """(architecture, name, length, signature[, manifest SHA-256[, patch]]): older callers pass four fields."""
    architecture, name, length, signature, *extra = asset
    return architecture, name, length, signature, (extra[0] if extra else None), (extra[1] if len(extra) > 1 else None)


def minimum_windows():
    return "10.0.{}".format(json.loads((ROOT / "windows/toolchain-lock.json").read_text())["minimumWindowsBuild"])


def application_version():
    info = plistlib.loads((ROOT / "native/Info.plist").read_bytes())
    version, build = info["CFBundleShortVersionString"], info["CFBundleVersion"]
    if not re.fullmatch(r"\d+\.\d+\.\d+", version) or not build.isdigit():
        raise ValueError("The shared application version is invalid.")
    return version, build, info["SUPublicEDKey"]


def file_version(data):
    """Return the FILEVERSION of a PE image's own RT_VERSION resource."""
    def u16(offset): return struct.unpack_from("<H", data, offset)[0]
    def u32(offset): return struct.unpack_from("<I", data, offset)[0]
    header = u32(0x3C)
    if data[:2] != b"MZ" or data[header:header + 4] != b"PE\0\0":
        raise ValueError("The installer is not a PE image.")
    sections, optional_size, optional = u16(header + 6), u16(header + 20), header + 24
    directories = optional + {0x10B: 96, 0x20B: 112}[u16(optional)]
    table = [struct.unpack_from("<IIII", data, optional + optional_size + 40 * index + 8) for index in range(sections)]
    def offset(rva):
        for size, address, raw_size, raw in table:
            if address <= rva < address + max(size, raw_size):
                return raw + rva - address
        raise ValueError("The version resource lies outside the image.")
    base = offset(u32(directories + 16))
    def entry(directory, identifier=None):
        count = u16(directory + 12) + u16(directory + 14)
        for index in range(count):
            name, target = struct.unpack_from("<II", data, directory + 16 + 8 * index)
            if identifier is None or name == identifier:
                return target
        raise ValueError("The installer has no version resource.")
    versions = entry(base, 16)
    languages = entry(base + (versions & 0x7FFFFFFF)) if versions & 0x80000000 else None
    leaf = entry(base + (languages & 0x7FFFFFFF)) if languages is not None and languages & 0x80000000 else None
    if leaf is None or leaf & 0x80000000:
        raise ValueError("The installer version resource is malformed.")
    rva, size = struct.unpack_from("<II", data, base + leaf)
    block = data[offset(rva):offset(rva) + size]
    fixed = block.find(struct.pack("<I", 0xFEEF04BD))
    if fixed < 0:
        raise ValueError("The installer has no fixed file version.")
    major_minor, patch_build = struct.unpack_from("<II", block, fixed + 8)
    return f"{major_minor >> 16}.{major_minor & 0xFFFF}.{patch_build >> 16}.{patch_build & 0xFFFF}"


def sign(tools, path):
    """Sign bytes with the update key; the file must not end in .xml, which sign_update treats as an appcast."""
    output = sparkle_key.run(tools / "sign_update", path, capture=True)
    match = re.fullmatch(r'\s*sparkle:edSignature="([A-Za-z0-9+/]+=*)" length="(\d+)"\s*', output)
    if not match or int(match.group(2)) != path.stat().st_size or len(base64.b64decode(match.group(1), validate=True)) != 64:
        raise ValueError("sign_update returned an unexpected signature.")
    verify(tools, path, match.group(1))
    return match.group(1)


def verify(tools, path, signature):
    sparkle_key.run(tools / "sign_update", "--verify", path, signature)


def build_feed(version, build, notes, assets, minimum):
    """notes: (language, text) pairs; assets: see unpack(). A patch is a dict with name, length, signature,
    from (the base build) and baseManifestSHA256."""
    rss = ET.Element("rss", {"version": "2.0"})
    channel = ET.SubElement(rss, "channel")
    ET.SubElement(channel, "title").text = "Codex Pacer"
    prefix = f"https://github.com/{REPOSITORY}/releases/download/v{quote(version, safe='')}/"
    for asset in assets:
        architecture, name, length, signature, manifest, patch = unpack(asset)
        item = ET.SubElement(channel, "item")
        ET.SubElement(item, "title").text = version
        ET.SubElement(item, f"{{{NAMESPACE}}}version").text = f"{version}.{build}"
        ET.SubElement(item, f"{{{NAMESPACE}}}shortVersionString").text = version
        ET.SubElement(item, f"{{{NAMESPACE}}}minimumSystemVersion").text = minimum
        for language, text in notes:
            ET.SubElement(item, "description", {XML_LANGUAGE: language}).text = text
        full = {"url": prefix + quote(name), "length": str(length), "type": "application/octet-stream",
                f"{{{NAMESPACE}}}os": f"windows-{architecture}", f"{{{NAMESPACE}}}edSignature": signature}
        if manifest:
            full[f"{{{PACER_NAMESPACE}}}manifestSHA256"] = manifest
        ET.SubElement(item, "enclosure", full)
        if patch:
            # Nested, so 4.2.2 clients still see exactly one direct enclosure.
            deltas = ET.SubElement(item, f"{{{NAMESPACE}}}deltas")
            ET.SubElement(deltas, "enclosure", {"url": prefix + quote(patch["name"]), "length": str(patch["length"]), "type": "application/octet-stream",
                                                f"{{{NAMESPACE}}}os": f"windows-{architecture}", f"{{{NAMESPACE}}}deltaFrom": patch["from"],
                                                f"{{{NAMESPACE}}}edSignature": patch["signature"],
                                                f"{{{PACER_NAMESPACE}}}baseManifestSHA256": patch["baseManifestSHA256"]})
    ET.indent(rss, space="    ")
    return ET.tostring(rss, encoding="utf-8", xml_declaration=True) + b"\n"


def split_feed(signed):
    """Mirror the Windows client: one signature comment line, then the signed XML bytes."""
    newline = signed.find(b"\n")
    header = signed[:newline]
    if newline < 0 or newline > 256 or not header.startswith(SIGNATURE_PREFIX) or not header.endswith(b" -->"):
        raise ValueError("The Windows feed must start with its signature line.")
    signature = header[len(SIGNATURE_PREFIX):-4].decode("ascii")
    if len(base64.b64decode(signature, validate=True)) != 64:
        raise ValueError("The Windows feed signature is malformed.")
    return signature, signed[newline + 1:]


def validate_feed(body, version, build, assets, minimum):
    items = ET.fromstring(body).findall("./channel/item")
    if len(items) != len(ARCHITECTURES):
        raise ValueError("The Windows feed must contain exactly one update per architecture.")
    expected = {unpack(asset)[0]: unpack(asset)[1:] for asset in assets}
    prefix = f"https://github.com/{REPOSITORY}/releases/download/v{quote(version, safe='')}/"
    for item in items:
        if len(item.findall("enclosure")) != 1:
            raise ValueError("Each Windows feed item needs exactly one direct enclosure, as 4.2.2 clients require.")
        enclosure = item.find("enclosure")
        architecture = enclosure.get(f"{{{NAMESPACE}}}os", "").removeprefix("windows-")
        name, length, signature, manifest, patch = expected.pop(architecture)
        if enclosure.get(f"{{{PACER_NAMESPACE}}}manifestSHA256") != manifest:
            raise ValueError("Windows feed manifest does not match this release.")
        deltas = item.findall(f"{{{NAMESPACE}}}deltas")
        if patch is None:
            if deltas:
                raise ValueError("The Windows feed lists a patch this release does not carry.")
        else:
            entries = deltas[0].findall("enclosure") if len(deltas) == 1 else []
            if len(entries) != 1 or entries[0].attrib != {
                    "url": prefix + quote(patch["name"]), "length": str(patch["length"]), "type": "application/octet-stream",
                    f"{{{NAMESPACE}}}os": f"windows-{architecture}", f"{{{NAMESPACE}}}deltaFrom": patch["from"],
                    f"{{{NAMESPACE}}}edSignature": patch["signature"], f"{{{PACER_NAMESPACE}}}baseManifestSHA256": patch["baseManifestSHA256"]}:
                raise ValueError("Windows feed patch does not match its signed installer.")
        if (item.findtext(f"{{{NAMESPACE}}}version") != f"{version}.{build}" or item.findtext(f"{{{NAMESPACE}}}shortVersionString") != version
                or item.findtext(f"{{{NAMESPACE}}}minimumSystemVersion") != minimum or item.find(f"{{{NAMESPACE}}}releaseNotesLink") is not None):
            raise ValueError("Windows feed metadata does not match this release.")
        if enclosure.get("url") != prefix + quote(name) or enclosure.get("length") != str(length) or enclosure.get(f"{{{NAMESPACE}}}edSignature") != signature:
            raise ValueError("Windows feed download does not match its signed installer.")
        if {entry.get(XML_LANGUAGE) for entry in item.findall("description")} != {language for language, _ in LANGUAGES}:
            raise ValueError("Windows release notes must include English and Simplified Chinese.")
    if expected:
        raise ValueError("The Windows feed is missing an architecture.")


def download(commit, directory):
    """The installers of the newest Release workflow run on this commit that built both of them."""
    runs = json.loads(subprocess.check_output(["gh", "run", "list", "--repo", REPOSITORY, "--workflow", "release.yml", "--commit", commit,
        "--json", "databaseId,headSha,status", "--limit", "20"], text=True))
    wanted = {f"windows-installer-{architecture}-unsigned" for architecture in ARCHITECTURES}
    for run in sorted((run["databaseId"] for run in runs if run["headSha"] == commit and run["status"] == "completed"), reverse=True):
        # A failed publish job still leaves the installers its Windows jobs built.
        listed = json.loads(subprocess.check_output(["gh", "api", f"repos/{REPOSITORY}/actions/runs/{run}/artifacts",
                                                     "--jq", "[.artifacts[] | select(.expired | not) | .name]"], text=True))
        if wanted <= set(listed):
            for architecture in ARCHITECTURES:
                subprocess.run(["gh", "run", "download", str(run), "--repo", REPOSITORY, "--name", f"windows-installer-{architecture}-unsigned",
                                "--dir", str(directory / architecture)], check=True)
            return run
    raise ValueError("No Release workflow run built the installers for this commit; start one manually, which publishes nothing.")


def checked(directory, architecture, name):
    """An artifact file whose bytes match the checksum CI wrote beside it."""
    path = directory / architecture / name
    data = path.read_bytes()
    digest = hashlib.sha256(data).hexdigest()
    if (directory / architecture / (name + ".sha256")).read_text(encoding="utf-8") != f"{digest}  {name}\n":
        raise ValueError(f"The {architecture} {name} does not match its CI checksum.")
    return path, data, digest


def manifest(directory, version, build, commit, architecture):
    name = f"CodexPacer-{version}-windows-{architecture}-manifest-{commit[:7]}.json"
    if not (directory / architecture / name).exists():
        raise ValueError(f"The {architecture} artifact has no manifest for {commit[:7]}.")
    path, data, digest = checked(directory, architecture, name)
    info = json.loads(data)
    if (info.get("version"), str(info.get("build")), info.get("architecture"), info.get("sourceCommit")) != (version, build, architecture, commit):
        raise ValueError(f"The {architecture} manifest describes another build.")
    return path, digest


def published_bases(tools):
    """Build and manifest SHA-256 of each architecture in the latest public signed Windows feed."""
    latest = latest_feed()
    if latest is None:
        return {}
    signature, body = latest
    with tempfile.TemporaryDirectory(prefix="pacer-windows-base-") as temporary:
        unsigned = Path(temporary) / "appcast-windows.body"
        unsigned.write_bytes(body)
        verify(tools, unsigned, signature)
    bases = {}
    for item in ET.fromstring(body).findall("./channel/item"):
        enclosure = item.find("enclosure")
        digest = enclosure.get(f"{{{PACER_NAMESPACE}}}manifestSHA256") if enclosure is not None else None
        if digest:
            bases[enclosure.get(f"{{{NAMESPACE}}}os", "").removeprefix("windows-")] = (item.findtext(f"{{{NAMESPACE}}}version"), digest)
    return bases


def patch(directory, version, build, commit, architecture, manifest_digest, bases):
    """CI's patch installer, kept only when its base is the latest published build."""
    stem = f"CodexPacer-{version}-windows-{architecture}-patch-{commit[:7]}"
    if not (directory / architecture / (stem + ".exe")).exists():
        print(f"No {architecture} patch: CI had no published manifest to build one from.")
        return None
    path, data, digest = checked(directory, architecture, stem + ".exe")
    info = json.loads((directory / architecture / (stem + ".json")).read_text(encoding="utf-8"))
    if file_version(data) != f"{version}.{build}" or (info["sha256"], info["manifestSHA256"], info["architecture"], info["build"]) \
            != (digest, manifest_digest, architecture, f"{version}.{build}"):
        raise ValueError(f"The {architecture} patch does not belong to this build.")
    if bases.get(architecture) != (info["baseBuild"], info["baseManifestSHA256"]):
        print(f"Dropping the {architecture} patch: its base {info['baseBuild']} is not the latest published Windows build.")
        return None
    return path, digest, info


def installer(directory, version, build, commit, architecture):
    name = f"CodexPacer-{version}-windows-{architecture}-setup-{commit[:7]}.exe"
    path = directory / architecture / name
    if not path.exists():
        found = ", ".join(sorted(item.name for item in (directory / architecture).glob("*.exe"))) or "none"
        raise ValueError(f"The {architecture} artifact has no clean installer for {commit[:7]} (found: {found}).")
    data = path.read_bytes()
    digest = hashlib.sha256(data).hexdigest()
    if (directory / architecture / (name + ".sha256")).read_text(encoding="utf-8") != f"{digest}  {name}\n":
        raise ValueError(f"The {architecture} installer does not match its CI checksum.")
    if file_version(data) != f"{version}.{build}":
        raise ValueError(f"The {architecture} installer was built for another version.")
    return path, digest


def prepare(tools, output, notes, artifacts=None):
    """artifacts: a directory holding each architecture's installer artifact in a subdirectory named after it."""
    version, build, public_key = application_version()
    commit = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=ROOT, text=True).strip()
    minimum = minimum_windows()
    output.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="pacer-windows-release-") as temporary:
        staging = Path(temporary)
        if artifacts is None:
            source, run = staging, download(commit, staging)
        else:
            source, run = artifacts, int(os.environ.get("GITHUB_RUN_ID", "0")) or None
        bases = published_bases(tools)
        assets, digests, entries = [], {}, []
        for architecture in ARCHITECTURES:
            installer_path, digest = installer(source, version, build, commit, architecture)
            name = asset_name(version, architecture)
            target = output / name
            shutil.copy2(installer_path, target)
            signature = sign(tools, target)
            digests[name] = digest
            manifest_source, manifest_digest = manifest(source, version, build, commit, architecture)
            shutil.copy2(manifest_source, output / manifest_name(version, architecture))
            entry = {"architecture": architecture, "name": name, "sha256": digest, "signature": signature,
                     "manifest": manifest_name(version, architecture), "manifestSHA256": manifest_digest, "patch": None}
            found = patch(source, version, build, commit, architecture, manifest_digest, bases)
            if found:
                patch_source, patch_digest, info = found
                patch_target = output / patch_name(version, architecture, info["baseVersion"])
                shutil.copy2(patch_source, patch_target)
                entry["patch"] = {"name": patch_target.name, "length": patch_target.stat().st_size, "signature": sign(tools, patch_target),
                                  "from": info["baseBuild"], "baseManifestSHA256": info["baseManifestSHA256"], "sha256": patch_digest}
            entries.append(entry)
            assets.append((architecture, name, target.stat().st_size, signature, manifest_digest, entry["patch"]))
        texts = [(language, notes[suffix].read_text(encoding="utf-8")) for language, suffix in LANGUAGES]
        body = build_feed(version, build, texts, assets, minimum)
        validate_feed(body, version, build, assets, minimum)
        unsigned = staging / "appcast-windows.body"
        unsigned.write_bytes(body)
        feed_signature = sign(tools, unsigned)
    (output / FEED).write_bytes(SIGNATURE_PREFIX + feed_signature.encode("ascii") + b" -->\n" + body)
    metadata = {"version": version, "buildNumber": build, "commit": commit, "workflowRun": run, "publicEDKey": public_key,
                "feed": FEED, "feedSHA256": hashlib.sha256((output / FEED).read_bytes()).hexdigest(), "installers": entries}
    (output / "windows-update.json").write_text(json.dumps(metadata, indent=2) + "\n")
    print(f"Verified Windows update feed: {output / FEED} (build {version}.{build}, run {run})")


def verify_release(tools, output, check_latest):
    version, build, public_key = application_version()
    metadata = json.loads((output / "windows-update.json").read_text())
    commit = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=ROOT, text=True).strip()
    signed = (output / FEED).read_bytes()
    if (metadata["version"], metadata["buildNumber"], metadata["commit"], metadata["publicEDKey"]) != (version, build, commit, public_key) \
            or metadata["feedSHA256"] != hashlib.sha256(signed).hexdigest():
        raise ValueError("Windows update metadata does not match this release.")
    assets = []
    for entry in metadata["installers"]:
        path = output / entry["name"]
        if entry["name"] != asset_name(version, entry["architecture"]) or hashlib.sha256(path.read_bytes()).hexdigest() != entry["sha256"]:
            raise ValueError("A Windows installer changed after signing.")
        verify(tools, path, entry["signature"])
        if entry["manifest"] != manifest_name(version, entry["architecture"]) or \
                hashlib.sha256((output / entry["manifest"]).read_bytes()).hexdigest() != entry["manifestSHA256"]:
            raise ValueError("A Windows manifest changed after signing.")
        patch_entry = entry["patch"]
        if patch_entry:
            patch_path = output / patch_entry["name"]
            if hashlib.sha256(patch_path.read_bytes()).hexdigest() != patch_entry["sha256"] or patch_path.stat().st_size != patch_entry["length"]:
                raise ValueError("A Windows patch changed after signing.")
            verify(tools, patch_path, patch_entry["signature"])
        assets.append((entry["architecture"], entry["name"], path.stat().st_size, entry["signature"], entry["manifestSHA256"], patch_entry))
    signature, body = split_feed(signed)
    validate_feed(body, version, build, assets, minimum_windows())
    with tempfile.TemporaryDirectory(prefix="pacer-windows-feed-") as temporary:
        unsigned = Path(temporary) / "appcast-windows.body"
        unsigned.write_bytes(body)
        verify(tools, unsigned, signature)
    if check_latest:
        check_continuity(f"{version}.{build}")
    print(f"Windows release signatures and build {version}.{build} verified.")


def latest_feed():
    """(signature, body) of the latest public release's Windows feed, or None when it has none."""
    latest = json.loads(subprocess.check_output(["gh", "api", f"repos/{REPOSITORY}/releases/latest"], text=True))
    if not any(asset["name"] == FEED for asset in latest["assets"]):
        return None
    with tempfile.TemporaryDirectory(prefix="pacer-windows-latest-") as temporary:
        subprocess.run(["gh", "release", "download", latest["tag_name"], "--repo", REPOSITORY, "--pattern", FEED, "--dir", temporary], check=True)
        return split_feed((Path(temporary) / FEED).read_bytes())


def asset_names(output):
    """Every Windows asset of a prepared release, for the shell scripts that checksum and upload them."""
    metadata = json.loads((output / "windows-update.json").read_text())
    names = []
    for entry in metadata["installers"]:
        names += [entry["name"], entry["manifest"]] + ([entry["patch"]["name"]] if entry["patch"] else [])
    return names + [metadata["feed"]]


def check_continuity(build=None):
    """Once a release carries the Windows feed, later releases must carry a newer one."""
    latest = latest_feed()
    if latest is None:
        return
    if build is None:
        raise ValueError("The latest release ships Windows; enable scripts/release/windows-release.json for every later release.")
    _, body = latest
    published = [tuple(map(int, item.findtext(f"{{{NAMESPACE}}}version", "").split("."))) for item in ET.fromstring(body).findall("./channel/item")]
    if not published or max(published) >= tuple(map(int, build.split("."))):
        raise ValueError("The Windows build must exceed every build in the latest public Windows feed.")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, help="Release output directory, e.g. output/releases/VERSION")
    parser.add_argument("--tools", type=Path, help="Sparkle tools directory with sign_update")
    parser.add_argument("--notes", type=Path, help="English Markdown release notes")
    parser.add_argument("--notes-zh", type=Path, help="Simplified Chinese Markdown release notes")
    parser.add_argument("--artifacts", type=Path, help="Installer artifacts already downloaded, one subdirectory per architecture")
    parser.add_argument("--verify", action="store_true")
    parser.add_argument("--check-latest", action="store_true")
    parser.add_argument("--check-latest-only", action="store_true")
    parser.add_argument("--enabled", action="store_true", help="Exit 0 when Windows joins this release, 1 otherwise")
    parser.add_argument("--assets", action="store_true", help="Print the prepared Windows asset names, one per line")
    args = parser.parse_args()
    if args.enabled:
        raise SystemExit(0 if enabled() else 1)
    if args.assets:
        if args.output is None:
            parser.error("--output is required")
        print("\n".join(asset_names(args.output.resolve())))
        return
    if not enabled():
        check_continuity()
        return
    if args.check_latest_only:
        version, build, _ = application_version()
        check_continuity(f"{version}.{build}")
        return
    if args.output is None or args.tools is None:
        parser.error("--output and --tools are required")
    if args.verify:
        verify_release(args.tools.resolve(), args.output.resolve(), args.check_latest)
    else:
        if args.notes is None or args.notes_zh is None:
            parser.error("--notes and --notes-zh are required to generate the bilingual Windows feed")
        prepare(args.tools.resolve(), args.output.resolve(), {"en": args.notes.resolve(), "zh-CN": args.notes_zh.resolve()},
                args.artifacts.resolve(strict=True) if args.artifacts else None)


if __name__ == "__main__":
    main()
