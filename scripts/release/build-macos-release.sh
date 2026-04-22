#!/usr/bin/env bash

set -euo pipefail

usage() {
  cat <<'EOF'
Usage: ./scripts/release/build-macos-release.sh VERSION

Required environment variables:
  APPLE_SIGNING_IDENTITY

Notarization environment variables (choose exactly one path):
  APPLE_ID + APPLE_PASSWORD + APPLE_TEAM_ID
  or
  APPLE_API_ISSUER + APPLE_API_KEY + APPLE_API_KEY_PATH

Optional environment variables:
  TAURI_TARGET        e.g. aarch64-apple-darwin
  TAURI_BUILD_ARGS    extra Tauri build args appended before the Cargo `--` boundary
  CARGO_TARGET_DIR    defaults to ~/Library/Caches/CodexPacer/cargo-target
EOF
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

default_cargo_target_dir() {
  printf '%s\n' "${HOME}/Library/Caches/CodexPacer/cargo-target"
}

path_is_cloud_synced() {
  local path="$1"
  [[ "${path}" == *"/Mobile Documents/"* || "${path}" == *"/CloudStorage/"* ]]
}

require_command() {
  local command_name="$1"
  if ! command -v "${command_name}" >/dev/null 2>&1; then
    echo "ERROR: Missing required command: ${command_name}" >&2
    exit 1
  fi
}

json_value() {
  local file_path="$1"
  local expression="$2"
  node -e "const fs=require('fs'); const data=JSON.parse(fs.readFileSync(process.argv[1], 'utf8')); console.log(${expression});" "${file_path}"
}

require_clean_worktree() {
  if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    echo "ERROR: ${REPO_ROOT} is not inside a git work tree." >&2
    exit 1
  fi

  git update-index -q --refresh

  if [[ -n "$(git status --porcelain)" ]]; then
    echo "ERROR: Working tree is not clean. Commit, stash, or remove local changes before building a release." >&2
    git status --short
    exit 1
  fi
}

latest_recent_match() {
  local search_root="$1"
  local start_epoch="$2"
  local find_type="$3"
  local expected_name="$4"
  local expected_fragment="$5"
  local expected_suffix="$6"
  local latest_path=""
  local latest_mtime=0
  local candidate

  while IFS= read -r -d '' candidate; do
    local base_name mtime
    base_name="$(basename "${candidate}")"
    if [[ -n "${expected_name}" && "${base_name}" != "${expected_name}" ]]; then
      continue
    fi

    if [[ -n "${expected_fragment}" && "${candidate}" != *"${expected_fragment}"* ]]; then
      continue
    fi

    if [[ -n "${expected_suffix}" && "${base_name}" != *"${expected_suffix}" ]]; then
      continue
    fi

    mtime="$(stat -f '%m' "${candidate}")"
    if (( mtime < start_epoch )); then
      continue
    fi

    if (( mtime >= latest_mtime )); then
      latest_path="${candidate}"
      latest_mtime="${mtime}"
    fi
  done < <(find "${search_root}" -type "${find_type}" -print0)

  if [[ -z "${latest_path}" ]]; then
    return 1
  fi

  printf '%s\n' "${latest_path}"
}

main() {
  if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
    usage
    exit 0
  fi

  local version="${1:-}"
  if [[ -z "${version}" ]]; then
    usage >&2
    exit 1
  fi

  if [[ "$(uname -s)" != "Darwin" ]]; then
    echo "ERROR: macOS release builds must run on Darwin." >&2
    exit 1
  fi

  require_command npm
  require_command cargo
  require_command node
  require_command codesign
  require_command spctl
  require_command xcrun
  require_command shasum
  require_command git

  cd "${REPO_ROOT}"
  require_clean_worktree

  local build_target_root package_version tauri_version product_name
  build_target_root="${CARGO_TARGET_DIR:-$(default_cargo_target_dir)}"
  mkdir -p "${build_target_root}"
  build_target_root="$(cd "${build_target_root}" && pwd)"
  if path_is_cloud_synced "${build_target_root}"; then
    echo "ERROR: CARGO_TARGET_DIR points to a cloud-synced path: ${build_target_root}" >&2
    echo "Use a local path such as $(default_cargo_target_dir) to avoid FinderInfo metadata breaking macOS code signing." >&2
    exit 1
  fi
  export CARGO_TARGET_DIR="${build_target_root}"

  package_version="$(json_value "${REPO_ROOT}/package.json" "data.version")"
  tauri_version="$(json_value "${REPO_ROOT}/src-tauri/tauri.conf.json" "data.version")"
  product_name="$(json_value "${REPO_ROOT}/src-tauri/tauri.conf.json" "data.productName")"

  if [[ "${package_version}" != "${version}" ]]; then
    echo "ERROR: package.json version is ${package_version}, expected ${version}." >&2
    exit 1
  fi

  if [[ "${tauri_version}" != "${version}" ]]; then
    echo "ERROR: src-tauri/tauri.conf.json version is ${tauri_version}, expected ${version}." >&2
    exit 1
  fi

  if [[ -z "${APPLE_SIGNING_IDENTITY:-}" ]]; then
    echo "ERROR: APPLE_SIGNING_IDENTITY is required for a signed macOS release build." >&2
    exit 1
  fi

  if [[ "${APPLE_SIGNING_IDENTITY}" == "-" ]]; then
    echo "ERROR: APPLE_SIGNING_IDENTITY='-' is ad-hoc signing and is not suitable for the public release workflow." >&2
    exit 1
  fi

  local has_apple_id_path=0
  local has_api_path=0

  if [[ -n "${APPLE_ID:-}" && -n "${APPLE_PASSWORD:-}" && -n "${APPLE_TEAM_ID:-}" ]]; then
    has_apple_id_path=1
  fi

  if [[ -n "${APPLE_API_ISSUER:-}" && -n "${APPLE_API_KEY:-}" && -n "${APPLE_API_KEY_PATH:-}" ]]; then
    has_api_path=1
  fi

  if (( has_apple_id_path + has_api_path != 1 )); then
    echo "ERROR: Provide exactly one notarization credential path." >&2
    echo "  Apple ID: APPLE_ID + APPLE_PASSWORD + APPLE_TEAM_ID" >&2
    echo "  API key : APPLE_API_ISSUER + APPLE_API_KEY + APPLE_API_KEY_PATH" >&2
    exit 1
  fi

  if (( has_api_path == 1 )) && [[ ! -f "${APPLE_API_KEY_PATH}" ]]; then
    echo "ERROR: APPLE_API_KEY_PATH does not exist: ${APPLE_API_KEY_PATH}" >&2
    exit 1
  fi

  local notarization_mode="Apple ID"
  if (( has_api_path == 1 )); then
    notarization_mode="App Store Connect API"
  fi

  local -a tauri_build_args cargo_runner_args
  tauri_build_args=(--ci --bundles dmg)
  cargo_runner_args=(--locked)

  if [[ -n "${TAURI_TARGET:-}" ]]; then
    tauri_build_args+=(--target "${TAURI_TARGET}")
  fi

  if [[ -n "${TAURI_BUILD_ARGS:-}" ]]; then
    # shellcheck disable=SC2206
    local extra_args=( ${TAURI_BUILD_ARGS} )
    tauri_build_args+=("${extra_args[@]}")
  fi

  echo "Building Codex Pacer v${version}"
  echo "Signing identity : ${APPLE_SIGNING_IDENTITY}"
  echo "Notarization via : ${notarization_mode}"
  echo "Cargo target dir : ${build_target_root}"
  if [[ -n "${TAURI_TARGET:-}" ]]; then
  echo "Tauri target     : ${TAURI_TARGET}"
  fi

  echo
  echo "Installing dependencies from the committed package-lock.json..."
  npm ci

  echo
  echo "Running public branding audit..."
  "${REPO_ROOT}/scripts/release/audit-public-branding.sh"

  echo
  echo "Running lint..."
  npm run lint

  echo
  echo "Building frontend..."
  npm run build

  echo
  echo "Running Rust tests..."
  cargo test --manifest-path src-tauri/Cargo.toml --locked

  echo
  echo "Running Tauri release build..."
  local build_start
  build_start="$(date +%s)"
  npm run tauri build -- "${tauri_build_args[@]}" -- "${cargo_runner_args[@]}"

  local app_name dmg_fragment app_path dmg_path checksum_path
  app_name="${product_name}.app"
  dmg_fragment="_${version}_"

  app_path="$(latest_recent_match "${build_target_root}" "${build_start}" d "${app_name}" "" "")" || {
    echo "ERROR: Could not locate the built app bundle for ${app_name}." >&2
    exit 1
  }

  dmg_path="$(latest_recent_match "${build_target_root}" "${build_start}" f "" "${dmg_fragment}" ".dmg")" || {
    echo "ERROR: Could not locate the built DMG for version ${version}." >&2
    exit 1
  }

  checksum_path="${dmg_path}.sha256"

  echo
  echo "Verifying signed app..."
  codesign --verify --deep --strict --verbose=2 "${app_path}"
  spctl -a -vv --type exec "${app_path}"
  xcrun stapler validate "${app_path}"

  echo
  echo "Verifying signed DMG..."
  codesign --verify --verbose=2 "${dmg_path}"
  spctl -a -vv --type open "${dmg_path}"
  xcrun stapler validate "${dmg_path}"

  echo
  echo "Writing DMG checksum..."
  (
    cd "$(dirname "${dmg_path}")"
    shasum -a 256 "$(basename "${dmg_path}")" > "${checksum_path}"
  )

  echo
  echo "Build complete."
  echo "App bundle : ${app_path}"
  echo "DMG        : ${dmg_path}"
  echo "Checksum   : ${checksum_path}"
}

main "$@"
