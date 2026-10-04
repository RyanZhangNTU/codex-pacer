#!/usr/bin/env python3
"""Embed Sparkle's binary framework and sign helpers before the enclosing app."""
from pathlib import Path
import subprocess
import sys


def main():
    artifacts, app, identity = Path(sys.argv[1]), Path(sys.argv[2]), sys.argv[3]
    candidates = list(artifacts.glob("sparkle/Sparkle/Sparkle.xcframework/macos-*/Sparkle.framework"))
    if len(candidates) != 1:
        raise SystemExit(f"Expected one macOS Sparkle framework; found {len(candidates)}.")
    framework = app / "Contents/Frameworks/Sparkle.framework"
    subprocess.run(["ditto", "--norsrc", "--noextattr", str(candidates[0]), str(framework)], check=True)
    # Preserve the framework symlinks and sign nested code from the inside out.
    version = framework / "Versions/B"
    helpers = [version / "XPCServices/Downloader.xpc", version / "XPCServices/Installer.xpc",
               version / "Autoupdate", version / "Updater.app", framework]
    for item in helpers:
        command = ["codesign", "--force", "--sign", identity]
        if identity != "-":
            command += ["--options", "runtime", "--timestamp"]
            if item.name == "Downloader.xpc":
                command += ["--preserve-metadata=entitlements"]
        subprocess.run(command + [str(item)], check=True)
    subprocess.run(["codesign", "--verify", "--deep", "--strict", str(framework)], check=True)


if __name__ == "__main__":
    main()
