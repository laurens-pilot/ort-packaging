#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "$SCRIPT_DIR/common.sh"

abi="${1:-}"
[ "$abi" = "x86_64" ] || die "usage: $0 x86_64"
require_cmd adb
require_cmd cmake

package_dir="$BUILD_ROOT/android-$abi/package"
core="$package_dir/jni/$abi/libonnxruntime.so"
model="$ORT_SOURCE_DIR/onnxruntime/test/testdata/mul_1.onnx"
headers="$ORT_SOURCE_DIR/include/onnxruntime/core/session"
toolchain="$ANDROID_NDK_HOME/build/cmake/android.toolchain.cmake"
test_build_dir="$BUILD_ROOT/android-$abi-runtime-smoke"
require_file "$core"
require_file "$model"
require_dir "$headers"
require_file "$toolchain"

rm -rf "$test_build_dir"
cmake -S "$REPO_ROOT/tests" -B "$test_build_dir" \
  -G Ninja \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_TOOLCHAIN_FILE="$toolchain" \
  -DANDROID_ABI="$abi" \
  -DANDROID_PLATFORM="android-$ANDROID_MIN_SDK" \
  -DORT_INCLUDE_DIR="$headers"
cmake --build "$test_build_dir" --parallel "$JOBS"

remote_dir=/data/local/tmp/ort-packaging-smoke
adb shell "rm -rf $remote_dir && mkdir -p $remote_dir"
adb push "$test_build_dir/runtime-smoke" "$remote_dir/runtime-smoke"
adb push "$core" "$remote_dir/libonnxruntime.so"
adb push "$model" "$remote_dir/mul_1.onnx"
# Hosted Android emulators use SwiftShader without a host GPU. Upstream ORT
# therefore skips WebGPU execution on these emulators. This still validates
# that the exact packaged x86_64 runtime loads and performs inference.
adb shell "chmod 755 $remote_dir/runtime-smoke && cd $remote_dir && LD_LIBRARY_PATH=$remote_dir ./runtime-smoke ./libonnxruntime.so cpu-only ./mul_1.onnx 0 -"
