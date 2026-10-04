#!/bin/bash
set -euo pipefail
task_root="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$task_root"
task_mode=signed
case "${1:-}" in
    '') ;;
    --unsigned) task_mode=unsigned ;;
    *) echo 'Usage: publish-github-release.sh [--unsigned]' >&2; exit 2 ;;
esac
[[ $# -le 1 ]] || { echo 'Too many arguments.' >&2; exit 2; }
task_version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' native/Info.plist)"
task_notes="$task_root/docs/release-notes-${task_version}.zh-CN.md"
task_notes_en="$task_root/docs/release-notes-${task_version}.en.md"
[[ -f "$task_notes" ]] || { echo "Missing release notes: $task_notes" >&2; exit 1; }
[[ -f "$task_notes_en" ]] || { echo "Missing release notes: $task_notes_en" >&2; exit 1; }
task_tag="v$task_version"
task_output="$task_root/output/releases/$task_version"
task_name="Codex-Pacer-${task_version}-universal.dmg"
task_title="Codex Pacer $task_version"
if [[ "$task_mode" == unsigned ]]; then
    task_output="$task_output/unsigned"
    task_name="Codex-Pacer-${task_version}-universal-unsigned.dmg"
    task_title="$task_title · 未签名版"
fi
task_dmg="$task_output/$task_name"
[[ -z "$(git status --porcelain)" ]] || { echo 'Release requires a clean checkout.' >&2; exit 1; }
[[ "$(git rev-parse HEAD)" == "$(git rev-parse "$task_tag^{commit}")" ]] || { echo 'Tag must match this checkout.' >&2; exit 1; }
[[ "$(git ls-remote origin "refs/tags/$task_tag" | cut -f1)" == "$(git rev-parse "$task_tag")" ]] || { echo 'Push the release tag first.' >&2; exit 1; }
python3 - "$task_output/build.json" "$(git rev-parse HEAD)" "$task_version" "$task_mode" "$task_name" <<'PY'
import json,sys
m=json.load(open(sys.argv[1]))
assert m['commit']==sys.argv[2] and m['version']==sys.argv[3]
assert m['distribution']==sys.argv[4] and m['filename']==sys.argv[5]
assert set(m['architectures'])=={'arm64','x86_64'}
trusted=sys.argv[4]=='signed'
assert all(m[k] is trusted for k in ('developerIDSigned','signed','notarized','stapled'))
assert m['signatureType']==('Developer ID' if trusted else 'ad-hoc')
PY
(cd "$task_output" && shasum -a 256 -c SHA256SUMS.txt)
task_sparkle_tools="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["sparkleTools"])' "$task_output/update.json")"
python3 scripts/release/prepare-update.py --verify --check-latest --info-plist native/Info.plist \
    --archive "$task_dmg" --tools "$task_sparkle_tools"
if [[ "$task_mode" == signed ]]; then
    xcrun stapler validate "$task_dmg"
    codesign --verify --strict "$task_dmg"
else
    if codesign -dv "$task_dmg" >/dev/null 2>&1; then
        echo 'Unsigned distribution must not contain a signed DMG.' >&2; exit 1
    fi
    hdiutil verify "$task_dmg"
fi
# Keep the current update feed live until both new assets are uploaded and checked.
task_verify="$(mktemp -d /private/tmp/codex-pacer-published.XXXXXX)"
python3 - "$task_notes_en" "$task_notes" "$task_verify/release-notes.md" "$task_version" <<'PY'
from pathlib import Path
import sys
english, chinese, combined = map(Path, sys.argv[1:4])
version = sys.argv[4]
combined.write_text('## English\n\n' + english.read_text() + '\n## 简体中文\n\n' + chinese.read_text()
    + '\n[First-launch help / 首次打开帮助 (Apple)](https://support.apple.com/102445)\n\n'
    + f'![Privacy & Security / 隐私与安全](https://raw.githubusercontent.com/RyanZhangNTU/codex-pacer/v{version}/docs/assets/macos-open-anyway.png)\n')
PY
gh release create "$task_tag" "$task_dmg" "$task_output/appcast.xml" --verify-tag --draft \
    --title "$task_title" --notes-file "$task_verify/release-notes.md"
gh release download "$task_tag" --pattern "$task_name" --pattern appcast.xml --dir "$task_verify"
cmp "$task_dmg" "$task_verify/$task_name"
cmp "$task_output/appcast.xml" "$task_verify/appcast.xml"
gh release edit "$task_tag" --draft=false --latest
