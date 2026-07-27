#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "$SCRIPT_DIR/common.sh"

require_cmd lipo
require_cmd nm
require_cmd otool
require_cmd plutil
require_cmd python3
require_cmd strip
require_cmd tee
require_cmd xcodebuild
require_cmd xcrun
require_cmd zip
require_file "$REPO_ROOT/config/ios-coreml.json"
prepare_ort_source

settings="$REPO_ROOT/config/ios-coreml.json"
build_dir="$BUILD_ROOT/ios"
dist_dir="$DIST_ROOT/ios"
package_dir="$dist_dir/package"
rm -rf "$build_dir" "$dist_dir"
mkdir -p "$build_dir" "$package_dir"

python3 - "$settings" "$IOS_MIN_VERSION" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as settings_file:
    settings = json.load(settings_file)

expected = f"--apple_deploy_target={sys.argv[2]}"
for sysroot in ("iphoneos", "iphonesimulator"):
    params = settings["build_params"][sysroot]
    if expected not in params:
        raise SystemExit(f"{sysroot} does not use {expected}")

base = settings["build_params"]["base"]
if "--use_coreml" not in base:
    raise SystemExit("CoreML is not enabled")
for forbidden in ("--use_webgpu", "--use_xnnpack"):
    if any(param == forbidden or param.startswith(f"{forbidden}=") for params in settings["build_params"].values() for param in params):
        raise SystemExit(f"forbidden iOS provider enabled: {forbidden}")
PY

log "building iOS CoreML XCFramework"
build_log="$build_dir/build.log"
python3 "$ORT_SOURCE_DIR/tools/ci_build/github/apple/build_apple_framework.py" \
  --build_dir "$build_dir" \
  --config Release \
  "$settings" 2>&1 | tee "$build_log"

if grep -Fq -- '-Wunguarded-availability-new' "$build_log"; then
  die "iOS build emitted an unguarded runtime availability warning"
fi

xcframework="$build_dir/framework_out/onnxruntime.xcframework"
require_dir "$xcframework"

python3 - "$xcframework/Info.plist" <<'PY'
import plistlib
import sys

with open(sys.argv[1], "rb") as plist_file:
    libraries = plistlib.load(plist_file)["AvailableLibraries"]

actual = {
    (
        item["SupportedPlatform"],
        item.get("SupportedPlatformVariant"),
        tuple(sorted(item["SupportedArchitectures"])),
    )
    for item in libraries
}
expected = {
    ("ios", None, ("arm64",)),
    ("ios", "simulator", ("arm64",)),
}
if actual != expected:
    raise SystemExit(f"unexpected XCFramework slices: {actual}")
PY

framework_binaries=()
while IFS= read -r -d '' binary; do
  framework_binaries+=("$binary")
done < <(find "$xcframework" -type f -name onnxruntime -print0)
[ "${#framework_binaries[@]}" -eq 2 ] || die "expected two iOS framework binaries"
for binary in "${framework_binaries[@]}"; do
  strip -S "$binary"
  if otool -l "$binary" | grep -Fq 'segname __DWARF'; then
    die "iOS framework still contains DWARF sections after stripping: $binary"
  fi

  archs="$(lipo -archs "$binary")"
  case "$binary" in
    *simulator*) [ "$archs" = "arm64" ] || die "unexpected simulator architectures: $archs" ;;
    *) [ "$archs" = "arm64" ] || die "unexpected device architectures: $archs" ;;
  esac

  min_versions="$(otool -l "$binary" | awk '$1 == "minos" { print $2 }' | sort -u)"
  [ "$min_versions" = "$IOS_MIN_VERSION" ] || die "unexpected iOS deployment target in $binary: ${min_versions:-missing}"
  framework_dir="$(dirname "$binary")"
  slice_name="$(basename "$(dirname "$framework_dir")")"
  symbols_file="$build_dir/$slice_name-symbols.txt"
  nm -gU "$binary" >"$symbols_file"
  grep -Fq '_OrtGetApiBase' "$symbols_file" || die "ORT core does not export OrtGetApiBase"
  grep -Fq '_OrtSessionOptionsAppendExecutionProvider_CoreML' "$symbols_file" || die "ORT core does not include CoreML EP"

  static_library="$build_dir/static-lib/$slice_name/libonnxruntime.a"
  mkdir -p "$(dirname "$static_library")"
  lipo "$binary" -thin arm64 -output "$static_library"

  lipo -info "$static_library" | grep -Fq 'Non-fat file' ||
    die "pre-thinned iOS archive is still a universal binary: $static_library"
  [ "$(lipo -archs "$static_library")" = arm64 ] ||
    die "unexpected pre-thinned iOS archive architecture: $static_library"
  if otool -l "$static_library" | grep -Fq 'segname __DWARF'; then
    die "pre-thinned iOS archive contains DWARF sections: $static_library"
  fi

  static_min_versions="$(otool -l "$static_library" | awk '$1 == "minos" { print $2 }' | sort -u)"
  [ "$static_min_versions" = "$IOS_MIN_VERSION" ] ||
    die "unexpected deployment target in $static_library: ${static_min_versions:-missing}"
  static_platforms="$(otool -l "$static_library" | awk '$1 == "platform" { print $2 }' | sort -u)"
  case "$slice_name" in
    ios-arm64) expected_platform=2 ;;
    ios-arm64-simulator) expected_platform=7 ;;
    *) die "unexpected iOS slice name: $slice_name" ;;
  esac
  [ "$static_platforms" = "$expected_platform" ] ||
    die "unexpected Apple platform in $static_library: ${static_platforms:-missing}"

  static_symbols_file="$build_dir/$slice_name-static-symbols.txt"
  nm -gU "$static_library" >"$static_symbols_file"
  grep -Fq '_OrtGetApiBase' "$static_symbols_file" ||
    die "pre-thinned ORT archive does not export OrtGetApiBase"
  grep -Fq '_OrtSessionOptionsAppendExecutionProvider_CoreML' "$static_symbols_file" ||
    die "pre-thinned ORT archive does not include CoreML EP"
done

require_file "$build_dir/static-lib/ios-arm64/libonnxruntime.a"
require_file "$build_dir/static-lib/ios-arm64-simulator/libonnxruntime.a"

"$SCRIPT_DIR/create-ios-static-xcframework.sh" \
  "$xcframework" \
  "$build_dir/static-lib" \
  "$package_dir/onnxruntime.xcframework"
cp "$ORT_SOURCE_DIR/LICENSE" "$package_dir/ONNXRUNTIME-LICENSE"
[ -f "$ORT_SOURCE_DIR/ThirdPartyNotices.txt" ] && cp "$ORT_SOURCE_DIR/ThirdPartyNotices.txt" "$package_dir/"
[ -f "$build_dir/xcframework_info.json" ] && cp "$build_dir/xcframework_info.json" "$package_dir/"
write_manifest "$package_dir/manifest.env" "ios" "disabled" "CoreML,CPU"

asset="$dist_dir/onnxruntime-coreml-ios-$ORT_VERSION-$(package_label).zip"
(
  cd "$package_dir"
  COPYFILE_DISABLE=1 zip -qry "$asset" .
)
write_checksum "$asset"
cp "$package_dir/manifest.env" "$asset.manifest.env"
log "created $asset"
