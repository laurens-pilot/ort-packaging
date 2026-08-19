#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

die() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

[ "$#" -eq 2 ] || die "usage: $0 <ort-version> <package-revision>"
ort_version="$1"
package_revision="$2"
[[ "$ort_version" =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]] ||
  die "ORT version must be MAJOR.MINOR.PATCH"
[[ "$package_revision" =~ ^[1-9][0-9]*$ ]] ||
  die "package revision must be a positive integer"
[ -n "${GITHUB_REPOSITORY:-}" ] || die "GITHUB_REPOSITORY is required"
[[ "$GITHUB_REPOSITORY" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] ||
  die "invalid GITHUB_REPOSITORY"
command -v gh >/dev/null || die "missing command: gh"
command -v git >/dev/null || die "missing command: git"
command -v jq >/dev/null || die "missing command: jq"

# shellcheck disable=SC1091
source "$REPO_ROOT/build.env"
[ "$ORT_TELEMETRY" = disabled ] || die "ORT_TELEMETRY must be disabled"

ort_ref="v$ort_version"
package_label="r$package_revision"
release_tag="ort-$ort_version-$package_label"

upstream_release="$(gh api "repos/microsoft/onnxruntime/releases/tags/$ort_ref")"
jq --exit-status --arg ref "$ort_ref" \
  '.tag_name == $ref and .draft == false and .prerelease == false' \
  <<<"$upstream_release" >/dev/null || die "upstream release is not a published stable release"

tag_refs="$(git ls-remote https://github.com/microsoft/onnxruntime.git \
  "refs/tags/$ort_ref" "refs/tags/$ort_ref^{}")"
direct_commit="$(awk -v ref="refs/tags/$ort_ref" '$2 == ref { print $1 }' <<<"$tag_refs")"
peeled_commit="$(awk -v ref="refs/tags/$ort_ref^{}" '$2 == ref { print $1 }' <<<"$tag_refs")"
ort_commit="${peeled_commit:-$direct_commit}"
[[ "$ort_commit" =~ ^[0-9a-f]{40}$ ]] || die "unable to resolve upstream tag $ort_ref"

release_error="$(mktemp)"
if gh api "repos/$GITHUB_REPOSITORY/releases/tags/$release_tag" --silent 2>"$release_error"; then
  die "release $release_tag already exists"
elif ! grep -Fq 'HTTP 404' "$release_error"; then
  cat "$release_error" >&2
  die "unable to determine whether release $release_tag exists"
fi
target_tag_refs="$(git ls-remote "https://github.com/$GITHUB_REPOSITORY.git" "refs/tags/$release_tag")"
[ -z "$target_tag_refs" ] || die "tag $release_tag already exists"

if [ "$package_revision" -gt 1 ]; then
  previous_tag="ort-$ort_version-r$((package_revision - 1))"
  gh api "repos/$GITHUB_REPOSITORY/releases/tags/$previous_tag" \
    --jq 'if .draft == false and .immutable == true then empty else error("previous release is not published and immutable") end'
fi

build_env_sha256="$(sha256sum "$REPO_ROOT/build.env" | awk '{ print $1 }')"
printf 'ort_ref=%s\n' "$ort_ref"
printf 'ort_version=%s\n' "$ort_version"
printf 'ort_commit=%s\n' "$ort_commit"
printf 'ort_telemetry=%s\n' "$ORT_TELEMETRY"
printf 'python_version=%s\n' "$PYTHON_VERSION"
printf 'node_version=%s\n' "$NODE_VERSION"
printf 'package_channel=stable\n'
printf 'package_revision=%s\n' "$package_revision"
printf 'package_label=%s\n' "$package_label"
printf 'release_tag=%s\n' "$release_tag"
printf 'build_env_sha256=%s\n' "$build_env_sha256"
