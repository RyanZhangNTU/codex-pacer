"""Which platforms a pull request touches, so CI runs only their jobs.

Pushes to main and manual runs build a release, so they always cover both
platforms. A pull request runs a platform's jobs only when it changes files
that platform builds or tests; documentation alone runs nothing.
"""
import os
import subprocess
import sys

# Text no build reads. Markdown anywhere is documentation.
DOCUMENTATION = ("docs/", ".github/ISSUE_TEMPLATE/", "LICENSE")
# Built on both platforms; the Windows engine compiles these (see scripts/windows/stage-engine.py).
SHARED = ("native/Sources/PacerCore/", "native/Sources/CZstd/", "native/Sources/CGzip/",
          "native/Tests/PacerCoreTests/", "native/Tests/PresentationTables/", "native/Info.plist",
          "Package.swift", "Package.resolved", ".github/workflows/", "scripts/ci/")
MAC = ("native/", "scripts/native/", "scripts/release/", "Makefile")
WINDOWS = ("windows/", "scripts/windows/", "global.json")


def classify(paths):
    """Returns (mac, windows): whether each platform's jobs must run."""
    mac = windows = False
    for path in paths:
        if path.endswith(".md") or path.startswith(DOCUMENTATION):
            continue
        if path.startswith(SHARED):
            mac = windows = True
        elif path.startswith(MAC):
            mac = True
        elif path.startswith(WINDOWS):
            windows = True
        else:  # Anything unknown runs everything.
            mac = windows = True
    return mac, windows


def main():
    if os.environ.get("GITHUB_EVENT_NAME") == "pull_request":
        # The pull request checkout is its merge commit; its first parent is the base.
        names = subprocess.check_output(["git", "diff", "--name-only", "HEAD^1", "HEAD"], text=True).split()
        mac, windows = classify(names)
        print(f"{len(names)} changed files")
    else:
        mac = windows = True
    lines = [f"mac={str(mac).lower()}", f"windows={str(windows).lower()}"]
    print("\n".join(lines))
    output = os.environ.get("GITHUB_OUTPUT")
    if output:
        with open(output, "a", encoding="utf-8") as handle:
            handle.write("\n".join(lines) + "\n")


if __name__ == "__main__":
    sys.exit(main())
