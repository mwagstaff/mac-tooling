#!/usr/bin/env bash

set -euo pipefail

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly DEFAULT_MANIFEST="$SCRIPT_DIR/repos.tsv"
readonly DEFAULT_JOBS=4

usage() {
  cat <<'EOF'
Usage: restore_github_repos.sh [options]

Clones or updates GitHub repositories from a manifest.

Options:
  --manifest PATH  Manifest file to read. Default: migration/repos.tsv
  --jobs N         Number of concurrent clones/fetches. Default: 4
  --update         Fetch existing repositories instead of skipping them
  --dry-run        Print planned actions without changing anything
  --help, -h       Show this help

Manifest format:
  clone-url<TAB>destination-path

Lines beginning with # and blank lines are ignored.
EOF
}

manifest="$DEFAULT_MANIFEST"
jobs="$DEFAULT_JOBS"
update_existing="false"
dry_run="false"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --manifest)
      manifest="${2:-}"
      shift 2
      ;;
    --jobs)
      jobs="${2:-}"
      shift 2
      ;;
    --update)
      update_existing="true"
      shift
      ;;
    --dry-run)
      dry_run="true"
      shift
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
done

if [[ ! "$jobs" =~ ^[1-9][0-9]*$ ]]; then
  echo "--jobs must be a positive integer." >&2
  exit 1
fi

if [[ ! -f "$manifest" ]]; then
  echo "Manifest not found: $manifest" >&2
  exit 1
fi

if ! command -v git >/dev/null 2>&1; then
  echo "git is required but was not found." >&2
  exit 1
fi

if [[ "$dry_run" != "true" ]]; then
  mkdir -p "$HOME/dev"
fi

if command -v gh >/dev/null 2>&1; then
  if ! gh auth status >/dev/null 2>&1; then
    echo "[WARN] GitHub CLI is installed but not authenticated. SSH clone may still work."
  fi
fi

status_dir="$(mktemp -d)"
cleanup() {
  rm -rf "$status_dir"
}
trap cleanup EXIT

expand_path() {
  local raw_path="$1"

  case "$raw_path" in
    "~")
      printf '%s\n' "$HOME"
      ;;
    "~/"*)
      printf '%s/%s\n' "$HOME" "${raw_path:2}"
      ;;
    *)
      printf '%s\n' "$raw_path"
      ;;
  esac
}

process_repo() {
  local index="$1"
  local repo_url="$2"
  local destination="$3"
  local status_file="$status_dir/$index.status"

  if [[ -e "$destination/.git" ]]; then
    if [[ "$update_existing" == "true" ]]; then
      if [[ "$dry_run" == "true" ]]; then
        echo "[DRY-RUN] Would update $destination"
        printf 'UPDATED\t%s\t%s\n' "$repo_url" "$destination" >"$status_file"
        return 0
      fi

      echo "[UPDATE] $destination"
      if git -C "$destination" fetch --all --prune; then
        printf 'UPDATED\t%s\t%s\n' "$repo_url" "$destination" >"$status_file"
        return 0
      fi

      printf 'FAILED\t%s\t%s\n' "$repo_url" "$destination" >"$status_file"
      return 1
    fi

    echo "[SKIP] $destination already exists"
    printf 'SKIPPED\t%s\t%s\n' "$repo_url" "$destination" >"$status_file"
    return 0
  fi

  if [[ -e "$destination" ]]; then
    echo "[FAIL] $destination exists but is not a Git repository" >&2
    printf 'FAILED\t%s\t%s\n' "$repo_url" "$destination" >"$status_file"
    return 1
  fi

  if [[ "$dry_run" == "true" ]]; then
    echo "[DRY-RUN] Would clone $repo_url -> $destination"
    printf 'CLONED\t%s\t%s\n' "$repo_url" "$destination" >"$status_file"
    return 0
  fi

  mkdir -p "$(dirname "$destination")"

  echo "[CLONE] $repo_url -> $destination"
  if git clone "$repo_url" "$destination"; then
    printf 'CLONED\t%s\t%s\n' "$repo_url" "$destination" >"$status_file"
    return 0
  fi

  printf 'FAILED\t%s\t%s\n' "$repo_url" "$destination" >"$status_file"
  return 1
}

declare -a pids=()
index=0

while IFS=$'\t' read -r repo_url destination extra; do
  if [[ -n "${extra:-}" ]]; then
    echo "[WARN] Ignoring extra manifest fields for destination: $destination"
  fi

  if [[ -z "${repo_url// }" || "${repo_url:0:1}" == "#" ]]; then
    continue
  fi

  if [[ -z "${destination// }" ]]; then
    echo "[WARN] Skipping malformed manifest line for repo: $repo_url"
    continue
  fi

  destination="$(expand_path "$destination")"

  while (( $(jobs -pr | wc -l | tr -d ' ') >= jobs )); do
    sleep 0.2
  done

  process_repo "$index" "$repo_url" "$destination" &
  pids+=("$!")
  ((index += 1))
done <"$manifest"

overall_rc=0
for pid in "${pids[@]}"; do
  if ! wait "$pid"; then
    overall_rc=1
  fi
done

cloned=0
updated=0
skipped=0
failed=0

echo
echo "Repo restore summary"
echo "--------------------"

while IFS=$'\t' read -r status repo_url destination; do
  case "$status" in
    CLONED)
      ((cloned += 1))
      ;;
    UPDATED)
      ((updated += 1))
      ;;
    SKIPPED)
      ((skipped += 1))
      ;;
    FAILED)
      ((failed += 1))
      echo "FAILED: $repo_url -> $destination"
      ;;
  esac
done < <(cat "$status_dir"/*.status 2>/dev/null || true)

echo "Cloned: $cloned"
echo "Updated: $updated"
echo "Skipped: $skipped"
echo "Failed: $failed"

exit "$overall_rc"
