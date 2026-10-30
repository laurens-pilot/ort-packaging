#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "$SCRIPT_DIR/common.sh"

require_cmd codesign
require_cmd python3
require_cmd xcrun

asset="${ORT_PACKAGE_ASSET:-$DIST_ROOT/ios/onnxruntime-coreml-ios-$ORT_VERSION-$(package_label).zip}"
package_dir="$BUILD_ROOT/ios-runtime-package"
require_file "$asset"
rm -rf "$package_dir"
mkdir -p "$package_dir"
unzip -q "$asset" -d "$package_dir"
xcframework="$package_dir/onnxruntime.xcframework"
sdk=iphonesimulator
minimum_flag="-mios-simulator-version-min=$IOS_MIN_VERSION"
slice="$xcframework/ios-arm64-simulator"
if [ -n "${IOS_DEVICE_ID:-}" ]; then
  sdk=iphoneos
  minimum_flag="-miphoneos-version-min=$IOS_MIN_VERSION"
  slice="$xcframework/ios-arm64"
fi
headers="$slice/Headers"
static_library="$slice/libonnxruntime.a"
model="$ORT_SOURCE_DIR/onnxruntime/test/testdata/mul_1.onnx"
app_dir="$BUILD_ROOT/ios-runtime-smoke/ORT-Runtime-Smoke.app"
require_dir "$headers"
require_file "$static_library"
require_file "$model"

rm -rf "$(dirname "$app_dir")"
mkdir -p "$app_dir"
sdk_path="$(xcrun --sdk "$sdk" --show-sdk-path)"
xcrun --sdk "$sdk" clang++ \
  -std=c++17 \
  -Wall -Wextra -Werror \
  -fobjc-arc \
  -arch arm64 \
  "$minimum_flag" \
  -isysroot "$sdk_path" \
  -I "$headers" \
  "$REPO_ROOT/tests/ios-smoke.mm" \
  "$static_library" \
  -framework Foundation \
  -weak_framework CoreML \
  -o "$app_dir/runtime-smoke"
python3 "$REPO_ROOT/scripts/write-ios-info.py" "$REPO_ROOT/tests/ios-smoke-Info.plist" "$app_dir/Info.plist" "$IOS_MIN_VERSION" "$sdk"
cp "$model" "$app_dir/mul_1.onnx"
if [ -n "${IOS_DEVICE_ID:-}" ]; then
  require_file "${IOS_PROVISIONING_PROFILE:?IOS_PROVISIONING_PROFILE is required}"
  require_file "${IOS_ENTITLEMENTS:?IOS_ENTITLEMENTS is required}"
  cp "$IOS_PROVISIONING_PROFILE" "$app_dir/embedded.mobileprovision"
  codesign --force --sign "${IOS_SIGNING_IDENTITY:?IOS_SIGNING_IDENTITY is required}" --entitlements "$IOS_ENTITLEMENTS" "$app_dir"
else
  codesign --force --sign - "$app_dir"
fi

if [ -n "${IOS_DEVICE_ID:-}" ]; then
  xcrun devicectl device install app --device "$IOS_DEVICE_ID" "$app_dir"
  launch_output="$(xcrun devicectl device process launch --device "$IOS_DEVICE_ID" --console --terminate-existing io.ente.ort-packaging.runtime-smoke)"
  launch_status=0
else
  device_id="$(xcrun simctl list devices available -j | python3 "$REPO_ROOT/scripts/select-ios-simulator.py")"
  [ -n "$device_id" ] || die "no available iPhone Simulator was found"
  xcrun simctl boot "$device_id" 2>/dev/null || true
  xcrun simctl bootstatus "$device_id" -b
  xcrun simctl install "$device_id" "$app_dir"

  set +e
  launch_output="$(xcrun simctl launch --console --terminate-running-process \
    "$device_id" io.ente.ort-packaging.runtime-smoke 2>&1)"
  launch_status=$?
  set -e

fi
printf '%s\n' "$launch_output"
[ "$launch_status" -eq 0 ] || die "iOS runtime smoke-test app failed"
grep -Fq 'CPU_INFERENCE=passed' <<<"$launch_output" || die "iOS CPU inference result was not observed"
grep -Fq 'COREML_INFERENCE=passed' <<<"$launch_output" || die "iOS CoreML inference result was not observed"
grep -Fq 'IOS_RUNTIME_SMOKE=passed' <<<"$launch_output" || die "iOS runtime smoke-test completion was not observed"
if [ -n "${IOS_DEVICE_ID:-}" ]; then
  launch_output="$launch_output
PHYSICAL_DEVICE=passed
ASSET_SHA256=$(sha256_file "$asset")"
fi
printf '%s\n' "$launch_output" | tee "$BUILD_ROOT/ios-smoke.log"
python3 "$REPO_ROOT/scripts/release.py" record "$asset" --log "$BUILD_ROOT/ios-smoke.log"
