"""Which platforms a pull request touches, so CI runs only their jobs.

A pull request runs a platform's jobs only when it changes files that
platform builds or tests; documentation alone runs nothing. Its Windows
installer and patch checks run only when it changes what the installers are
built from or what those checks start in the app. A manual run tests every
platform, so every flag is set for it.
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
# What the Windows package, installers and patches are built from, beyond the app itself.
INSTALLER = ("windows/Installer/", "windows/InstallerHooks/", "windows/InstallerSupport/", "windows/Maintenance/",
             "windows/UpdateSupport/", "windows/ThirdParty/InnoSetup/", "windows/installer-toolchain-lock.json",
             "windows/toolchain-lock.json", "global.json", "native/Info.plist", "scripts/windows/package-", "scripts/windows/test-installer.ps1",
             "scripts/windows/test-patch.ps1", "scripts/windows/test-preview.ps1", "scripts/windows/test-update-base.ps1",
             "scripts/windows/setup-installer.ps1",
             "scripts/windows/fetch-update-base.ps1", "scripts/windows/build-maintenance.ps1",
             "scripts/windows/environment.ps1", "scripts/windows/architecture.ps1", "scripts/windows/version.ps1",
             "scripts/windows/stage-engine.py", "scripts/windows/check-architecture.py", "scripts/windows/test-instance-activation.ps1",
             "scripts/windows/self-contained-test-environment.ps1",
             "scripts/windows/build-localization.py", "scripts/windows/build-shell-resources.py",
             "scripts/windows/prune-arm64-runtime.py", "scripts/windows/setup-swift.ps1", "scripts/windows/build-engine.ps1",
             "scripts/windows/build-desktop.ps1", ".github/workflows/", "scripts/ci/",
             # The app code the installer and package checks start: launch, single instance,
             # installation identity, notification and startup registration, and the packaged project.
             "windows/Desktop/App.xaml.cs", "windows/Desktop/WindowsInstanceActivation.cs",
             "windows/Desktop/WindowsInstallationIdentity.cs", "windows/Desktop/WindowsSystemNotifications.cs",
             "windows/Desktop/WindowsNotificationCleanup.cs", "windows/Desktop/WindowsStartupRegistration.cs",
             "windows/Desktop/Pacer.Windows.csproj", "windows/desktop-platform.props")


def classify(paths):
    """Returns (mac, windows, installer): whether each set of jobs must run."""
    mac = windows = installer = False
    for path in paths:
        if path.endswith(".md") or path.startswith(DOCUMENTATION):
            continue
        if path.startswith(INSTALLER):
            windows = installer = True
        if path.startswith(SHARED):
            mac = windows = True
        elif path.startswith(MAC):
            mac = True
        elif path.startswith(WINDOWS):
            windows = True
        else:  # Anything unknown runs everything.
            mac = windows = installer = True
    return mac, windows, installer


def main():
    if os.environ.get("GITHUB_EVENT_NAME") == "pull_request":
        # The pull request checkout is its merge commit; its first parent is the base.
        # Keep both sides of a rename and preserve whitespace in filenames.
        names = [os.fsdecode(path) for path in subprocess.check_output(
            ["git", "diff", "--no-renames", "--name-only", "-z", "HEAD^1", "HEAD"]).split(b"\0") if path]
        mac, windows, installer = classify(names)
        print(f"{len(names)} changed files")
    else:
        mac = windows = installer = True
    lines = [f"mac={str(mac).lower()}", f"windows={str(windows).lower()}", f"installer={str(installer).lower()}"]
    print("\n".join(lines))
    output = os.environ.get("GITHUB_OUTPUT")
    if output:
        with open(output, "a", encoding="utf-8") as handle:
            handle.write("\n".join(lines) + "\n")


if __name__ == "__main__":
    sys.exit(main())
