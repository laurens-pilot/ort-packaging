#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "$SCRIPT_DIR/common.sh"

target="${1:-}"
case "$target" in
  linux-x64 | linux-arm64 | macos-x64 | macos-arm64) ;;
  *) die "usage: $0 <linux-x64|linux-arm64|macos-x64|macos-arm64>" ;;
esac

require_cmd python3
prepare_ort_source
build_dir="$BUILD_ROOT/$target"
dist_dir="$DIST_ROOT/$target"
rm -rf "$build_dir" "$dist_dir"
mkdir -p "$build_dir" "$dist_dir/package"

cmake_defines=("onnxruntime_BUILD_UNIT_TESTS=OFF")
case "$target" in
  linux-*)
    cmake_defines+=("onnxruntime_ENABLE_DAWN_BACKEND_VULKAN=1")
    plugin="$build_dir/Release/libonnxruntime_providers_webgpu.so"
    core="$build_dir/Release/libonnxruntime.so.$ORT_VERSION"
    ;;
  macos-x64)
    cmake_defines+=("CMAKE_OSX_ARCHITECTURES=x86_64" "CMAKE_OSX_DEPLOYMENT_TARGET=$MACOS_MIN_VERSION")
    plugin="$build_dir/Release/libonnxruntime_providers_webgpu.dylib"
    core="$build_dir/Release/libonnxruntime.$ORT_VERSION.dylib"
    ;;
  macos-arm64)
    cmake_defines+=("CMAKE_OSX_ARCHITECTURES=arm64" "CMAKE_OSX_DEPLOYMENT_TARGET=$MACOS_MIN_VERSION")
    plugin="$build_dir/Release/libonnxruntime_providers_webgpu.dylib"
    core="$build_dir/Release/libonnxruntime.$ORT_VERSION.dylib"
    ;;
esac

if [[ "$target" == macos-* ]]; then
  # ORT's build.py reads this when generating its vcpkg overlay triplets. A
  # top-level -DVCPKG_OSX_DEPLOYMENT_TARGET does not configure vcpkg ports.
  export MACOSX_DEPLOYMENT_TARGET="$MACOS_MIN_VERSION"
fi

log "building WebGPU plugin for $target"
build_args=(
  "$ORT_SOURCE_DIR/tools/ci_build/build.py"
  --build_dir "$build_dir"
  --config Release
  --parallel "$JOBS"
  --skip_tests
  --build_shared_lib
  --use_vcpkg
  --use_webgpu shared_lib
  --wgsl_template static
  --disable_rtti
)
if [ "$target" = "linux-arm64" ]; then
  build_args+=(--compile_no_warning_as_error)
else
  build_args+=(--enable_lto)
fi
build_args+=(
  --cmake_generator Ninja
  --cmake_extra_defines "${cmake_defines[@]}"
)
build_log="$build_dir/build.log"
python3 "${build_args[@]}" 2>&1 | tee "$build_log"

if [[ "$target" == macos-* ]]; then
  if grep -Fq "built for newer 'macOS' version" "$build_log"; then
    die "one or more macOS dependencies target a newer version than $MACOS_MIN_VERSION"
  fi

  triplet_arch="${target#macos-}"
  generated_triplet="$build_dir/Release/nortti/$triplet_arch-osx.cmake"
  require_file "$generated_triplet"
  grep -Fqx "set(VCPKG_OSX_DEPLOYMENT_TARGET \"$MACOS_MIN_VERSION\")" "$generated_triplet" ||
    die "generated vcpkg triplet does not target macOS $MACOS_MIN_VERSION"
fi

require_file "$plugin"
require_file "$core"
shopt -s nullglob
case "$target" in
  linux-*) runtime_files=("$build_dir/Release"/libonnxruntime.so*) ;;
  macos-*) runtime_files=("$build_dir/Release"/libonnxruntime.dylib "$build_dir/Release"/libonnxruntime.*.dylib) ;;
esac
shopt -u nullglob
[ "${#runtime_files[@]}" -gt 0 ] || die "no ONNX Runtime core libraries found"
cp -P "$plugin" "${runtime_files[@]}" "$dist_dir/package/"

