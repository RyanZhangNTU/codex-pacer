#!/bin/bash
# Create a disposable launchable demo copy; the production app stays unchanged.
set -euo pipefail
: "${1:?Pass the app path printed by make build}"
task_demo="$(mktemp -d /private/tmp/pacer-marketing-demo.XXXXXX)/Codex Pacer Demo.app"
ditto --norsrc --noextattr "$1" "$task_demo"
/usr/libexec/PlistBuddy -c 'Set :CFBundleIdentifier com.codexpacer.demo' "$task_demo/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Set :CFBundleExecutable DemoLauncher' "$task_demo/Contents/Info.plist"
cat > "$task_demo/Contents/MacOS/DemoLauncher" <<'WRAPPER'
#!/bin/sh
exec "$(dirname "$0")/CodexPacerIsland" --demo --demo-notch
WRAPPER
chmod +x "$task_demo/Contents/MacOS/DemoLauncher"
codesign --force --deep --sign - "$task_demo"
codesign --verify --strict "$task_demo"
printf '%s\n' "$task_demo"
