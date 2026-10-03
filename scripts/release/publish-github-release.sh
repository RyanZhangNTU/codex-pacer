#!/bin/bash
set -euo pipefail
task_root="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$task_root"
task_version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' native/Info.plist)"
task_tag="v$task_version"
task_output="$task_root/output/releases/$task_version"
task_dmg="$task_output/Codex-Pacer-${task_version}-universal.dmg"
[[ -z "$(git status --porcelain)" ]] || { echo 'Release requires a clean checkout.' >&2; exit 1; }
[[ "$(git rev-parse HEAD)" == "$(git rev-parse "$task_tag^{commit}")" ]] || { echo 'Tag must match this checkout.' >&2; exit 1; }
[[ "$(git ls-remote origin "refs/tags/$task_tag" | cut -f1)" == "$(git rev-parse "$task_tag")" ]] || { echo 'Push the release tag first.' >&2; exit 1; }
python3 - "$task_output/build.json" "$(git rev-parse HEAD)" "$task_version" <<'PY'
import json,sys
m=json.load(open(sys.argv[1]))
assert m['commit']==sys.argv[2] and m['version']==sys.argv[3]
assert all(m[k] for k in ('signed','notarized','stapled'))
PY
(cd "$task_output" && shasum -a 256 -c SHA256SUMS.txt)
xcrun stapler validate "$task_dmg"
codesign --verify --strict "$task_dmg"
gh release create "$task_tag" "$task_dmg" "$task_output/SHA256SUMS.txt" --verify-tag --latest \
    --title "Codex Pacer $task_version" --notes-file docs/release-notes-2.0.zh-CN.md
