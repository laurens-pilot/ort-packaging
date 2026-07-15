#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "$SCRIPT_DIR/common.sh"

require_cmd python3
require_cmd xcodebuild
require_file "$REPO_ROOT/config/apple-webgpu.json"
prepare_ort_source

build_dir="$BUILD_ROOT/ios"
dist_dir="$DIST_ROOT/ios"
rm -rf "$build_dir" "$dist_dir"
mkdir -p "$build_dir" "$dist_dir" "$build_dir/preserved"

build_slice() {
  local sysroot="$1"
  local arch="$2"
  local output_list="$build_dir/${sysroot}-${arch}.outputs"
  local archive="$build_dir/preserved/${sysroot}-${arch}.tar"

  log "building iOS WebGPU framework for $sysroot/$arch"
  python3 "$ORT_SOURCE_DIR/tools/ci_build/github/apple/build_apple_framework.py" \
    --build_dir "$build_dir" \
    --config Release \
    --only_build_single_sysroot_arch_framework "$sysroot" "$arch" \
    --record_sysroot_arch_framework_build_outputs_to_file "$output_list" \
    "$REPO_ROOT/config/apple-webgpu.json"

  tar -C "$build_dir" -cf "$archive" -T "$output_list"
  rm -rf "$build_dir/intermediates"
  mkdir -p "$build_dir/intermediates"
  tar -C "$build_dir" -xf "$archive"
}

build_slice iphoneos arm64
build_slice iphonesimulator arm64

python3 "$ORT_SOURCE_DIR/tools/ci_build/github/apple/build_apple_framework.py" \
  --build_dir "$build_dir" \
  --config Release \
  --only_assemble_xcframework \
  "$REPO_ROOT/config/apple-webgpu.json"

framework="$build_dir/framework_out/onnxruntime.xcframework"
require_dir "$framework"
asset="$dist_dir/onnxruntime-webgpu-ios-$ORT_VERSION-pilot.$PACKAGE_REVISION.xcframework.tar.gz"
tar -C "$build_dir/framework_out" -czf "$asset" onnxruntime.xcframework LICENSE
write_checksum "$asset"
write_manifest "$dist_dir/manifest.env" "ios-arm64" "built-in-static"
xcodebuild -checkFirstLaunchStatus >/dev/null
log "created $asset"
