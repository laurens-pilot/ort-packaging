#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "$SCRIPT_DIR/common.sh"

[ "$#" -ge 2 ] || die "usage: $0 <output-dir> <aar> [aar ...]"
output_dir="$1"
shift
work_dir="$BUILD_ROOT/android-merged"
rm -rf "$work_dir" "$output_dir"
mkdir -p "$work_dir/base" "$output_dir"

first="$1"
unzip -q "$first" -d "$work_dir/base"
shift

for aar in "$@"; do
  overlay="$work_dir/overlay"
  rm -rf "$overlay"
  mkdir -p "$overlay"
  unzip -q "$aar" -d "$overlay"

  while IFS= read -r -d '' file; do
    relative="${file#"$overlay/"}"
    destination="$work_dir/base/$relative"
    case "$relative" in
      jni/* | prefab/modules/*/libs/android.*/*)
        mkdir -p "$(dirname "$destination")"
        cp "$file" "$destination"
        ;;
      *)
        if [ -f "$destination" ]; then
          cmp -s "$file" "$destination" || die "non-ABI AAR entry differs: $relative"
        else
          mkdir -p "$(dirname "$destination")"
          cp "$file" "$destination"
        fi
        ;;
    esac
  done < <(find "$overlay" -type f -print0)
done

asset="$output_dir/onnxruntime-webgpu-android-$ORT_VERSION-pilot.$PACKAGE_REVISION.aar"
(cd "$work_dir/base" && zip -q -r "$asset" .)
write_checksum "$asset"
write_manifest "$output_dir/manifest.env" "android-universal" "built-in"

for abi in arm64-v8a armeabi-v7a x86_64; do
  unzip -l "$asset" | grep -q "jni/$abi/libonnxruntime.so" || die "merged AAR is missing $abi"
done
log "created $asset"
