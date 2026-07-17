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
    require_webgpu=0
    backend=Vulkan
    ;;
  macos-*)
    core="$package_dir/libonnxruntime.$ORT_VERSION.dylib"
    plugin="$package_dir/libonnxruntime_providers_webgpu.dylib"
    require_webgpu=1
    backend=-
    ;;
esac
require_file "$core"
require_file "$plugin"

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
  "$test_build_dir/runtime-smoke" "$core" "$plugin" "$model" "$require_webgpu" "$backend"
)
