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

require_cmd cmake
package_dir="$DIST_ROOT/$target/package"
test_build_dir="$BUILD_ROOT/$target-runtime-smoke"
model="$ORT_SOURCE_DIR/onnxruntime/test/testdata/mul_1.onnx"
headers="$ORT_SOURCE_DIR/include/onnxruntime/core/session"
require_dir "$package_dir"
require_file "$model"
require_dir "$headers"

case "$target" in
  linux-*)
    core="$package_dir/libonnxruntime.so.$ORT_VERSION"
    plugin="$package_dir/libonnxruntime_providers_webgpu.so"
    provider_spec="$plugin"
    require_webgpu=1
    backend=Vulkan

    lavapipe_icd="$(find /usr/share/vulkan/icd.d -maxdepth 1 -type f -name 'lvp_icd*.json' -print -quit)"
    require_file "$lavapipe_icd"
    export VK_DRIVER_FILES="$lavapipe_icd"
    ;;
  macos-*)
    core="$package_dir/libonnxruntime.$ORT_VERSION.dylib"
    provider_spec=builtin:CoreML
    require_webgpu=0
    backend=-
    ;;
esac
require_file "$core"
if [[ "$target" == linux-* ]]; then
  require_file "$plugin"
fi

rm -rf "$test_build_dir"
cmake -S "$REPO_ROOT/tests" -B "$test_build_dir" \
  -DCMAKE_BUILD_TYPE=Release \
  -DORT_INCLUDE_DIR="$headers"
cmake --build "$test_build_dir" --parallel "$JOBS"

if [[ "$target" == linux-* ]]; then
  export LD_LIBRARY_PATH="$package_dir${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
else
  export DYLD_LIBRARY_PATH="$package_dir${DYLD_LIBRARY_PATH:+:$DYLD_LIBRARY_PATH}"
fi

(
  cd "$package_dir"
  "$test_build_dir/runtime-smoke" "$core" "$provider_spec" "$model" "$require_webgpu" "$backend"
)
