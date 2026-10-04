#!/usr/bin/env python3
"""Generate and verify a signed Sparkle feed for a single GitHub release."""
import argparse
import base64
import hashlib
import json
from pathlib import Path
import plistlib
import shutil
import subprocess
import tempfile
from urllib.parse import quote
from urllib.request import urlopen
import xml.etree.ElementTree as ET

REPOSITORY = "RyanZhangNTU/codex-pacer"
KEY_ACCOUNT = "com.codexpacer.app"
NAMESPACE = "http://www.andymatuschak.org/xml-namespaces/sparkle"
XML_LANGUAGE = "{http://www.w3.org/XML/1998/namespace}lang"
ET.register_namespace("sparkle", NAMESPACE)


def validate_appcast(feed, archive, version, build, download_url):
    root = ET.parse(feed).getroot()
    items = root.findall("./channel/item")
    if len(items) != 1:
        raise ValueError("A release feed must contain exactly its one verified update.")
    item = items[0]
    def value(name):
        return item.findtext(f"{{{NAMESPACE}}}{name}")
    if value("version") != build or value("shortVersionString") != version:
        raise ValueError("Update feed version does not match the built application.")
    enclosure = item.find("enclosure")
    if enclosure is None or enclosure.get("url") != download_url:
        raise ValueError("Update download URL does not match this GitHub release asset.")
    if int(enclosure.get("length", "-1")) != archive.stat().st_size:
        raise ValueError("Update archive length does not match the feed.")
    signature = enclosure.get(f"{{{NAMESPACE}}}edSignature", "")
    if len(base64.b64decode(signature, validate=True)) != 64:
        raise ValueError("A valid Ed25519 update signature is required.")
    if value("minimumSystemVersion") != "14.0":
        raise ValueError("Update feed must preserve Pacer's macOS 14 minimum.")
    if item.find(f"{{{NAMESPACE}}}releaseNotesLink") is not None:
        raise ValueError("Release notes must be embedded in the signed feed.")
    descriptions = item.findall("description")
    if len(descriptions) != 2 or {entry.get(XML_LANGUAGE) for entry in descriptions} != {"en", "zh"}:
        raise ValueError("Release notes must include English and Simplified Chinese.")
    if any(not (entry.text or "").strip() or entry.get(f"{{{NAMESPACE}}}format") != "markdown" for entry in descriptions):
        raise ValueError("Both release notes must contain Markdown text.")
    return signature


def validate_configuration(info, tools):
    expected_feed = f"https://github.com/{REPOSITORY}/releases/latest/download/appcast.xml"
    if info.get("CFBundleIdentifier") != KEY_ACCOUNT or info.get("SUFeedURL") != expected_feed:
        raise ValueError("Release application identity and update feed must match Codex Pacer.")
    version, build = info["CFBundleShortVersionString"], info["CFBundleVersion"]
    if not build.isdigit() or int(build) < 1:
        raise ValueError("Pacer requires a monotonically increasing integer build number.")
    public_key = info["SUPublicEDKey"]
    if len(base64.b64decode(public_key, validate=True)) != 32:
        raise ValueError("The application has no valid update verification key.")
    actual_key = subprocess.check_output([str(tools / "generate_keys"), "--account", KEY_ACCOUNT, "-p"], text=True).strip()
    if public_key != actual_key:
        raise ValueError("The app's public key does not match the release signing key.")
    required = ("SUVerifyUpdateBeforeExtraction", "SURequireSignedFeed")
    if not all(info.get(key) is True for key in required):
        raise ValueError("Application must require signed update archives and feeds.")
    return version, build, public_key


