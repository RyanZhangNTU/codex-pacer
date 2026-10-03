#!/bin/bash
set -euo pipefail
task_root="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$task_root"
: "${APPLE_SIGNING_IDENTITY:?Set APPLE_SIGNING_IDENTITY to a Developer ID Application identity}"
if [[ -n "$(git status --porcelain)" ]]; then echo 'Commit source changes before building a release.' >&2; exit 1; fi
task_version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' native/Info.plist)"
task_build="$(mktemp -d /private/tmp/codex-pacer-release.XXXXXX)"
task_app="$task_build/stage/Codex Pacer.app"
task_name="Codex-Pacer-${task_version}-universal.dmg"
task_dmg="$task_build/$task_name"
task_output="$task_root/output/releases/$task_version"
mkdir -p "$task_build/stage" "$task_output"
PACER_UNIVERSAL=1 bash scripts/native/build-island.sh "$task_app" "$APPLE_SIGNING_IDENTITY"
# Notarize the app first so dragging it out of the DMG also carries its ticket.
ditto -c -k --keepParent --norsrc --noextattr "$task_app" "$task_build/app.zip"
python3 scripts/release/notarize.py "$task_build/app.zip"
xcrun stapler staple "$task_app"
xcrun stapler validate "$task_app"
codesign --verify --strict "$task_app"
ln -s /Applications "$task_build/stage/Applications"
hdiutil create -volname "Codex Pacer $task_version" -srcfolder "$task_build/stage" -ov -format UDZO "$task_dmg"
codesign --force --sign "$APPLE_SIGNING_IDENTITY" --timestamp "$task_dmg"
python3 scripts/release/notarize.py "$task_dmg"
xcrun stapler staple "$task_dmg"
xcrun stapler validate "$task_dmg"
codesign --verify --strict "$task_dmg"
spctl --assess --type execute --verbose=2 "$task_app"
spctl --assess --type open --context context:primary-signature --verbose=2 "$task_dmg"
hdiutil verify "$task_dmg"
cp -X "$task_dmg" "$task_output/$task_name"
(cd "$task_output" && shasum -a 256 "$task_name" > SHA256SUMS.txt)
python3 - "$task_output" "$task_build" "$task_version" "$(git rev-parse HEAD)" <<'PY'
import json, pathlib, sys
out, build, version, commit = sys.argv[1:]
pathlib.Path(out, 'build.json').write_text(json.dumps({
    'version': version, 'commit': commit, 'architectures': ['arm64', 'x86_64'],
    'appPath': str(pathlib.Path(build, 'stage', 'Codex Pacer.app')),
    'signed': True, 'notarized': True, 'stapled': True
}, indent=2) + '\n')
PY
printf 'Verified release: %s\n' "$task_output/$task_name"
