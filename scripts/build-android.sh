#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "$SCRIPT_DIR/common.sh"

abi="${1:-}"
case "$abi" in
  arm64-v8a | armeabi-v7a | x86_64) ;;
  *) die "usage: $0 <arm64-v8a|armeabi-v7a|x86_64>" ;;
esac

require_cmd python3
require_file "$REPO_ROOT/config/android-webgpu.json"
require_dir "${ANDROID_HOME:-}"
require_dir "${ANDROID_NDK_HOME:-}"
prepare_ort_source

build_dir="$BUILD_ROOT/android-$abi"
dist_dir="$DIST_ROOT/android-$abi"
settings="$build_dir/android-webgpu-$abi.json"
rm -rf "$build_dir" "$dist_dir"
mkdir -p "$build_dir" "$dist_dir"

sed "s/\"arm64-v8a\"/\"$abi\"/" "$REPO_ROOT/config/android-webgpu.json" >"$settings"

log "building Android WebGPU AAR for $abi"
python3 "$ORT_SOURCE_DIR/tools/ci_build/github/android/build_aar_package.py" \
  --build_dir "$build_dir" \
  --config Release \
  --android_sdk_path "$ANDROID_HOME" \
  --android_ndk_path "$ANDROID_NDK_HOME" \
  "$settings"

aar="$(find "$build_dir/aar_out/Release" -type f -name '*.aar' -print -quit)"
require_file "$aar"
asset="$dist_dir/onnxruntime-webgpu-android-$abi-$ORT_VERSION-pilot.$PACKAGE_REVISION.aar"
cp "$aar" "$asset"
write_checksum "$asset"
write_manifest "$asset.manifest.env" "android-$abi" "built-in" "WebGPU,XNNPACK,CPU"

unzip -l "$asset" | grep -q "jni/$abi/libonnxruntime.so" || die "AAR is missing libonnxruntime.so for $abi"
unzip -l "$asset" | grep -q "jni/$abi/libonnxruntime4j_jni.so" || die "AAR is missing JNI bridge for $abi"
log "created $asset"