case "$target" in
  linux-*)
    providers_shared="$build_dir/Release/libonnxruntime_providers_shared.so"
    require_file "$providers_shared"
    cp -P "$providers_shared" "$dist_dir/package/"
    ;;
  macos-*)
    providers_shared="$build_dir/Release/libonnxruntime_providers_shared.dylib"
    [ ! -e "$providers_shared" ] || cp -P "$providers_shared" "$dist_dir/package/"
    ;;
esac

cp "$ORT_SOURCE_DIR/LICENSE" "$dist_dir/package/ONNXRUNTIME-LICENSE"
[ -f "$ORT_SOURCE_DIR/ThirdPartyNotices.txt" ] && cp "$ORT_SOURCE_DIR/ThirdPartyNotices.txt" "$dist_dir/package/"
write_manifest "$dist_dir/package/manifest.env" "$target" "plugin-shared" "WebGPU,CPU"

if [[ "$target" == macos-* ]]; then
  expected_arch="${target#macos-}"
  [ "$expected_arch" != "x64" ] || expected_arch="x86_64"
  while IFS= read -r -d '' library; do
    codesign --force --sign - "$library"
    file "$library" | grep -q "$expected_arch" || die "unexpected macOS binary architecture: $library"
  done < <(find "$dist_dir/package" -type f -name '*.dylib' -print0)
  grep -q '_OrtGetApiBase' < <(nm -gU "$core") || die "ORT core does not export OrtGetApiBase"
  grep -q '_CreateEpFactories' < <(nm -gU "$plugin") || die "WebGPU plugin does not export CreateEpFactories"
  grep -q '_ReleaseEpFactory' < <(nm -gU "$plugin") || die "WebGPU plugin does not export ReleaseEpFactory"

  while IFS= read -r -d '' library; do
    actual_min="$(otool -l "$library" | awk '$1 == "minos" { print $2; exit }')"
    [ "$actual_min" = "$MACOS_MIN_VERSION" ] ||
      die "unexpected macOS deployment target for $library: expected $MACOS_MIN_VERSION, found ${actual_min:-unknown}"
  done < <(find "$dist_dir/package" -type f -name '*.dylib' -print0)
else
  grep -q 'OrtGetApiBase' < <(readelf -Ws "$core") || die "ORT core does not export OrtGetApiBase"
  grep -q 'CreateEpFactories' < <(readelf -Ws "$plugin") || die "WebGPU plugin does not export CreateEpFactories"
  grep -q 'ReleaseEpFactory' < <(readelf -Ws "$plugin") || die "WebGPU plugin does not export ReleaseEpFactory"
  readelf -h "$plugin" >/dev/null

  while IFS= read -r -d '' library; do
    max_glibc="$(readelf --version-info "$library" | grep -oE 'GLIBC_[0-9]+(\.[0-9]+)+' | sed 's/^GLIBC_//' | sort -Vu | tail -1 || true)"
    max_glibcxx="$(readelf --version-info "$library" | grep -oE 'GLIBCXX_[0-9]+(\.[0-9]+)+' | sed 's/^GLIBCXX_//' | sort -Vu | tail -1 || true)"
    if [ -n "$max_glibc" ] && [ "$(printf '%s\n%s\n' "$max_glibc" "$LINUX_MAX_GLIBC" | sort -V | tail -1)" != "$LINUX_MAX_GLIBC" ]; then
      die "$library requires GLIBC_$max_glibc; maximum allowed is GLIBC_$LINUX_MAX_GLIBC"
    fi
    if [ -n "$max_glibcxx" ] && [ "$(printf '%s\n%s\n' "$max_glibcxx" "$LINUX_MAX_GLIBCXX" | sort -V | tail -1)" != "$LINUX_MAX_GLIBCXX" ]; then
      die "$library requires GLIBCXX_$max_glibcxx; maximum allowed is GLIBCXX_$LINUX_MAX_GLIBCXX"
    fi
  done < <(find "$dist_dir/package" -type f -name '*.so*' -print0)
fi

asset="$dist_dir/onnxruntime-webgpu-$target-$ORT_VERSION-pilot.$PACKAGE_REVISION.tar.gz"
tar -C "$dist_dir/package" -czf "$asset" .
write_checksum "$asset"
cp "$dist_dir/package/manifest.env" "$asset.manifest.env"
log "created $asset"
