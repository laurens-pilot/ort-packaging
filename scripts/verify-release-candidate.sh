#!/usr/bin/env bash
set -euo pipefail

die() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

[ "$#" -eq 4 ] || die "usage: $0 <candidate-directory> <build-run-id> <build-run-attempt> <build-commit>"
candidate_dir="$1"
build_run_id="$2"
build_run_attempt="$3"
build_commit="$4"
[[ "$build_run_id" =~ ^[1-9][0-9]*$ ]] || die "invalid build run ID"
[[ "$build_run_attempt" =~ ^[1-9][0-9]*$ ]] || die "invalid build run attempt"
[[ "$build_commit" =~ ^[0-9a-f]{40}$ ]] || die "invalid build commit"
[ -n "${GITHUB_REPOSITORY:-}" ] || die "GITHUB_REPOSITORY is required"
[ -d "$candidate_dir" ] || die "missing candidate directory: $candidate_dir"

provenance="$candidate_dir/build-provenance.json"
checksums="$candidate_dir/SHA256SUMS"
[ -f "$provenance" ] || die "missing build provenance"
[ -f "$checksums" ] || die "missing SHA256SUMS"
[ "$(find "$candidate_dir" -maxdepth 1 -type f | wc -l | tr -d '[:space:]')" -eq 35 ] ||
  die "release candidate must contain exactly 35 files"

jq --exit-status \
  --arg repository "$GITHUB_REPOSITORY" \
  --arg build_commit "$build_commit" \
  --argjson build_run_id "$build_run_id" \
  --argjson build_run_attempt "$build_run_attempt" '
    .github_repository == $repository and
    .github_build_run_id == $build_run_id and
    .github_build_run_attempt == $build_run_attempt and
    .github_workflow_ref == ($repository + "/.github/workflows/build.yml@refs/heads/main") and
    .packaging_commit == $build_commit and
    .release_scope == "all" and
    .ort_telemetry == "disabled" and
    .package_channel == "stable" and
    (.release_notes | type) == "string" and
    (.release_notes | length) > 0 and
    (.upstream_ort_version | test("^(0|[1-9][0-9]*)\\.(0|[1-9][0-9]*)\\.(0|[1-9][0-9]*)$")) and
    .upstream_ort_ref == ("v" + .upstream_ort_version) and
    (.upstream_ort_commit | test("^[0-9a-f]{40}$")) and
    (.build_env_sha256 | test("^[0-9a-f]{64}$")) and
    (.package_revision | type) == "number" and
    .package_revision >= 1 and
    (.package_revision | floor) == .package_revision and
    .package_label == ("r" + (.package_revision | tostring)) and
    .release_tag == ("ort-" + .upstream_ort_version + "-" + .package_label)
  ' "$provenance" >/dev/null || die "invalid build provenance"

release_tag="$(jq -r .release_tag "$provenance")"
ort_ref="$(jq -r .upstream_ort_ref "$provenance")"
ort_version="$(jq -r .upstream_ort_version "$provenance")"
ort_commit="$(jq -r .upstream_ort_commit "$provenance")"
package_revision="$(jq -r .package_revision "$provenance")"
package_label="$(jq -r .package_label "$provenance")"
expected_build_env_sha256="$(jq -r .build_env_sha256 "$provenance")"
actual_build_env_sha256="$(git show "$build_commit:build.env" | sha256sum | awk '{ print $1 }')"
[ "$actual_build_env_sha256" = "$expected_build_env_sha256" ] ||
  die "build.env does not match the candidate provenance"

expected_assets=(
  "onnxruntime-coreml-ios-$ort_version-$package_label.zip"
  "onnxruntime-coreml-macos-arm64-$ort_version-$package_label.tar.gz"
  "onnxruntime-coreml-macos-x64-$ort_version-$package_label.tar.gz"
  "onnxruntime-webgpu-android-$ort_version-$package_label.aar"
  "onnxruntime-webgpu-android-arm64-v8a-$ort_version-$package_label.aar"
  "onnxruntime-webgpu-android-armeabi-v7a-$ort_version-$package_label.aar"
  "onnxruntime-webgpu-android-x86_64-$ort_version-$package_label.aar"
  "onnxruntime-webgpu-linux-arm64-$ort_version-$package_label.tar.gz"
  "onnxruntime-webgpu-linux-x64-$ort_version-$package_label.tar.gz"
  "onnxruntime-webgpu-windows-arm64-$ort_version-$package_label.zip"
  "onnxruntime-webgpu-windows-x64-$ort_version-$package_label.zip"
)

for asset_name in "${expected_assets[@]}"; do
  asset="$candidate_dir/$asset_name"
  checksum="$asset.sha256"
  manifest="$asset.manifest.env"
  [ -f "$asset" ] || die "missing release asset: $asset_name"
  [ -f "$checksum" ] || die "missing release checksum: $asset_name.sha256"
  [ -f "$manifest" ] || die "missing release manifest: $asset_name.manifest.env"

  expected="$(tr -d '[:space:]' <"$checksum")"
  [[ "$expected" =~ ^[0-9a-f]{64}$ ]] || die "invalid checksum: $asset_name.sha256"
  actual="$(sha256sum "$asset" | awk '{ print $1 }')"
  [ "$actual" = "$expected" ] || die "checksum mismatch: $asset_name"
  grep -Fqx "$expected  ./$asset_name" "$checksums" || die "SHA256SUMS is missing $asset_name"
  grep -Fqx "ORT_REF=$ort_ref" "$manifest" || die "ORT_REF mismatch: $asset_name"
  grep -Fqx "ORT_VERSION=$ort_version" "$manifest" || die "ORT_VERSION mismatch: $asset_name"
  grep -Fqx "ORT_COMMIT=$ort_commit" "$manifest" || die "ORT_COMMIT mismatch: $asset_name"
  grep -Fqx 'ORT_TELEMETRY=disabled' "$manifest" || die "telemetry mismatch: $asset_name"
  grep -Fqx "PACKAGING_COMMIT=$build_commit" "$manifest" || die "packaging commit mismatch: $asset_name"
  grep -Fqx 'PACKAGE_CHANNEL=stable' "$manifest" || die "package channel mismatch: $asset_name"
  grep -Fqx "PACKAGE_REVISION=$package_revision" "$manifest" || die "package revision mismatch: $asset_name"
  grep -Fqx "PACKAGE_LABEL=$package_label" "$manifest" || die "package label mismatch: $asset_name"
  grep -Fqx 'ORT_CORE_INCLUDED=1' "$manifest" || die "missing ORT core marker: $asset_name"
done

[ "$(wc -l <"$checksums" | tr -d '[:space:]')" -eq 11 ] || die "SHA256SUMS must contain 11 entries"
(cd "$candidate_dir" && sha256sum -c SHA256SUMS >/dev/null)

printf 'release_tag=%s\n' "$release_tag"
printf 'ort_ref=%s\n' "$ort_ref"
printf 'ort_version=%s\n' "$ort_version"
printf 'ort_commit=%s\n' "$ort_commit"
printf 'package_revision=%s\n' "$package_revision"
printf 'package_label=%s\n' "$package_label"
printf 'packaging_commit=%s\n' "$build_commit"
