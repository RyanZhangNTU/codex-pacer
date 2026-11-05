#!/bin/bash
# Signs a built release's update feeds and writes its checksums: the Mac appcast for
# its DMG and, with Windows enabled, the Windows installers, any patches and their feed.
# WINDOWS_ARTIFACTS holds the installer artifacts the Release workflow already
# downloaded; without it they come from that workflow's newest run on this commit.
set -euo pipefail
task_root="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$task_root"
[[ $# -ge 2 && $# -le 3 ]] || { echo 'Usage: sign-updates.sh OUTPUT SPARKLE_TOOLS [WINDOWS_ARTIFACTS]' >&2; exit 2; }
task_output="$(cd "$1" && pwd)"
task_tools="$(cd "$2" && pwd)"
task_artifacts=()
[[ $# -lt 3 ]] || task_artifacts=(--artifacts "$3")
[[ -x "$task_tools/generate_appcast" ]] || { echo 'Sparkle signing tools are missing.' >&2; exit 1; }
task_version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' native/Info.plist)"
task_notes="$task_root/docs/release-notes-${task_version}.en.md"
task_notes_zh="$task_root/docs/release-notes-${task_version}.zh-CN.md"
task_name="$(python3 -c 'import json, sys; print(json.load(open(sys.argv[1]))["filename"])' "$task_output/build.json")"
python3 scripts/release/prepare-update.py --info-plist native/Info.plist --archive "$task_output/$task_name" \
    --tools "$task_tools" --notes "$task_notes" --notes-zh "$task_notes_zh"
# The Windows installers come from the Release workflow on this commit and share the Mac update key.
task_windows=()
if python3 scripts/release/prepare-windows-update.py --enabled; then
    python3 scripts/release/prepare-windows-update.py --output "$task_output" --tools "$task_tools" \
        --notes "$task_notes" --notes-zh "$task_notes_zh" ${task_artifacts[@]+"${task_artifacts[@]}"}
    # Installers, manifests, any patches and the feed, as prepared and signed above.
    while IFS= read -r task_asset; do task_windows+=("$task_asset"); done \
        < <(python3 scripts/release/prepare-windows-update.py --assets --output "$task_output")
fi
(cd "$task_output" && shasum -a 256 "$task_name" appcast.xml ${task_windows[@]+"${task_windows[@]}"} > SHA256SUMS.txt)
