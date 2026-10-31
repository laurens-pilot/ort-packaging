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

cmake_defines=(
  "onnxruntime_BUILD_UNIT_TESTS=OFF"
  "onnxruntime_USE_TELEMETRY=OFF"
)
case "$target" in
  linux-*)
    cmake_defines+=(
      "onnxruntime_ENABLE_DAWN_BACKEND_VULKAN=1"
      "CMAKE_SHARED_LINKER_FLAGS=-Wl,-z,noexecstack"
      "CMAKE_MODULE_LINKER_FLAGS=-Wl,-z,noexecstack"
    )
    plugin="$build_dir/Release/libonnxruntime_providers_webgpu.so"
    core="$build_dir/Release/libonnxruntime.so.$ORT_VERSION"
    ;;
  macos-x64)
    cmake_defines+=("CMAKE_OSX_ARCHITECTURES=x86_64" "CMAKE_OSX_DEPLOYMENT_TARGET=$MACOS_MIN_VERSION")
    core="$build_dir/Release/libonnxruntime.$ORT_VERSION.dylib"
    ;;
  macos-arm64)
    cmake_defines+=("CMAKE_OSX_ARCHITECTURES=arm64" "CMAKE_OSX_DEPLOYMENT_TARGET=$MACOS_MIN_VERSION")
    core="$build_dir/Release/libonnxruntime.$ORT_VERSION.dylib"
    ;;
esac

if [[ "$target" == macos-* ]]; then
  require_cmd strip
  # ORT's build.py reads this when generating its vcpkg overlay triplets. A
  # top-level -DVCPKG_OSX_DEPLOYMENT_TARGET does not configure vcpkg ports.
  export MACOSX_DEPLOYMENT_TARGET="$MACOS_MIN_VERSION"
fi

provider_args=()
if [[ "$target" == linux-* ]]; then
  provider_args+=(--use_webgpu shared_lib --wgsl_template static)
  log "building ORT core and WebGPU plugin for $target"
else
  provider_args+=(--use_coreml)
  log "building ORT core with CoreML for $target"
fi

build_args=(
  "$ORT_SOURCE_DIR/tools/ci_build/build.py"
  --build_dir "$build_dir"
  --config Release
  --parallel "$JOBS"
  --skip_tests
  --build_shared_lib
  --use_vcpkg
  "${provider_args[@]}"
  --disable_rtti
)
if ort_supports_no_telemetry; then
  build_args+=(--no_telemetry)
fi
if [[ "$target" == linux-* ]] && [ "$EUID" -eq 0 ]; then
  build_args+=(--allow_running_as_root)
fi
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
verify_ort_telemetry_disabled "$build_dir"

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

require_file "$core"
if [[ "$target" == linux-* ]]; then
  require_file "$plugin"
fi
shopt -s nullglob
case "$target" in
  linux-*) runtime_files=("$build_dir/Release"/libonnxruntime.so*) ;;
  macos-*) runtime_files=("$build_dir/Release"/libonnxruntime.dylib "$build_dir/Release"/libonnxruntime.*.dylib) ;;
esac
shopt -u nullglob
[ "${#runtime_files[@]}" -gt 0 ] || die "no ONNX Runtime core libraries found"
if [[ "$target" == linux-* ]]; then
  cp -P "$plugin" "${runtime_files[@]}" "$dist_dir/package/"
else
  cp -P "${runtime_files[@]}" "$dist_dir/package/"
fi

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
if [[ "$target" == linux-* ]]; then
  write_manifest "$dist_dir/package/manifest.env" "$target" "plugin-shared" "WebGPU,CPU"
else
  write_manifest "$dist_dir/package/manifest.env" "$target" "disabled" "CoreML,CPU"
fi

if [[ "$target" == macos-* ]]; then
  if find "$dist_dir/package" -type f -iname '*webgpu*' -print -quit | grep -q .; then
    die "macOS package unexpectedly contains a WebGPU component"
  fi

  expected_arch="${target#macos-}"
  [ "$expected_arch" != "x64" ] || expected_arch="x86_64"
  while IFS= read -r -d '' library; do
    strip -S "$library"
    if otool -l "$library" | grep -Fq 'segname __DWARF'; then
      die "macOS runtime still contains DWARF sections after stripping: $library"
    fi
    codesign --force --sign - "$library"
    file "$library" | grep -q "$expected_arch" || die "unexpected macOS binary architecture: $library"
  done < <(find "$dist_dir/package" -type f -name '*.dylib' -print0)

  packaged_core="$dist_dir/package/$(basename "$core")"
  symbols_file="$build_dir/packaged-core-symbols.txt"
  require_file "$packaged_core"
  nm -gU "$packaged_core" >"$symbols_file"
  grep -Fq '_OrtGetApiBase' "$symbols_file" || die "ORT core does not export OrtGetApiBase"
  grep -Fq '_OrtSessionOptionsAppendExecutionProvider_CoreML' "$symbols_file" ||
    die "ORT core does not include CoreML EP"

  if grep -Fq -- '-Wunguarded-availability-new' "$build_log"; then
    die "macOS build emitted an unguarded runtime availability warning"
  fi

  while IFS= read -r -d '' library; do
    actual_min="$(otool -l "$library" | awk '$1 == "minos" { print $2; exit }')"
    [ "$actual_min" = "$MACOS_MIN_VERSION" ] ||
      die "unexpected macOS deployment target for $library: expected $MACOS_MIN_VERSION, found ${actual_min:-unknown}"
  done < <(find "$dist_dir/package" -type f -name '*.dylib' -print0)
else
  require_cmd readelf
  require_cmd strip
  while IFS= read -r -d '' library; do
    strip --strip-unneeded "$library"
    if readelf -W -S "$library" | grep -Eq '] \.(debug|zdebug|gnu_debuglink|symtab)([[:space:]]|_)'; then
      die "Linux runtime still contains debug or symbol-table sections after stripping: $library"
    fi

    stack_header="$(readelf -W -l "$library" | awk '$1 == "GNU_STACK" { print; exit }')"
    [ -n "$stack_header" ] || die "Linux runtime has no GNU_STACK header: $library"
    [[ "$stack_header" != *E* ]] || die "Linux runtime requests an executable stack: $library"
  done < <(find "$dist_dir/package" -type f -name '*.so*' -print0)

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

if [[ "$target" == macos-* ]]; then
  asset="$dist_dir/onnxruntime-coreml-$target-$ORT_VERSION-$(package_label).tar.gz"
else
  asset="$dist_dir/onnxruntime-webgpu-$target-$ORT_VERSION-$(package_label).tar.gz"
fi
tar -C "$dist_dir/package" -czf "$asset" .
write_checksum "$asset"
cp "$dist_dir/package/manifest.env" "$asset.manifest.env"
log "created $asset"
