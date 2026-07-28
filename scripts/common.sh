#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export REPO_ROOT="${REPO_ROOT:-$(cd "$SCRIPT_DIR/.." && pwd)}"

set -a
# shellcheck disable=SC1091
source "$REPO_ROOT/versions.env"
set +a

export ORT_SOURCE_DIR="${ORT_SOURCE_DIR:-$REPO_ROOT/onnxruntime}"
export BUILD_ROOT="${BUILD_ROOT:-$REPO_ROOT/build}"
export DIST_ROOT="${DIST_ROOT:-$REPO_ROOT/dist}"
export JOBS="${JOBS:-$(getconf _NPROCESSORS_ONLN 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo 2)}"

log() {
  printf '[%s] %s\n' "$(date +%H:%M:%S)" "$*" >&2
}

die() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "missing command: $1"
}

require_file() {
  [ -f "$1" ] || die "missing file: $1"
}

require_dir() {
  [ -d "$1" ] || die "missing directory: $1"
}

sha256_file() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  else
    shasum -a 256 "$1" | awk '{print $1}'
  fi
}

write_checksum() {
  local file="$1"
  printf '%s\n' "$(sha256_file "$file")" >"$file.sha256"
}

package_label() {
  case "$PACKAGE_CHANNEL" in
    pilot) printf 'pilot.%s' "$PACKAGE_REVISION" ;;
    stable) printf 'r%s' "$PACKAGE_REVISION" ;;
    *) die "unsupported PACKAGE_CHANNEL: $PACKAGE_CHANNEL" ;;
  esac
}

package_release_tag() {
  printf 'ort-%s-%s' "$ORT_VERSION" "$(package_label)"
}

packaging_commit() {
  git -C "$REPO_ROOT" rev-parse HEAD
}

ort_commit() {
  if [ -n "${ORT_COMMIT_OVERRIDE:-}" ]; then
    printf '%s\n' "$ORT_COMMIT_OVERRIDE"
    return
  fi
  git -C "$ORT_SOURCE_DIR" rev-parse HEAD
}

write_manifest() {
  local path="$1"
  local target="$2"
  local linkage="$3"
  local providers="$4"
  local ort_commit_value packaging_commit_value
  ort_commit_value="$(ort_commit)" || die "unable to resolve the ONNX Runtime commit"
  packaging_commit_value="$(packaging_commit)" || die "unable to resolve the packaging commit"
  [[ "$ort_commit_value" =~ ^[0-9a-f]{40}$ ]] || die "invalid ONNX Runtime commit: $ort_commit_value"
  [[ "$packaging_commit_value" =~ ^[0-9a-f]{40}$ ]] || die "invalid packaging commit: $packaging_commit_value"
  {
    printf 'ORT_REF=%s\n' "$ORT_REF"
    printf 'ORT_VERSION=%s\n' "$ORT_VERSION"
    printf 'ORT_COMMIT=%s\n' "$ort_commit_value"
    printf 'PACKAGING_COMMIT=%s\n' "$packaging_commit_value"
    printf 'PACKAGE_CHANNEL=%s\n' "$PACKAGE_CHANNEL"
    printf 'PACKAGE_REVISION=%s\n' "$PACKAGE_REVISION"
    printf 'PACKAGE_LABEL=%s\n' "$(package_label)"
    printf 'TARGET=%s\n' "$target"
    printf 'ORT_CORE_INCLUDED=1\n'
    printf 'WEBGPU_LINKAGE=%s\n' "$linkage"
    printf 'EXECUTION_PROVIDERS=%s\n' "$providers"
    printf 'BUILD_CONFIG=Release\n'
    if [ -n "${REPACKAGE_SOURCE_TAG:-}" ]; then
      [ -n "${REPACKAGE_SOURCE_ASSET:-}" ] || die "missing REPACKAGE_SOURCE_ASSET"
      [ -n "${REPACKAGE_SOURCE_SHA256:-}" ] || die "missing REPACKAGE_SOURCE_SHA256"
      printf 'REPACKAGE_SOURCE_TAG=%s\n' "$REPACKAGE_SOURCE_TAG"
      printf 'REPACKAGE_SOURCE_ASSET=%s\n' "$REPACKAGE_SOURCE_ASSET"
      printf 'REPACKAGE_SOURCE_SHA256=%s\n' "$REPACKAGE_SOURCE_SHA256"
    fi
  } >"$path"
}

prepare_ort_source() {
  require_dir "$ORT_SOURCE_DIR/.git"
  local actual_ref
  actual_ref="$(git -C "$ORT_SOURCE_DIR" describe --tags --exact-match 2>/dev/null || true)"
  [ "$actual_ref" = "$ORT_REF" ] || die "expected ORT source at $ORT_REF, found ${actual_ref:-untagged commit}"

  local patch
  for patch in "$REPO_ROOT"/patches/*.patch; do
    if git -C "$ORT_SOURCE_DIR" apply --reverse --check "$patch" >/dev/null 2>&1; then
      log "$(basename "$patch") already applied"
    else
      git -C "$ORT_SOURCE_DIR" apply --check "$patch"
      git -C "$ORT_SOURCE_DIR" apply "$patch"
    fi
  done
}
