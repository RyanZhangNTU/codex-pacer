#!/bin/bash
set -euo pipefail
task_root="$(cd "$(dirname "$0")/../.." && pwd)"
task_build="$(mktemp -d /private/tmp/codex-pacer-island-test.XXXXXX)"
mkdir -p "$task_build/native"
export CLANG_MODULE_CACHE_PATH="$task_build/module-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$task_build/module-cache"
rsync -a --exclude=.build --exclude=.swiftpm "$task_root/native/" "$task_build/native/"
swift test --package-path "$task_build/native" --scratch-path "$task_build/.build" --cache-path "$task_build/cache" --config-path "$task_build/config" --security-path "$task_build/security"
printf 'Test directory: %s\n' "$task_build"
