#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "$SCRIPT_DIR/common.sh"

require_cmd codesign
require_cmd python3
require_cmd xcrun

package_dir="${IOS_PACKAGE_DIR:-$DIST_ROOT/ios/package}"
xcframework="$package_dir/onnxruntime.xcframework"
slice="$xcframework/ios-arm64-simulator"
headers="$slice/Headers"
static_library="$slice/libonnxruntime.a"
model="$ORT_SOURCE_DIR/onnxruntime/test/testdata/mul_1.onnx"
app_dir="$BUILD_ROOT/ios-runtime-smoke/ORT-Runtime-Smoke.app"
require_dir "$headers"
require_file "$static_library"
require_file "$model"

rm -rf "$(dirname "$app_dir")"
mkdir -p "$app_dir"
sdk_path="$(xcrun --sdk iphonesimulator --show-sdk-path)"
xcrun --sdk iphonesimulator clang++ \
  -std=c++17 \
  -Wall -Wextra -Werror \
  -fobjc-arc \
  -arch arm64 \
  -mios-simulator-version-min="$IOS_MIN_VERSION" \
  -isysroot "$sdk_path" \
  -I "$headers" \
  "$REPO_ROOT/tests/ios-smoke.mm" \
  "$static_library" \
  -framework Foundation \
  -weak_framework CoreML \
  -o "$app_dir/runtime-smoke"
cp "$REPO_ROOT/tests/ios-smoke-Info.plist" "$app_dir/Info.plist"
cp "$model" "$app_dir/mul_1.onnx"
codesign --force --sign - "$app_dir"

device_id="$(xcrun simctl list devices available -j | python3 -c '
import json
import sys

devices_by_runtime = json.load(sys.stdin)["devices"]
for runtime, devices in devices_by_runtime.items():
    if ".iOS-" not in runtime:
        continue
    for device in devices:
        if device.get("isAvailable"):
            print(device["udid"])
            raise SystemExit
')"
[ -n "$device_id" ] || die "no available iPhone Simulator was found"
xcrun simctl boot "$device_id" 2>/dev/null || true
xcrun simctl bootstatus "$device_id" -b
xcrun simctl install "$device_id" "$app_dir"

set +e
launch_output="$(xcrun simctl launch --console --terminate-running-process \
  "$device_id" io.ente.ort-packaging.runtime-smoke 2>&1)"
launch_status=$?
set -e
printf '%s\n' "$launch_output"
[ "$launch_status" -eq 0 ] || die "iOS runtime smoke-test app failed"
grep -Fq 'CPU_INFERENCE=passed' <<<"$launch_output" || die "iOS CPU inference result was not observed"
grep -Fq 'COREML_INFERENCE=passed' <<<"$launch_output" || die "iOS CoreML inference result was not observed"
grep -Fq 'IOS_RUNTIME_SMOKE=passed' <<<"$launch_output" || die "iOS runtime smoke-test completion was not observed"
