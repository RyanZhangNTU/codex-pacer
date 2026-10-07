#!/bin/bash
set -euo pipefail
task_root="$(cd "$(dirname "$0")/../.." && pwd)"
task_build="$(mktemp -d /private/tmp/codex-pacer-island-test.XXXXXX)"
mkdir -p "$task_build/native"
source "$task_root/scripts/native/swiftpm-environment.sh"
rsync -a --exclude=.build --exclude=.swiftpm "$task_root/native/" "$task_build/native/"
if [[ -n "${TEST_FILTER:-}" ]]; then task_swift_flags+=(--filter "$TEST_FILTER"); fi
swift test "${task_swift_flags[@]}"
printf 'Test directory: %s\n' "$task_build"
