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

require_cmd cmp
require_cmd python3
require_cmd unzip
require_cmd zip
require_file "$REPO_ROOT/config/android-webgpu.json"
require_dir "${ANDROID_HOME:-}"
require_dir "${ANDROID_NDK_HOME:-}"

ndk_bin="$(find "$ANDROID_NDK_HOME/toolchains/llvm/prebuilt" -type d -name bin -print -quit)"
require_dir "$ndk_bin"
ndk_readelf="$ndk_bin/llvm-readelf"
ndk_strip="$ndk_bin/llvm-strip"
require_file "$ndk_readelf"
require_file "$ndk_strip"

python3 - "$REPO_ROOT/config/android-webgpu.json" "$ANDROID_MIN_SDK" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as settings_file:
    settings = json.load(settings_file)

actual = settings.get("android_min_sdk_version")
expected = int(sys.argv[2])
if actual != expected:
    raise SystemExit(
        f"Android build configuration uses minSdk {actual}; expected {expected} from versions.env"
    )
PY

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
require_file "$ORT_SOURCE_DIR/LICENSE"
require_file "$ORT_SOURCE_DIR/ThirdPartyNotices.txt"
asset="$dist_dir/onnxruntime-webgpu-android-$abi-$ORT_VERSION-pilot.$PACKAGE_REVISION.aar"
package_dir="$build_dir/package"
mkdir -p "$package_dir"
unzip -q "$aar" -d "$package_dir"

while IFS= read -r -d '' library; do
  "$ndk_strip" --strip-unneeded "$library"
  if "$ndk_readelf" --sections "$library" | grep -Eq '] \.(debug|zdebug|gnu_debuglink|symtab)([[:space:]]|_)'; then
    die "Android runtime still contains debug or symbol-table sections after stripping: $library"
  fi

  stack_header="$("$ndk_readelf" --program-headers "$library" | awk '$1 == "GNU_STACK" { print; exit }')"
  [ -n "$stack_header" ] || die "Android runtime has no GNU_STACK header: $library"
  [[ "$stack_header" != *E* ]] || die "Android runtime requests an executable stack: $library"
done < <(find "$package_dir" -type f -name '*.so' -print0)

notice_dir="$package_dir/META-INF"
mkdir -p "$notice_dir"
cp "$ORT_SOURCE_DIR/LICENSE" "$notice_dir/ONNXRUNTIME-LICENSE"
cp "$ORT_SOURCE_DIR/ThirdPartyNotices.txt" "$notice_dir/ThirdPartyNotices.txt"
(
  cd "$package_dir"
  zip -q -r "$asset" .
)

write_checksum "$asset"
write_manifest "$asset.manifest.env" "android-$abi" "built-in" "WebGPU,XNNPACK,CPU"

unzip -l "$asset" | grep -q "jni/$abi/libonnxruntime.so" || die "AAR is missing libonnxruntime.so for $abi"
unzip -l "$asset" | grep -q "jni/$abi/libonnxruntime4j_jni.so" || die "AAR is missing JNI bridge for $abi"
cmp "$ORT_SOURCE_DIR/LICENSE" <(unzip -p "$asset" META-INF/ONNXRUNTIME-LICENSE) ||
  die "AAR has an invalid ONNX Runtime license"
cmp "$ORT_SOURCE_DIR/ThirdPartyNotices.txt" <(unzip -p "$asset" META-INF/ThirdPartyNotices.txt) ||
  die "AAR has invalid third-party notices"
log "created $asset"
