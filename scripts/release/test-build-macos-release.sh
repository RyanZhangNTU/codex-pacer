#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
TEST_ROOT="$(mktemp -d)"
STUB_BIN="${TEST_ROOT}/bin"
LOG_DIR="${TEST_ROOT}/logs"
RELEASE_VERSION="$(node -p "require('${REPO_ROOT}/package.json').version")"

cleanup() {
  rm -rf "${TEST_ROOT}"
}
trap cleanup EXIT

mkdir -p "${STUB_BIN}" "${LOG_DIR}"

cat > "${STUB_BIN}/git" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
case "${1:-}" in
  rev-parse)
    if [[ "${2:-}" == "--is-inside-work-tree" ]]; then
      echo "true"
      exit 0
    fi
    ;;
  update-index)
    exit 0
    ;;
  status)
    exit 0
    ;;
esac
echo "unexpected git invocation: $*" >&2
exit 1
EOF

cat > "${STUB_BIN}/cargo" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${1:-}" == "test" ]]; then
  exit 0
fi
echo "unexpected cargo invocation: $*" >&2
exit 1
EOF

cat > "${STUB_BIN}/codesign" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
exit 0
EOF

cat > "${STUB_BIN}/spctl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "${TEST_SPCTL_LOG:?}"
exit 0
EOF

cat > "${STUB_BIN}/xcrun" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "${TEST_XCRUN_LOG:?}"
exit 0
EOF

cat > "${STUB_BIN}/hdiutil" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "${TEST_HDIUTIL_LOG:?}"
exit 0
EOF

cat > "${STUB_BIN}/shasum" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
file="${@: -1}"
echo "deadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeef  ${file}"
EOF

cat > "${STUB_BIN}/npm" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

log_file="${TEST_RELEASE_LOG:?}"
printf '%s\n' "$*" >> "${log_file}"

if [[ "${1:-}" == "ci" ]]; then
  exit 0
fi

if [[ "${1:-}" == "run" && "${2:-}" == "lint" ]]; then
  exit 0
fi

if [[ "${1:-}" == "run" && "${2:-}" == "build" ]]; then
  exit 0
fi

if [[ "${1:-}" == "run" && "${2:-}" == "tauri" && "${3:-}" == "build" ]]; then
  bundles=""
  prev=""
  for arg in "$@"; do
    if [[ "${prev}" == "--bundles" ]]; then
      bundles="${arg}"
      break
    fi
    prev="${arg}"
  done

  dmg_dir="${CARGO_TARGET_DIR}/release/bundle/dmg"
  macos_dir="${CARGO_TARGET_DIR}/release/bundle/macos"
  mkdir -p "${dmg_dir}" "${macos_dir}"
  touch "${dmg_dir}/Codex Pacer_${TEST_RELEASE_VERSION}_aarch64.dmg"

  case "${bundles}" in
    app,dmg|dmg,app)
      mkdir -p "${macos_dir}/Codex Pacer.app"
      ;;
    dmg)
      rm -rf "${macos_dir}/Codex Pacer.app"
      ;;
    *)
      echo "unexpected bundles argument: ${bundles}" >&2
      exit 1
      ;;
  esac

  exit 0
fi

echo "unexpected npm invocation: $*" >&2
exit 1
EOF

chmod +x \
  "${STUB_BIN}/git" \
  "${STUB_BIN}/cargo" \
  "${STUB_BIN}/codesign" \
  "${STUB_BIN}/spctl" \
  "${STUB_BIN}/xcrun" \
  "${STUB_BIN}/hdiutil" \
  "${STUB_BIN}/shasum" \
  "${STUB_BIN}/npm"

export PATH="${STUB_BIN}:${PATH}"
export TEST_RELEASE_LOG="${LOG_DIR}/npm.log"
export TEST_SPCTL_LOG="${LOG_DIR}/spctl.log"
export TEST_XCRUN_LOG="${LOG_DIR}/xcrun.log"
export TEST_HDIUTIL_LOG="${LOG_DIR}/hdiutil.log"
export TEST_RELEASE_VERSION="${RELEASE_VERSION}"
export APPLE_SIGNING_IDENTITY="Developer ID Application: Test Maintainer (TEAMID1234)"
export APPLE_ID="maintainer@example.com"
export APPLE_PASSWORD="app-specific-password"
export APPLE_TEAM_ID="TEAMID1234"
export CARGO_TARGET_DIR="${TEST_ROOT}/target"

