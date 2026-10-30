#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common.sh"

abi="${1:-}"
mode="${2:-cpu}"
case "$abi" in arm64-v8a | armeabi-v7a | x86_64) ;; *) die "invalid Android ABI" ;; esac
case "$mode" in cpu | webgpu) ;; *) die "mode must be cpu or webgpu" ;; esac
require_cmd adb
require_cmd cmake
require_cmd javac
asset="${ORT_PACKAGE_ASSET:-$DIST_ROOT/android-$abi/onnxruntime-webgpu-android-$abi-$ORT_VERSION-$(package_label).aar}"
package_dir="$BUILD_ROOT/android-$abi-runtime-package"
require_file "$asset"
rm -rf "$package_dir"
mkdir -p "$package_dir"
unzip -q "$asset" -d "$package_dir"
core="$package_dir/jni/$abi/libonnxruntime.so"
model="$ORT_SOURCE_DIR/onnxruntime/test/testdata/mul_1.onnx"
headers="$ORT_SOURCE_DIR/include/onnxruntime/core/session"
toolchain="$ANDROID_NDK_HOME/build/cmake/android.toolchain.cmake"
test_build_dir="$BUILD_ROOT/android-$abi-runtime-smoke"
require_file "$core"
require_file "$model"
require_dir "$headers"
require_file "$toolchain"
if [ "$mode" = webgpu ]; then
  [ "$(adb shell getprop ro.kernel.qemu | tr -d '\r')" != 1 ] || die "WebGPU device acceptance requires a physical device"
fi
rm -rf "$test_build_dir"
cmake -S "$REPO_ROOT/tests" -B "$test_build_dir" -G Ninja \
  -DCMAKE_BUILD_TYPE=Release -DCMAKE_TOOLCHAIN_FILE="$toolchain" \
  -DANDROID_ABI="$abi" -DANDROID_PLATFORM="android-$ANDROID_MIN_SDK" -DORT_INCLUDE_DIR="$headers"
cmake --build "$test_build_dir" --parallel "$JOBS"
mkdir -p "$test_build_dir/classes" "$test_build_dir/dex"
javac --release 8 -cp "$package_dir/classes.jar" -d "$test_build_dir/classes" "$REPO_ROOT/tests/AndroidRuntimeSmoke.java"
"$ANDROID_HOME/build-tools/$ANDROID_BUILD_TOOLS_VERSION/d8" \
  --min-api "$ANDROID_MIN_SDK" --lib "$ANDROID_HOME/platforms/android-$ANDROID_TARGET_SDK/android.jar" \
  --output "$test_build_dir/dex" "$package_dir/classes.jar" "$test_build_dir/classes/AndroidRuntimeSmoke.class"
remote_dir=/data/local/tmp/ort-packaging-smoke
adb shell "rm -rf $remote_dir && mkdir -p $remote_dir"
adb push "$test_build_dir/runtime-smoke" "$remote_dir/runtime-smoke"
adb push "$package_dir/jni/$abi/". "$remote_dir/"
adb push "$test_build_dir/dex/classes.dex" "$remote_dir/classes.dex"
adb push "$model" "$remote_dir/mul_1.onnx"
provider=cpu-only
required=0
if [ "$mode" = webgpu ]; then
  provider=builtin:WebGPU
  required=1
fi
log="$BUILD_ROOT/android-$abi-smoke.log"
{
  adb shell "chmod 755 $remote_dir/runtime-smoke && cd $remote_dir && LD_LIBRARY_PATH=$remote_dir ./runtime-smoke ./libonnxruntime.so $provider ./mul_1.onnx $required Vulkan"
  adb shell "cd $remote_dir && CLASSPATH=$remote_dir/classes.dex LD_LIBRARY_PATH=$remote_dir app_process -Djava.library.path=$remote_dir /system/bin AndroidRuntimeSmoke ./mul_1.onnx $remote_dir"
  if [ "$mode" = webgpu ]; then echo 'PHYSICAL_DEVICE=passed'; fi
  echo "ASSET_SHA256=$(sha256_file "$asset")"
} | tee "$log"
python3 "$REPO_ROOT/scripts/release.py" record "$asset" --log "$log"
