#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

PUBLIC_PATHS=(
  ".github"
  "README.md"
  "README.zh-CN.md"
  "CHANGELOG.md"
  "CODE_OF_CONDUCT.md"
  "CONTRIBUTING.md"
  "SECURITY.md"
  "LICENSE"
  "index.html"
  "public"
  "docs/en"
  "docs/zh-CN"
)

STALE_BRANDING_PATTERNS=(
  "Codex Counter"
  "v0.1.0-beta"
)

COMPATIBILITY_GUARDS=(
  "package.json|\"name\": \"codex-pacer\"|npm package name"
  "src-tauri/Cargo.toml|name = \"codex-pacer\"|Rust package name"
  "src-tauri/tauri.conf.json|\"identifier\": \"com.codex.counter\"|macOS bundle identifier"
)

scan_public_paths() {
  local pattern="$1"
  local found=1

  for relative_path in "${PUBLIC_PATHS[@]}"; do
    local absolute_path="${REPO_ROOT}/${relative_path}"
    if [[ ! -e "${absolute_path}" ]]; then
      continue
    fi

    if rg --fixed-strings --line-number --with-filename --color=never "${pattern}" "${absolute_path}"; then
      found=0
    fi
  done

  return "${found}"
}

main() {
  cd "${REPO_ROOT}"

  local failures=0

  echo "Auditing public-facing files for stale branding..."
  for pattern in "${STALE_BRANDING_PATTERNS[@]}"; do
    if scan_public_paths "${pattern}"; then
      echo "ERROR: Found stale public branding reference: ${pattern}"
      failures=1
    else
      echo "OK: No public references to ${pattern}"
    fi
  done

  echo
  echo "Checking compatibility-sensitive identifiers..."
  local guard
  for guard in "${COMPATIBILITY_GUARDS[@]}"; do
    IFS='|' read -r file pattern description <<< "${guard}"
    if rg --fixed-strings --line-number --with-filename --color=never "${pattern}" "${REPO_ROOT}/${file}" >/dev/null; then
      echo "OK: ${description} still present in ${file}"
    else
      echo "ERROR: Missing ${description} in ${file}"
      failures=1
    fi
  done

  if [[ "${failures}" -ne 0 ]]; then
    echo
    echo "Branding audit failed."
    exit 1
  fi

  echo
  echo "Branding audit passed."
}

main "$@"