"${REPO_ROOT}/scripts/release/build-macos-release.sh" "${RELEASE_VERSION}"

if ! grep -F -- "--bundles app,dmg" "${TEST_RELEASE_LOG}" >/dev/null; then
  echo "expected build script to request both app and dmg bundles" >&2
  exit 1
fi

if [[ ! -d "${CARGO_TARGET_DIR}/release/bundle/macos/Codex Pacer.app" ]]; then
  echo "expected app bundle to remain available after the mocked Tauri build" >&2
  exit 1
fi

if [[ ! -f "${CARGO_TARGET_DIR}/release/bundle/dmg/Codex Pacer_${RELEASE_VERSION}_aarch64.dmg.sha256" ]]; then
  echo "expected checksum to be written beside the mocked DMG" >&2
  exit 1
fi

if ! grep -F -- "notarytool submit ${CARGO_TARGET_DIR}/release/bundle/dmg/Codex Pacer_${RELEASE_VERSION}_aarch64.dmg --apple-id maintainer@example.com --password app-specific-password --team-id TEAMID1234 --wait" "${TEST_XCRUN_LOG}" >/dev/null; then
  echo "expected build script to notarize the built DMG with notarytool" >&2
  exit 1
fi

if ! grep -F -- "stapler staple ${CARGO_TARGET_DIR}/release/bundle/dmg/Codex Pacer_${RELEASE_VERSION}_aarch64.dmg" "${TEST_XCRUN_LOG}" >/dev/null; then
  echo "expected build script to staple the built DMG" >&2
  exit 1
fi

if ! grep -F -- "--type open --context context:primary-signature ${CARGO_TARGET_DIR}/release/bundle/dmg/Codex Pacer_${RELEASE_VERSION}_aarch64.dmg" "${TEST_SPCTL_LOG}" >/dev/null; then
  echo "expected build script to assess the DMG with the primary-signature context" >&2
  exit 1
fi

rm -rf "${CARGO_TARGET_DIR}"
: > "${TEST_RELEASE_LOG}"
: > "${TEST_SPCTL_LOG}"
: > "${TEST_XCRUN_LOG}"
: > "${TEST_HDIUTIL_LOG}"
unset APPLE_ID APPLE_PASSWORD APPLE_TEAM_ID

"${REPO_ROOT}/scripts/release/build-macos-release.sh" "${RELEASE_VERSION}"

if grep -F -- "notarytool submit" "${TEST_XCRUN_LOG}" >/dev/null; then
  echo "expected signed-only build to skip notarytool" >&2
  exit 1
fi

if grep -F -- "stapler" "${TEST_XCRUN_LOG}" >/dev/null; then
  echo "expected signed-only build to skip stapler" >&2
  exit 1
fi

if [[ -s "${TEST_SPCTL_LOG}" ]]; then
  echo "expected signed-only build to skip Gatekeeper assessment" >&2
  exit 1
fi

if ! grep -F -- "verify ${CARGO_TARGET_DIR}/release/bundle/dmg/Codex Pacer_${RELEASE_VERSION}_aarch64.dmg" "${TEST_HDIUTIL_LOG}" >/dev/null; then
  echo "expected signed-only build to verify the DMG image" >&2
  exit 1
fi

: > "${TEST_RELEASE_LOG}"
export APPLE_ID="maintainer@example.com"
export APPLE_PASSWORD="app-specific-password"
unset APPLE_TEAM_ID

set +e
partial_output="$("${REPO_ROOT}/scripts/release/build-macos-release.sh" "${RELEASE_VERSION}" 2>&1)"
partial_status=$?
set -e

if [[ "${partial_status}" -eq 0 ]]; then
  echo "expected incomplete notarization credentials to fail" >&2
  exit 1
fi

if [[ "${partial_output}" != *"Incomplete Apple ID notarization credentials"* ]]; then
  echo "expected incomplete Apple ID credential failure to be explicit" >&2
  exit 1
fi

if [[ -s "${TEST_RELEASE_LOG}" ]]; then
  echo "expected incomplete notarization credentials to stop before npm commands run" >&2
  exit 1
fi

echo "build-macos-release regression test passed"
