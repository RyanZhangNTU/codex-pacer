#!/bin/bash
set -euo pipefail
task_root="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$task_root"
task_mode=signed
case "${1:-}" in
    '') ;;
    --unsigned) task_mode=unsigned ;;
    *) echo 'Usage: build-macos-release.sh [--unsigned]' >&2; exit 2 ;;
esac
[[ $# -le 1 ]] || { echo 'Too many arguments.' >&2; exit 2; }
if [[ "$task_mode" == signed ]]; then
    : "${APPLE_SIGNING_IDENTITY:?Set APPLE_SIGNING_IDENTITY to a Developer ID Application identity}"
    task_identity="$APPLE_SIGNING_IDENTITY"
else
    # Apple Silicon still needs a local code signature. This is not Developer ID.
    task_identity=-
fi
if [[ -n "$(git status --porcelain)" ]]; then echo 'Commit source changes before building a release.' >&2; exit 1; fi
task_version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' native/Info.plist)"
task_build="$(mktemp -d /private/tmp/codex-pacer-release.XXXXXX)"
task_app="$task_build/stage/Codex Pacer.app"
task_name="Codex-Pacer-${task_version}-universal.dmg"
task_output="$task_root/output/releases/$task_version"
if [[ "$task_mode" == unsigned ]]; then
    task_name="Codex-Pacer-${task_version}-universal-unsigned.dmg"
    task_output="$task_output/unsigned"
fi
task_dmg="$task_build/$task_name"
mkdir -p "$task_build/stage" "$task_output"
PACER_UNIVERSAL=1 bash scripts/native/build-island.sh "$task_app" "$task_identity"
lipo -verify_arch arm64 x86_64 "$task_app/Contents/MacOS/CodexPacerIsland"
if [[ "$task_mode" == signed ]]; then
    # Carry the notarization ticket with the app after it leaves the DMG.
    ditto -c -k --keepParent --norsrc --noextattr "$task_app" "$task_build/app.zip"
    python3 scripts/release/notarize.py "$task_build/app.zip"
    xcrun stapler staple "$task_app"
    xcrun stapler validate "$task_app"
else
    task_signature="$(codesign -dv --verbose=2 "$task_app" 2>&1)"
    [[ "$task_signature" == *'Signature=adhoc'* ]] || { echo 'Expected an ad hoc application signature.' >&2; exit 1; }
fi
codesign --verify --strict "$task_app"
ln -s /Applications "$task_build/stage/Applications"
cp -X docs/release-notes-2.0.zh-CN.md "$task_build/stage/安装与版本说明.md"
hdiutil create -volname "Codex Pacer $task_version" -srcfolder "$task_build/stage" -ov -format UDZO "$task_dmg"
if [[ "$task_mode" == signed ]]; then
    codesign --force --sign "$task_identity" --timestamp "$task_dmg"
    python3 scripts/release/notarize.py "$task_dmg"
    xcrun stapler staple "$task_dmg"
    xcrun stapler validate "$task_dmg"
    codesign --verify --strict "$task_dmg"
    spctl --assess --type execute --verbose=2 "$task_app"
    spctl --assess --type open --context context:primary-signature --verbose=2 "$task_dmg"
fi
hdiutil verify "$task_dmg"
# Verify what users will actually mount, including the app and drag-install link.
task_mount="$task_build/mount"
mkdir -p "$task_mount"
trap 'hdiutil detach "$task_mount" >/dev/null 2>&1 || true' EXIT
hdiutil attach -readonly -nobrowse -mountpoint "$task_mount" "$task_dmg" >/dev/null
codesign --verify --strict "$task_mount/Codex Pacer.app"
[[ "$(readlink "$task_mount/Applications")" == /Applications ]]
cmp "$task_app/Contents/MacOS/CodexPacerIsland" "$task_mount/Codex Pacer.app/Contents/MacOS/CodexPacerIsland"
hdiutil detach "$task_mount" >/dev/null
trap - EXIT
cp -X "$task_dmg" "$task_output/$task_name"
(cd "$task_output" && shasum -a 256 "$task_name" > SHA256SUMS.txt)
python3 - "$task_output" "$task_build" "$task_version" "$(git rev-parse HEAD)" "$task_mode" "$task_name" <<'PY'
import json, pathlib, sys
out, build, version, commit, mode, filename = sys.argv[1:]
trusted = mode == 'signed'
pathlib.Path(out, 'build.json').write_text(json.dumps({
    'version': version, 'commit': commit, 'architectures': ['arm64', 'x86_64'],
    'appPath': str(pathlib.Path(build, 'stage', 'Codex Pacer.app')),
    'distribution': mode, 'filename': filename,
    'signatureType': 'Developer ID' if trusted else 'ad-hoc',
    'developerIDSigned': trusted, 'signed': trusted, 'notarized': trusted, 'stapled': trusted
}, indent=2) + '\n')
PY
printf 'Verified %s release: %s\n' "$task_mode" "$task_output/$task_name"
