#!/bin/bash
set -euo pipefail
[[ $# -ge 3 && $# -le 4 ]] || { echo 'Usage: build-ui-replay.sh SOURCE_ROOT LABEL OUTPUT_DIRECTORY [SECONDS]' >&2; exit 2; }
task_root="$(cd "$(dirname "$0")/../.." && pwd)"
task_source="$(cd "$1" && pwd)"
task_label="$2"
task_output="$(mkdir -p "$3" && cd "$3" && pwd)"
task_seconds="${4:-60}"
[[ "$task_label" =~ ^[a-z0-9-]+$ ]] || { echo 'Label must use lowercase letters, digits and hyphens.' >&2; exit 2; }
task_build="$(mktemp -d /private/tmp/pacer-ui-replay.XXXXXX)"
task_app="$task_build/Pacer Performance $task_label.app"
mkdir -p "$task_build/native" "$task_app/Contents/MacOS" "$task_app/Contents/Resources"
rsync -a --exclude=.build --exclude=.swiftpm "$task_source/native/" "$task_build/native/"
export CLANG_MODULE_CACHE_PATH="$task_build/module-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$task_build/module-cache"
task_flags=(--package-path "$task_build/native" --scratch-path "$task_build/.build" --cache-path "$task_build/cache" --config-path "$task_build/config" --security-path "$task_build/security" -c release)
swift build "${task_flags[@]}" --target PacerCore
task_bin="$(swift build "${task_flags[@]}" --show-bin-path)"
python3 - "$task_build" "$task_app" "$task_label" "$task_output" "$task_seconds" <<'PY'
import json,pathlib,plistlib,sys
build,app,label,out,seconds=sys.argv[1:]
chart=pathlib.Path(build,'native/Sources/PacerIsland/QuotaCycleChart.swift')
s=chart.read_text();needle='    var body: some View {\n'
assert s.count(needle)==1
chart.write_text(s.replace(needle,needle+'        let _ = { ReplayMetrics.chartEvaluations += 1 }()\n',1))
info={'CFBundleIdentifier':'com.codexpacer.performance.'+label,'CFBundleName':'Pacer Performance '+label,'CFBundleExecutable':'UIReplay','CFBundlePackageType':'APPL','CFBundleShortVersionString':'1.0','CFBundleVersion':'1','LSMinimumSystemVersion':'14.0','LSUIElement':True,'NSHighResolutionCapable':True}
pathlib.Path(app,'Contents/Info.plist').write_bytes(plistlib.dumps(info))
pathlib.Path(app,'Contents/Resources/configuration.json').write_text(json.dumps({'label':label,'output':out,'seconds':float(seconds)}))
PY
clang -O2 -mmacosx-version-min=14.0 -c "$task_root/scripts/performance/ui-metrics.c" -o "$task_build/metrics.o"
task_sources=()
for task_file in "$task_build/native/Sources/PacerIsland/"*.swift; do
    [[ "$(basename "$task_file")" == PacerMain.swift ]] || task_sources+=("$task_file")
done
if [[ -f "$task_bin/PacerCore.o" ]]; then
    task_objects=("$task_bin/PacerCore.o")
else
    task_objects=("$task_bin/PacerCore.build/"*.o)
fi
swiftc -O -module-name PacerUIReplay -target "$(uname -m)-apple-macosx14.0" -I "$task_bin" -I "$task_bin/Modules" \
    -module-cache-path "$task_build/module-cache" "${task_sources[@]}" "$task_root/scripts/performance/ui-replay.swift" \
    "${task_objects[@]}" "$task_build/metrics.o" -lsqlite3 -o "$task_app/Contents/MacOS/UIReplay"
codesign --force --sign - "$task_app"
codesign --verify --strict "$task_app"
printf '%s\n' "$task_app" > "$task_output/$task_label.app-path.txt"
printf 'Replay app: %s\n' "$task_app"
