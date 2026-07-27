#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "$SCRIPT_DIR/common.sh"

[ "$#" -eq 3 ] || die "usage: $0 <framework-xcframework> <static-library-root> <output-xcframework>"

source_xcframework="$1"
static_root="$2"
output_xcframework="$3"

require_cmd lipo
require_cmd nm
require_cmd otool
require_cmd python3
require_cmd xcodebuild
require_dir "$source_xcframework"

device_library="$static_root/ios-arm64/libonnxruntime.a"
simulator_library="$static_root/ios-arm64-simulator/libonnxruntime.a"
device_headers="$source_xcframework/ios-arm64/onnxruntime.framework/Headers"
simulator_headers="$source_xcframework/ios-arm64-simulator/onnxruntime.framework/Headers"
require_file "$device_library"
require_file "$simulator_library"
require_dir "$device_headers"
require_dir "$simulator_headers"

for slice_name in ios-arm64 ios-arm64-simulator; do
  library="$static_root/$slice_name/libonnxruntime.a"
  [ "$(lipo -archs "$library")" = arm64 ] ||
    die "unexpected architecture in $library"
  if otool -l "$library" | grep -Fq 'segname __DWARF'; then
    die "static iOS archive contains DWARF sections: $library"
  fi

  min_versions="$(otool -l "$library" | awk '$1 == "minos" { print $2 }' | sort -u)"
  [ "$min_versions" = "$IOS_MIN_VERSION" ] ||
    die "unexpected deployment target in $library: ${min_versions:-missing}"
  platforms="$(otool -l "$library" | awk '$1 == "platform" { print $2 }' | sort -u)"
  case "$slice_name" in
    ios-arm64) expected_platform=2 ;;
    ios-arm64-simulator) expected_platform=7 ;;
  esac
  [ "$platforms" = "$expected_platform" ] ||
    die "unexpected Apple platform in $library: ${platforms:-missing}"

  symbols_file="$(mktemp)"
  nm -gU "$library" >"$symbols_file"
  grep -Fq '_OrtGetApiBase' "$symbols_file" ||
    die "iOS archive does not export OrtGetApiBase: $library"
  grep -Fq '_OrtSessionOptionsAppendExecutionProvider_CoreML' "$symbols_file" ||
    die "iOS archive does not include CoreML EP: $library"
  rm -f "$symbols_file"
done

[ ! -e "$output_xcframework" ] || die "output already exists: $output_xcframework"
xcodebuild -create-xcframework \
  -library "$device_library" \
  -headers "$device_headers" \
  -library "$simulator_library" \
  -headers "$simulator_headers" \
  -output "$output_xcframework"

python3 - "$output_xcframework/Info.plist" <<'PY'
import plistlib
import sys

with open(sys.argv[1], "rb") as plist_file:
    libraries = plistlib.load(plist_file)["AvailableLibraries"]

actual = {
    (
        item["LibraryIdentifier"],
        item["LibraryPath"],
        item.get("HeadersPath"),
        item["SupportedPlatform"],
        item.get("SupportedPlatformVariant"),
        tuple(sorted(item["SupportedArchitectures"])),
    )
    for item in libraries
}
expected = {
    ("ios-arm64", "libonnxruntime.a", "Headers", "ios", None, ("arm64",)),
    (
        "ios-arm64-simulator",
        "libonnxruntime.a",
        "Headers",
        "ios",
        "simulator",
        ("arm64",),
    ),
}
if actual != expected:
    raise SystemExit(f"unexpected static-library XCFramework slices: {actual}")
PY

for slice_name in ios-arm64 ios-arm64-simulator; do
  source_library="$static_root/$slice_name/libonnxruntime.a"
  packaged_library="$output_xcframework/$slice_name/libonnxruntime.a"
  require_file "$packaged_library"
  [ "$(sha256_file "$source_library")" = "$(sha256_file "$packaged_library")" ] ||
    die "xcodebuild changed the static archive for $slice_name"
done

if find "$output_xcframework" -type d -name '*.framework' | grep -q .; then
  die "static-library XCFramework unexpectedly contains a framework bundle"
fi

log "created static-library XCFramework at $output_xcframework"
