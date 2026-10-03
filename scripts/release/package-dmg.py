#!/usr/bin/env python3
"""Package an existing app with a fixed drag-to-Applications Finder layout."""

import argparse
import os
import pathlib
import plistlib
import subprocess
import tempfile

import dmgbuild


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("app", type=pathlib.Path)
    parser.add_argument("output", type=pathlib.Path)
    args = parser.parse_args()
    app, output = args.app.resolve(), args.output.resolve()
    if output.exists():
        parser.error(f"Output already exists: {output}")
    with (app / "Contents/Info.plist").open("rb") as source:
        info = plistlib.load(source)
    if info.get("CFBundleIdentifier") != "com.codexpacer.app":
        parser.error("Expected the release Codex Pacer app bundle.")
    subprocess.run(["codesign", "--verify", "--strict", str(app)], check=True)
    output.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="pacer-dmg-", dir="/private/tmp") as scratch:
        # Keep all generated assets and the Swift module cache outside iCloud.
        subprocess.run([
            "swift", "-module-cache-path", f"{scratch}/module-cache",
            str(pathlib.Path(__file__).with_name("dmg-background.swift")), scratch,
        ], check=True, env={**os.environ, "CLANG_MODULE_CACHE_PATH": f"{scratch}/module-cache"})
        dmgbuild.build_dmg(str(output), f"Codex Pacer {info['CFBundleShortVersionString']}", settings={
            "format": "UDZO",
            "filesystem": "HFS+",
            "files": [(str(app), "Codex Pacer.app")],
            "symlinks": {"Applications": "/Applications"},
            "background": f"{scratch}/background.png",
            # Leave room for Finder bars enabled by the user's preferences.
            "window_rect": ((240, 240), (640, 460)),
            "show_toolbar": False,
            "show_sidebar": False,
            "show_status_bar": False,
            "show_tab_view": False,
            "show_pathbar": False,
            "default_view": "icon-view",
            "include_icon_view_settings": True,
            "include_list_view_settings": False,
            "arrange_by": None,
            "grid_spacing": 80,
            "icon_size": 100,
            "text_size": 14,
            "icon_locations": {"Codex Pacer.app": (160, 195), "Applications": (480, 195)},
        })
    subprocess.run(["hdiutil", "verify", str(output)], check=True)


if __name__ == "__main__":
    main()
