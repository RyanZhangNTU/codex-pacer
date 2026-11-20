"""Select the platform jobs that build or test the changed inputs."""
import json
import os
from pathlib import Path
import subprocess
import sys

# Text no build reads. Markdown anywhere is documentation.
DOCUMENTATION = ("docs/", ".github/ISSUE_TEMPLATE/", "LICENSE")
# Built on both platforms; the Windows engine compiles these (see scripts/windows/stage-engine.py).
SHARED = ("native/Sources/PacerCore/", "native/Sources/CZstd/", "native/Sources/CGzip/",
          "native/Tests/PresentationTables/", "native/Info.plist",
          "Package.swift", "Package.resolved", ".github/", "scripts/ci/")
MAC = ("native/", "scripts/native/", "scripts/release/", "Makefile")
WINDOWS = ("windows/", "scripts/windows/", "global.json")
# What the Windows package, installers and patches are built from, beyond the app itself.
INSTALLER = ("windows/Installer/", "windows/InstallerHooks/", "windows/InstallerSupport/", "windows/Maintenance/",
             "windows/UpdateSupport/", "windows/ThirdParty/InnoSetup/", "windows/installer-toolchain-lock.json",
             "windows/toolchain-lock.json", "global.json", "scripts/windows/package-", "scripts/windows/test-installer.ps1",
             "scripts/windows/test-patch.ps1", "scripts/windows/test-preview.ps1", "scripts/windows/setup-installer.ps1",
             "scripts/release/prepare-windows-update.py", "scripts/release/windows-release.json",
             "scripts/release/sign-updates.sh", "scripts/release/publish-github-release.sh",
             "scripts/release/sparkle_key.py", "scripts/release/sparkle-public-key.swift",
             "scripts/windows/fetch-update-base.", "scripts/windows/build-adapters.ps1", "scripts/windows/build-maintenance.ps1",
             "scripts/windows/prune-arm64-runtime.py", "scripts/windows/setup-swift.ps1", "scripts/windows/build-engine.ps1",
             "scripts/windows/build-desktop.ps1", ".github/", "scripts/ci/",
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


SHARDS = json.loads(Path(__file__).with_name("presentation-shards.json").read_text(encoding="utf-8"))
PRESENTATION = "windows/Tests/PresentationTests/"
# Only these inputs have been checked for independence from presentation variants
# or engine scheduling. Other Windows inputs get the complete measurement/matrix.
PACKAGING_ONLY = ("windows/Installer/", "windows/Maintenance/", "scripts/windows/package-", "scripts/windows/fetch-update-base.")
DESKTOP_ONLY = {"windows/Desktop/" + name for name in (
    "SettingsPalette.cs", "SettingsStyles.xaml", "PacerTheme.xaml", "GuideContent.cs", "SettingsGuidePages.cs",
    "CompactLayoutEditorView.cs", "ActivityBadge.cs", "WindowsStartupRegistration.cs", "WindowsNotificationCleanup.cs")}
APPEARANCE_INDEPENDENT = {"windows/Desktop/WindowsStartupRegistration.cs", "windows/Desktop/WindowsNotificationCleanup.cs"}


def plan(paths=None):
    jobs = ALL_JOBS if paths is None else classify(paths)
    selected = set()
    full_connections = measure_idle = paths is None
    reasons = []
    leaves = {PRESENTATION + filename: name for name, shard in SHARDS.items() for filename in shard["files"]}
    if paths is not None:
        for path in paths:
            affected = classify([path])
            if "windows_desktop" not in affected:
                continue
            leaf = leaves.get(path)
            selected.update([leaf] if leaf else SHARDS)
            full_connections |= not (path.startswith(PACKAGING_ONLY) or path in APPEARANCE_INDEPENDENT)
            measure_idle |= not (path.startswith((PRESENTATION,) + PACKAGING_ONLY) or path in DESKTOP_ONLY)
            reasons.append(leaf or "all Windows shards")
    else:
        selected.update(SHARDS)
    matrix = [{"shard": name, "groups": ",".join(spec["groups"])} for name, spec in SHARDS.items() if name in selected]
    return dict(jobs=sorted(jobs), shards=matrix, measure_idle=measure_idle,
                full_connections=full_connections, reason=", ".join(sorted(set(reasons))) if paths is not None else "manual full suite")


def changed_paths():
    # The merge commit's first parent is the PR base. A move affects both paths.
    data = subprocess.check_output(["git", "diff", "--no-renames", "--name-only", "-z", "HEAD^1", "HEAD", "--"])
    return [os.fsdecode(path) for path in data.split(b"\0") if path]


def main():
    event_path = os.environ.get("GITHUB_EVENT_PATH")
    event = json.loads(Path(event_path).read_text(encoding="utf-8")) if event_path else {}
    pr = event.get("pull_request", {})
    is_pr = os.environ.get("GITHUB_EVENT_NAME") == "pull_request"
    names = changed_paths() if is_pr else None
    selected = plan([] if pr.get("draft") else names)
    commit = subprocess.check_output(["git", "rev-parse", "HEAD"], text=True).strip()
    tree = subprocess.check_output(["git", "rev-parse", "HEAD^{tree}"], text=True).strip()
    expected = os.environ.get("EXPECTED_SHA")
    if not is_pr and expected and expected.lower() != commit:
        sys.exit("The selected ref has moved away from the expected commit.")
    selected.update(commit=commit, tree=tree, head=pr.get("head", {}).get("sha", commit),
                    base=pr.get("base", {}).get("sha", ""), draft=bool(pr.get("draft")))
    values = {job: str(job in selected["jobs"]).lower() for job in sorted(ALL_JOBS)}
    values.update(windows_shards=json.dumps(selected["shards"], separators=(",", ":")),
                  full_connections=str(selected["full_connections"]).lower(), measure_idle=str(selected["measure_idle"]).lower(),
                  plan=json.dumps(selected, separators=(",", ":")))
    summary = os.environ.get("GITHUB_STEP_SUMMARY")
    if summary:
        with open(summary, "a", encoding="utf-8") as handle:
            print("### Validation plan", file=handle)
            print("Head `{head}` · base `{base}` · checkout `{commit}` · tree `{tree}`".format(**selected), file=handle)
            print("Platform jobs:", ", ".join(selected["jobs"]) or "Linux checks only", file=handle)
            for row in selected["shards"]:
                print(f"- {row['shard']}: {row['groups']}", file=handle)
            if selected["shards"]:
                print(f"Selection: {selected['reason']}. Full connection variants: {selected['full_connections']}. Idle measurement: {selected['measure_idle']}.", file=handle)
    lines = [f"{key}={value}" for key, value in values.items()]
    print("\n".join(lines))
    if output := os.environ.get("GITHUB_OUTPUT"):
        with open(output, "a", encoding="utf-8") as handle:
            handle.write("\n".join(lines) + "\n")


if __name__ == "__main__":
    main()
