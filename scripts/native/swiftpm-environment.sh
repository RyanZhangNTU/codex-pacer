# Sourced after task_root/task_build are set. Sources and build outputs stay
# isolated per invocation; pinned dependencies and compiler modules are reusable.
task_cache="/private/tmp/codex-pacer-swiftpm-$(id -u)"
(umask 077; mkdir -p "$task_cache")
export CLANG_MODULE_CACHE_PATH="$task_cache/module-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$task_cache/module-cache"
task_swift_flags=(--package-path "$task_build/native" --scratch-path "$task_build/.build"
    --cache-path "$task_cache/dependencies" --config-path "$task_build/config"
    --security-path "$task_build/security" --force-resolved-versions)
