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
python3 "$ORT_SOURCE_DIR/tools/ci_build/github/apple/build_apple_framework.py" \
  --build_dir "$build_dir" \
  --config Release \
  "$settings"

xcframework="$build_dir/framework_out/onnxruntime.xcframework"
require_dir "$xcframework"
cp -R "$xcframework" "$package_dir/"
cp "$ORT_SOURCE_DIR/LICENSE" "$package_dir/ONNXRUNTIME-LICENSE"
[ -f "$ORT_SOURCE_DIR/ThirdPartyNotices.txt" ] && cp "$ORT_SOURCE_DIR/ThirdPartyNotices.txt" "$package_dir/"
[ -f "$build_dir/xcframework_info.json" ] && cp "$build_dir/xcframework_info.json" "$package_dir/"
write_manifest "$package_dir/manifest.env" "ios" "disabled" "CoreML,CPU"

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
  archs="$(lipo -archs "$binary")"
  case "$binary" in
    *simulator*) [ "$archs" = "arm64" ] || die "unexpected simulator architectures: $archs" ;;
    *) [ "$archs" = "arm64" ] || die "unexpected device architectures: $archs" ;;
  esac

  min_versions="$(otool -l "$binary" | awk '$1 == "minos" { print $2 }' | sort -u)"
  [ "$min_versions" = "$IOS_MIN_VERSION" ] || die "unexpected iOS deployment target in $binary: ${min_versions:-missing}"
  grep -q '_OrtGetApiBase' < <(nm -gU "$binary") || die "ORT core does not export OrtGetApiBase"
  grep -q '_OrtSessionOptionsAppendExecutionProvider_CoreML' < <(nm -gU "$binary") || die "ORT core does not include CoreML EP"
done

asset="$dist_dir/onnxruntime-coreml-ios-$ORT_VERSION-pilot.$PACKAGE_REVISION.zip"
(
  cd "$package_dir"
  COPYFILE_DISABLE=1 zip -qry "$asset" .
)
write_checksum "$asset"
cp "$package_dir/manifest.env" "$asset.manifest.env"
log "created $asset"