def prepare(info_path, archive, tools, notes, notes_zh):
    info = plistlib.loads(info_path.read_bytes())
    version, build, public_key = validate_configuration(info, tools)
    prefix = f"https://github.com/{REPOSITORY}/releases/download/v{quote(version, safe='')}/"
    download_url = prefix + quote(archive.name)
    with tempfile.TemporaryDirectory(prefix="pacer-appcast-") as directory:
        staging = Path(directory)
        staged_archive = staging / archive.name
        shutil.copy2(archive, staged_archive)
        shutil.copy2(notes, staged_archive.with_suffix(".md"))
        subprocess.run([str(tools / "generate_appcast"), "--account", KEY_ACCOUNT,
                        "--download-url-prefix", prefix, "--maximum-deltas", "0",
                        "--embed-release-notes", "--link", f"https://github.com/{REPOSITORY}/releases/tag/v{version}",
                        "-o", str(staging / "appcast.xml"), str(staging)], check=True)
        feed = staging / "appcast.xml"
        # Parsing intentionally drops the old signature comments. Re-sign after
        # embedding both languages; modifying a signed feed invalidates it.
        tree = ET.parse(feed)
        item = tree.getroot().find("./channel/item")
        for description in item.findall("description"):
            item.remove(description)
        for language, path in (("en", notes), ("zh", notes_zh)):
            description = ET.SubElement(item, "description", {XML_LANGUAGE: language, f"{{{NAMESPACE}}}format": "markdown"})
            description.text = path.read_text(encoding="utf-8")
        ET.indent(tree, space="    ")
        tree.write(feed, encoding="utf-8", xml_declaration=True)
        subprocess.run([str(tools / "sign_update"), "--account", KEY_ACCOUNT, str(feed)], check=True)
        signature = validate_appcast(feed, staged_archive, version, build, download_url)
        subprocess.run([str(tools / "sign_update"), "--account", KEY_ACCOUNT, "--verify", str(feed)], check=True)
        subprocess.run([str(tools / "sign_update"), "--account", KEY_ACCOUNT, "--verify", str(staged_archive), signature], check=True)
        shutil.copy2(feed, archive.parent / "appcast.xml")
    metadata = {"version": version, "buildNumber": build, "feed": "appcast.xml", "archive": archive.name,
                "publicEDKey": public_key, "archiveSignature": signature, "downloadURL": download_url,
                "feedSHA256": hashlib.sha256((archive.parent / "appcast.xml").read_bytes()).hexdigest(),
                "sparkleTools": str(tools)}
    (archive.parent / "update.json").write_text(json.dumps(metadata, indent=2) + "\n")
    print(f"Verified update feed: {archive.parent / 'appcast.xml'} (build {build})")


def verify_release(info_path, archive, tools, check_latest=False):
    info = plistlib.loads(info_path.read_bytes())
    version, build, public_key = validate_configuration(info, tools)
    metadata = json.loads((archive.parent / "update.json").read_text())
    expected_url = f"https://github.com/{REPOSITORY}/releases/download/v{quote(version, safe='')}/{quote(archive.name)}"
    feed = archive.parent / "appcast.xml"
    signature = validate_appcast(feed, archive, version, build, expected_url)
    expected = {"version": version, "buildNumber": build, "archive": archive.name,
                "publicEDKey": public_key, "archiveSignature": signature, "downloadURL": expected_url,
                "feedSHA256": hashlib.sha256(feed.read_bytes()).hexdigest()}
    if any(metadata.get(key) != value for key, value in expected.items()):
        raise ValueError("Update metadata does not match the verified release artifacts.")
    subprocess.run([str(tools / "sign_update"), "--account", KEY_ACCOUNT, "--verify", str(feed)], check=True)
    subprocess.run([str(tools / "sign_update"), "--account", KEY_ACCOUNT, "--verify", str(archive), signature], check=True)
    if check_latest:
        latest = json.loads(subprocess.check_output(["gh", "api", f"repos/{REPOSITORY}/releases/latest"], text=True))
        published = next((asset for asset in latest["assets"] if asset["name"] == "appcast.xml"), None)
        if published:
            expected_prefix = f"https://github.com/{REPOSITORY}/releases/download/"
            if not published["browser_download_url"].startswith(expected_prefix):
                raise ValueError("Latest update feed points outside this repository.")
            with urlopen(published["browser_download_url"], timeout=30) as response:
                xml = response.read(2 * 1024 * 1024 + 1)
            if len(xml) > 2 * 1024 * 1024:
                raise ValueError("Latest update feed is unexpectedly large.")
            versions = [item.findtext(f"{{{NAMESPACE}}}version") for item in ET.fromstring(xml).findall("./channel/item")]
            if not versions or any(not value or not value.isdigit() for value in versions):
                raise ValueError("Cannot establish the latest published build number.")
            if max(map(int, versions)) >= int(build):
                raise ValueError("CFBundleVersion must exceed every build in the latest public feed.")
    print(f"Release update signatures and build {build} verified.")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--info-plist", type=Path, required=True)
    parser.add_argument("--archive", type=Path, required=True)
    parser.add_argument("--tools", type=Path, required=True)
    parser.add_argument("--notes", type=Path, help="English Markdown release notes")
    parser.add_argument("--notes-zh", type=Path, help="Simplified Chinese Markdown release notes")
    parser.add_argument("--verify", action="store_true")
    parser.add_argument("--check-latest", action="store_true")
    args = parser.parse_args()
    if args.verify:
        verify_release(args.info_plist.resolve(), args.archive.resolve(), args.tools.resolve(), args.check_latest)
    else:
        if args.notes is None or args.notes_zh is None:
            parser.error("--notes and --notes-zh are required to generate a bilingual feed")
        prepare(args.info_plist.resolve(), args.archive.resolve(), args.tools.resolve(), args.notes.resolve(), args.notes_zh.resolve())


if __name__ == "__main__":
    main()
