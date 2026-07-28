#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "$SCRIPT_DIR/common.sh"

if [ "$#" -lt 2 ] || [ "$#" -gt 3 ]; then
  die "usage: $0 <source-release-directory> <source-release-tag> [all|non-linux]"
fi

source_dir="$1"
source_tag="$2"
repackage_scope="${3:-all}"
destination_label="$(package_label)"
destination_tag="$(package_release_tag)"
source_prefix="ort-$ORT_VERSION-"

case "$repackage_scope" in
  all) expected_binary_count=11 ;;
  non-linux) expected_binary_count=9 ;;
  *) die "unsupported repackage scope: $repackage_scope" ;;
esac

require_cmd cmp
require_cmd python3
require_cmd tar
require_cmd unzip
require_cmd zip
require_dir "$source_dir"
require_file "$source_dir/SHA256SUMS"
require_file "$source_dir/build-provenance.json"

case "$source_tag" in
  "$source_prefix"*) source_label="${source_tag#"$source_prefix"}" ;;
  *) die "source tag $source_tag does not contain ORT version $ORT_VERSION" ;;
esac
[ "$source_tag" != "$destination_tag" ] || die "source and destination release tags must differ"
[ -n "$source_label" ] || die "source package label is empty"

python3 - "$source_dir/build-provenance.json" "$source_tag" "$ORT_REF" "$ORT_VERSION" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as provenance_file:
    provenance = json.load(provenance_file)

expected = {
    "release_tag": sys.argv[2],
    "upstream_ort_ref": sys.argv[3],
    "upstream_ort_version": sys.argv[4],
}
for key, value in expected.items():
    if provenance.get(key) != value:
        raise SystemExit(
            f"source provenance has {key}={provenance.get(key)!r}; expected {value!r}"
        )
if not provenance.get("packaging_commit"):
    raise SystemExit("source provenance is missing packaging_commit")
PY

source_packaging_commit="$(python3 - "$source_dir/build-provenance.json" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as provenance_file:
    print(json.load(provenance_file)["packaging_commit"])
PY
)"

