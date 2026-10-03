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
if [[ "$task_mode" == signed ]]; then
    xcrun stapler validate "$task_dmg"
    codesign --verify --strict "$task_dmg"
else
    if codesign -dv "$task_dmg" >/dev/null 2>&1; then
        echo 'Unsigned distribution must not contain a signed DMG.' >&2; exit 1
    fi
    hdiutil verify "$task_dmg"
fi
gh release create "$task_tag" "$task_dmg" "$task_output/SHA256SUMS.txt" --verify-tag --latest \
    --title "$task_title" --notes-file docs/release-notes-2.0.zh-CN.md
