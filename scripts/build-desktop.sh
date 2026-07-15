#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "$SCRIPT_DIR/common.sh"

target="${1:-}"
case "$target" in
  linux-x64 | linux-arm64 | macos-x64 | macos-arm64) ;;
  *) die "usage: $0 <linux-x64|linux-arm64|macos-x64|macos-arm64>" ;;
esac

require_cmd python3
prepare_ort_source
build_dir="$BUILD_ROOT/$target"
dist_dir="$DIST_ROOT/$target"
rm -rf "$build_dir" "$dist_dir"
mkdir -p "$build_dir" "$dist_dir/package"

cmake_defines=("onnxruntime_BUILD_UNIT_TESTS=OFF")
case "$target" in
  linux-*)
    cmake_defines+=("onnxruntime_ENABLE_DAWN_BACKEND_VULKAN=1")
    plugin="$build_dir/Release/libonnxruntime_providers_webgpu.so"
    ;;
  macos-x64)
    cmake_defines+=("CMAKE_OSX_ARCHITECTURES=x86_64" "CMAKE_OSX_DEPLOYMENT_TARGET=$MACOS_MIN_VERSION")
    plugin="$build_dir/Release/libonnxruntime_providers_webgpu.dylib"
    ;;
  macos-arm64)
    cmake_defines+=("CMAKE_OSX_ARCHITECTURES=arm64" "CMAKE_OSX_DEPLOYMENT_TARGET=$MACOS_MIN_VERSION")
    plugin="$build_dir/Release/libonnxruntime_providers_webgpu.dylib"
    ;;
esac

log "building WebGPU plugin for $target"
python3 "$ORT_SOURCE_DIR/tools/ci_build/build.py" \
  --build_dir "$build_dir" \
  --config Release \
  --parallel "$JOBS" \
  --skip_tests \
  --use_vcpkg \
  --use_webgpu shared_lib \
  --wgsl_template static \
  --disable_rtti \
  --enable_lto \
  --cmake_generator Ninja \
  --cmake_extra_defines "${cmake_defines[@]}"

require_file "$plugin"
cp "$plugin" "$dist_dir/package/"
cp "$ORT_SOURCE_DIR/LICENSE" "$dist_dir/package/ONNXRUNTIME-LICENSE"
[ -f "$ORT_SOURCE_DIR/ThirdPartyNotices.txt" ] && cp "$ORT_SOURCE_DIR/ThirdPartyNotices.txt" "$dist_dir/package/"
write_manifest "$dist_dir/package/manifest.env" "$target" "plugin-shared"

if [[ "$target" == macos-* ]]; then
  codesign --force --sign - "$dist_dir/package/$(basename "$plugin")"
  file "$plugin" | grep -q "${target#macos-}" || die "unexpected macOS binary architecture"
else
  readelf -h "$plugin" >/dev/null
fi

asset="$dist_dir/onnxruntime-webgpu-$target-$ORT_VERSION-pilot.$PACKAGE_REVISION.tar.gz"
tar -C "$dist_dir/package" -czf "$asset" .
write_checksum "$asset"
log "created $asset"
