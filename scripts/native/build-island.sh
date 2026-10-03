#!/bin/bash
set -euo pipefail
task_root="$(cd "$(dirname "$0")/../.." && pwd)"
task_build="$(mktemp -d /private/tmp/codex-pacer-build.XXXXXX)"
task_app="${1:-$task_build/Codex Pacer.app}"
task_identity="${2:--}"
mkdir -p "$task_build/native" "$task_app/Contents/MacOS" "$task_app/Contents/Resources"
export CLANG_MODULE_CACHE_PATH="$task_build/module-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$task_build/module-cache"
rsync -a --exclude=.build --exclude=.swiftpm "$task_root/native/" "$task_build/native/"
task_flags=(--package-path "$task_build/native" --scratch-path "$task_build/.build" --cache-path "$task_build/cache" --config-path "$task_build/config" --security-path "$task_build/security" -c release)
if [[ "${PACER_UNIVERSAL:-0}" == 1 ]]; then task_flags+=(--arch arm64 --arch x86_64); fi
swift build "${task_flags[@]}"
task_bin="$(swift build "${task_flags[@]}" --show-bin-path)"
cp -X "$task_bin/CodexPacerIsland" "$task_app/Contents/MacOS/CodexPacerIsland"
cp -X "$task_root/native/Resources/Pacer.icns" "$task_app/Contents/Resources/Pacer.icns"
cp -X "$task_root/native/Info.plist" "$task_app/Contents/Info.plist"
if [[ "$task_identity" == - ]]; then
    codesign --force --sign - "$task_app"
else
    codesign --force --sign "$task_identity" --options runtime --timestamp "$task_app"
fi
codesign --verify --strict "$task_app"
printf 'App: %s\nBuild directory: %s\n' "$task_app" "$task_build"