dist_dir="$DIST_ROOT/repackaged"
work_dir="$BUILD_ROOT/repackage"
case "$dist_dir" in "$DIST_ROOT"/*) ;; *) die "unsafe repackaged dist path: $dist_dir" ;; esac
case "$work_dir" in "$BUILD_ROOT"/*) ;; *) die "unsafe repackaging work path: $work_dir" ;; esac
rm -rf "$dist_dir" "$work_dir"
mkdir -p "$dist_dir" "$work_dir"

source_names=(
  "onnxruntime-coreml-ios-$ORT_VERSION-$source_label.zip"
  "onnxruntime-coreml-macos-arm64-$ORT_VERSION-$source_label.tar.gz"
  "onnxruntime-coreml-macos-x64-$ORT_VERSION-$source_label.tar.gz"
  "onnxruntime-webgpu-android-$ORT_VERSION-$source_label.aar"
  "onnxruntime-webgpu-android-arm64-v8a-$ORT_VERSION-$source_label.aar"
  "onnxruntime-webgpu-android-armeabi-v7a-$ORT_VERSION-$source_label.aar"
  "onnxruntime-webgpu-android-x86_64-$ORT_VERSION-$source_label.aar"
  "onnxruntime-webgpu-linux-arm64-$ORT_VERSION-$source_label.tar.gz"
  "onnxruntime-webgpu-linux-x64-$ORT_VERSION-$source_label.tar.gz"
  "onnxruntime-webgpu-windows-arm64-$ORT_VERSION-$source_label.zip"
  "onnxruntime-webgpu-windows-x64-$ORT_VERSION-$source_label.zip"
)

if [ "$repackage_scope" = "non-linux" ]; then
  non_linux_source_names=()
  for source_name in "${source_names[@]}"; do
    case "$source_name" in
      onnxruntime-webgpu-linux-*) ;;
      *) non_linux_source_names+=("$source_name") ;;
    esac
  done
  source_names=("${non_linux_source_names[@]}")
fi

verify_source_asset() {
  local source_asset="$1"
  local source_manifest="$source_asset.manifest.env"
  local source_checksum="$source_asset.sha256"
  require_file "$source_asset"
  require_file "$source_manifest"
  require_file "$source_checksum"

  local expected actual
  expected="$(tr -d '[:space:]' <"$source_checksum")"
  [[ "$expected" =~ ^[0-9a-f]{64}$ ]] || die "invalid source checksum: $source_checksum"
  actual="$(sha256_file "$source_asset")"
  [ "$actual" = "$expected" ] || die "source checksum mismatch: $source_asset"
  grep -Fqx "$expected  ./$(basename "$source_asset")" "$source_dir/SHA256SUMS" ||
    die "source SHA256SUMS does not contain $(basename "$source_asset")"
  grep -Fqx "ORT_REF=$ORT_REF" "$source_manifest"
  grep -Fqx "ORT_VERSION=$ORT_VERSION" "$source_manifest"
  grep -Fqx "PACKAGING_COMMIT=$source_packaging_commit" "$source_manifest"
  grep -Fqx "PACKAGE_LABEL=$source_label" "$source_manifest"
  grep -Fqx 'ORT_CORE_INCLUDED=1' "$source_manifest"
}

manifest_value() {
  local manifest="$1"
  local key="$2"
  awk -F= -v key="$key" '$1 == key { sub(/^[^=]*=/, ""); print; found += 1 } END { if (found != 1) exit 1 }' "$manifest"
}

for source_name in "${source_names[@]}"; do
  source_asset="$source_dir/$source_name"
  source_manifest="$source_asset.manifest.env"
  verify_source_asset "$source_asset"

  destination_name="${source_name/-$source_label./-$destination_label.}"
  destination_asset="$dist_dir/$destination_name"
  source_sha256="$(sha256_file "$source_asset")"
  target="$(manifest_value "$source_manifest" TARGET)"
  linkage="$(manifest_value "$source_manifest" WEBGPU_LINKAGE)"
  providers="$(manifest_value "$source_manifest" EXECUTION_PROVIDERS)"
  ORT_COMMIT_OVERRIDE="$(manifest_value "$source_manifest" ORT_COMMIT)"
  REPACKAGE_SOURCE_TAG="$source_tag"
  REPACKAGE_SOURCE_ASSET="$source_name"
  REPACKAGE_SOURCE_SHA256="$source_sha256"

  case "$source_name" in
    *.aar)
      cp "$source_asset" "$destination_asset"
      [ "$(sha256_file "$destination_asset")" = "$source_sha256" ] ||
        die "Android archive changed while being copied: $source_name"
      write_manifest "$destination_asset.manifest.env" "$target" "$linkage" "$providers"
      ;;
    *-ios-*.zip)
      package_dir="$work_dir/ios-package"
      source_package_dir="$work_dir/ios-source"
      mkdir -p "$package_dir" "$source_package_dir"
      unzip -q "$source_asset" -d "$source_package_dir"
      cmp "$source_manifest" "$source_package_dir/manifest.env" ||
        die "source iOS internal and external manifests differ"

      require_dir "$source_package_dir/onnxruntime.xcframework"
      static_library_root="$source_package_dir/static-lib"
      if [ ! -d "$static_library_root" ]; then
        static_library_root="$source_package_dir/onnxruntime.xcframework"
      fi
      cp "$source_package_dir/ONNXRUNTIME-LICENSE" "$package_dir/"
      [ ! -f "$source_package_dir/ThirdPartyNotices.txt" ] ||
        cp "$source_package_dir/ThirdPartyNotices.txt" "$package_dir/"
      [ ! -f "$source_package_dir/xcframework_info.json" ] ||
        cp "$source_package_dir/xcframework_info.json" "$package_dir/"
      "$SCRIPT_DIR/create-ios-static-xcframework.sh" \
        "$source_package_dir/onnxruntime.xcframework" \
        "$static_library_root" \
        "$package_dir/onnxruntime.xcframework"
      write_manifest "$package_dir/manifest.env" "$target" "$linkage" "$providers"
      (
        cd "$package_dir"
        COPYFILE_DISABLE=1 zip -qry "$destination_asset" .
      )
      cp "$package_dir/manifest.env" "$destination_asset.manifest.env"
      ;;
    *.tar.gz)
      package_dir="$work_dir/${source_name%.tar.gz}"
      mkdir -p "$package_dir"
      tar -xzf "$source_asset" -C "$package_dir"
      cmp "$source_manifest" "$package_dir/manifest.env" ||
        die "source tar internal and external manifests differ: $source_name"
      write_manifest "$package_dir/manifest.env" "$target" "$linkage" "$providers"
      COPYFILE_DISABLE=1 tar -C "$package_dir" -czf "$destination_asset" .
      cp "$package_dir/manifest.env" "$destination_asset.manifest.env"
      ;;
    *.zip)
      package_dir="$work_dir/${source_name%.zip}"
      mkdir -p "$package_dir"
      unzip -q "$source_asset" -d "$package_dir"
      cmp "$source_manifest" "$package_dir/manifest.env" ||
        die "source ZIP internal and external manifests differ: $source_name"
      write_manifest "$package_dir/manifest.env" "$target" "$linkage" "$providers"
      (
        cd "$package_dir"
        COPYFILE_DISABLE=1 zip -qry "$destination_asset" .
      )
      cp "$package_dir/manifest.env" "$destination_asset.manifest.env"
      ;;
    *) die "unsupported source asset: $source_name" ;;
  esac

  write_checksum "$destination_asset"
  log "repackaged $source_name as $destination_name"
done

expected_file_count=$((expected_binary_count * 3))
[ "$(find "$dist_dir" -maxdepth 1 -type f | wc -l | tr -d '[:space:]')" -eq "$expected_file_count" ] ||
  die "expected $expected_file_count repackaged asset files"
log "repackaged $expected_binary_count binary assets from $source_tag without native recompilation"
