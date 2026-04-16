#!/usr/bin/env bash

set -euo pipefail

usage() {
  cat <<'EOF'
Usage: ./scripts/release/publish-github-release.sh VERSION

Requires:
  - gh authenticated against the target GitHub repository
  - docs/en/release-notes-vVERSION.md
  - a built DMG plus its .sha256 file from build-macos-release.sh
EOF
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

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
    echo "ERROR: Working tree is not clean. Commit, stash, or remove local changes before publishing a release." >&2
    git status --short
    exit 1
  fi
}

latest_matching_file() {
  local expected_fragment="$1"
  local required_suffix="$2"
  local latest_path=""
  local latest_mtime=0
  local candidate

  while IFS= read -r -d '' candidate; do
    local base_name mtime
    base_name="$(basename "${candidate}")"
    if [[ "${base_name}" != *"${expected_fragment}"* || "${base_name}" != *"${required_suffix}" ]]; then
      continue
    fi

    if [[ "${base_name}" == *.sha256 ]]; then
      continue
    fi

    mtime="$(stat -f '%m' "${candidate}")"
    if (( mtime >= latest_mtime )); then
      latest_path="${candidate}"
      latest_mtime="${mtime}"
    fi
  done < <(find "${REPO_ROOT}/src-tauri/target" -type f -print0)

  if [[ -z "${latest_path}" ]]; then
    return 1
  fi

  printf '%s\n' "${latest_path}"
}

remote_tag_commit() {
  local tag="$1"
  local remote_commit=""

  remote_commit="$(git ls-remote --exit-code origin "refs/tags/${tag}^{}" 2>/dev/null | awk 'NR==1 { print $1 }')"
  if [[ -z "${remote_commit}" ]]; then
    remote_commit="$(git ls-remote --exit-code origin "refs/tags/${tag}" 2>/dev/null | awk 'NR==1 { print $1 }')"
  fi

  if [[ -z "${remote_commit}" ]]; then
    return 1
  fi

  printf '%s\n' "${remote_commit}"
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

  require_command gh
  require_command git
  require_command node

  cd "${REPO_ROOT}"
  require_clean_worktree

  local package_version tauri_version
  package_version="$(json_value "${REPO_ROOT}/package.json" "data.version")"
  tauri_version="$(json_value "${REPO_ROOT}/src-tauri/tauri.conf.json" "data.version")"

  if [[ "${package_version}" != "${version}" ]]; then
    echo "ERROR: package.json version is ${package_version}, expected ${version}." >&2
    exit 1
  fi

  if [[ "${tauri_version}" != "${version}" ]]; then
    echo "ERROR: src-tauri/tauri.conf.json version is ${tauri_version}, expected ${version}." >&2
    exit 1
  fi

  local tag="v${version}"
  local release_notes="${REPO_ROOT}/docs/en/release-notes-v${version}.md"
  if [[ ! -f "${release_notes}" ]]; then
    echo "ERROR: Missing release notes file: ${release_notes}" >&2
    exit 1
  fi

  if ! git rev-parse --verify --quiet "refs/tags/${tag}" >/dev/null; then
    echo "ERROR: Missing local git tag ${tag}. Create and review the tag before publishing." >&2
    exit 1
  fi

  local tag_commit head_commit remote_commit
  tag_commit="$(git rev-list -n 1 "${tag}")"
  head_commit="$(git rev-parse HEAD)"
  if [[ "${tag_commit}" != "${head_commit}" ]]; then
    echo "ERROR: Local tag ${tag} resolves to ${tag_commit}, but HEAD is ${head_commit}. Check out the tagged commit before publishing." >&2
    exit 1
  fi

  if ! git remote get-url origin >/dev/null 2>&1; then
    echo "ERROR: Git remote 'origin' is not configured." >&2
    exit 1
  fi

  remote_commit="$(remote_tag_commit "${tag}")" || {
    echo "ERROR: Tag ${tag} is not present on origin. Push the tag before publishing." >&2
    exit 1
  }

  if [[ "${remote_commit}" != "${tag_commit}" ]]; then
    echo "ERROR: Tag ${tag} on origin resolves to ${remote_commit}, but the local tag resolves to ${tag_commit}." >&2
    exit 1
  fi

  gh auth status >/dev/null

  local dmg_path checksum_path
  dmg_path="$(latest_matching_file "_${version}_" ".dmg")" || {
    echo "ERROR: Could not locate a built DMG for version ${version}." >&2
    exit 1
  }

  checksum_path="${dmg_path}.sha256"
  if [[ ! -f "${checksum_path}" ]]; then
    echo "ERROR: Missing checksum file for ${dmg_path}. Run build-macos-release.sh first." >&2
    exit 1
  fi

  if gh release view "${tag}" >/dev/null 2>&1; then
    echo "ERROR: GitHub Release ${tag} already exists." >&2
    exit 1
  fi

  gh release create "${tag}" \
    "${dmg_path}" \
    "${checksum_path}" \
    --title "Codex Pacer ${tag}" \
    --notes-file "${release_notes}"
}

main "$@"
