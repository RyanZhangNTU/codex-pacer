"""Select the platform jobs that build or test the changed inputs."""
import os
import subprocess
import sys

# Text no build reads. Markdown anywhere is documentation.
DOCUMENTATION = ("docs/", ".github/ISSUE_TEMPLATE/", "LICENSE")
# Built on both platforms; the Windows engine compiles these (see scripts/windows/stage-engine.py).
SHARED = ("native/Sources/PacerCore/", "native/Sources/CZstd/", "native/Sources/CGzip/",
          "native/Tests/PresentationTables/", "native/Info.plist",
          "Package.swift", "Package.resolved", ".github/workflows/", "scripts/ci/")
MAC = ("native/", "scripts/native/", "scripts/release/", "Makefile")
WINDOWS = ("windows/", "scripts/windows/", "global.json")
# What the Windows package, installers and patches are built from, beyond the app itself.
INSTALLER = ("windows/Installer/", "windows/InstallerHooks/", "windows/InstallerSupport/", "windows/Maintenance/",
             "windows/UpdateSupport/", "windows/ThirdParty/InnoSetup/", "windows/installer-toolchain-lock.json",
             "windows/toolchain-lock.json", "global.json", "scripts/windows/package-", "scripts/windows/test-installer.ps1",
             "scripts/windows/test-patch.ps1", "scripts/windows/test-preview.ps1", "scripts/windows/setup-installer.ps1",
             "scripts/windows/fetch-update-base.ps1", "scripts/windows/build-maintenance.ps1",
             "scripts/windows/prune-arm64-runtime.py", "scripts/windows/setup-swift.ps1", "scripts/windows/build-engine.ps1",
             "scripts/windows/build-desktop.ps1", ".github/workflows/", "scripts/ci/",
             # The app code the installer and package checks start: launch, single instance,
             # installation identity, notification and startup registration, and the packaged project.
             "windows/Desktop/App.xaml.cs", "windows/Desktop/WindowsInstanceActivation.cs",
             "windows/Desktop/WindowsInstallationIdentity.cs", "windows/Desktop/WindowsSystemNotifications.cs",
             "windows/Desktop/WindowsNotificationCleanup.cs", "windows/Desktop/WindowsStartupRegistration.cs",
             "windows/Desktop/Pacer.Windows.csproj", "windows/desktop-platform.props")

MAC_JOBS = {"mac", "mac_bundle"}
WINDOWS_JOBS = {"windows_engine", "windows_desktop", "windows_integration", "windows_arm64"}
PRODUCT_JOBS = MAC_JOBS | WINDOWS_JOBS
ALL_JOBS = PRODUCT_JOBS | {"installer"}

# The narrower test targets must precede the native/ and windows/ defaults.
ROUTES = (
    (("native/Tests/PacerCoreTests/",), {"mac", "windows_engine"}),
    (("native/Tests/PacerMacSupportTests/", "native/Tests/PacerIslandTests/", "native/Tests/PacerTestSupport/"), {"mac"}),
    (("windows/Tests/EngineTests/",), {"windows_engine"}),
    (("windows/Tests/PresentationTests/",), {"windows_desktop"}),
    (SHARED, PRODUCT_JOBS),
    (MAC, MAC_JOBS),
    (WINDOWS, WINDOWS_JOBS),
)


def classify(paths):
    jobs = set()
    for path in paths:
        if path.endswith(".md") or path.startswith(DOCUMENTATION):
            continue
        if path.startswith(INSTALLER):
            jobs.update(WINDOWS_JOBS | {"installer"})
        for prefixes, affected in ROUTES:
            if path.startswith(prefixes):
                jobs.update(affected)
                break
        else:
            jobs.update(ALL_JOBS)
    return jobs


def changed_paths():
    # The merge commit's first parent is the PR base. A move affects both paths.
    data = subprocess.check_output(["git", "diff", "--no-renames", "--name-only", "-z", "HEAD^1", "HEAD", "--"])
    return [os.fsdecode(path) for path in data.split(b"\0") if path]


def main():
    if os.environ.get("GITHUB_EVENT_NAME") == "pull_request":
        names = changed_paths()
        jobs = classify(names)
        print(f"{len(names)} changed files")
    else:
        jobs = ALL_JOBS
    lines = [f"{job}={str(job in jobs).lower()}" for job in sorted(ALL_JOBS)]
    print("\n".join(lines))
    output = os.environ.get("GITHUB_OUTPUT")
    if output:
        with open(output, "a", encoding="utf-8") as handle:
            handle.write("\n".join(lines) + "\n")


if __name__ == "__main__":
    sys.exit(main())
