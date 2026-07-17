# Custom ONNX Runtime Packaging

Builds pinned, self-contained ONNX Runtime packages for Android, iOS, and desktop without depending on Microsoft-provided binaries.

Current build: **ONNX Runtime 1.27.0** from upstream tag `v1.27.0`. Version and toolchain pins are defined in [`versions.env`](versions.env).

## What This Produces

| Platform | Architectures | Contents |
| --- | --- | --- |
| Android | arm64-v8a, armeabi-v7a, x86_64 | API 24+ ABI-specific and universal AARs with ORT, Java/JNI, WebGPU, XNNPACK, and CPU fallback |
| iOS | ARM64 | Static XCFramework with ORT, CoreML, and CPU fallback; deployment target 15.1 |
| Linux | x64, ARM64 | ORT shared runtime and WebGPU plugin; Ubuntu 22.04-compatible ABI |
| macOS | Intel x64, Apple Silicon ARM64 | ORT shared runtime with CoreML and CPU fallback; deployment target 13.3 |
| Windows | x64, ARM64 | ORT runtime, WebGPU plugin, and required DXC DLLs |

The Android AAR packages WebGPU into the runtime and replaces `onnxruntime-android`. The iOS artifact replaces the official C XCFramework and requires linking `Foundation`, weak-linking `CoreML`, and linking `c++`. Linux and Windows archives contain a matching ORT core and WebGPU plugin built from the same source revision. Register the plugin and select its device through ORT's V2 device API or automatic device selection; the legacy built-in WebGPU registration API does not load plugin EPs. macOS archives instead contain CoreML built directly into the ORT core and do not include WebGPU. Windows applications must provide the standard Microsoft Visual C++ 2015–2022 runtime, as required by Microsoft's official ORT binaries too.

Do not mix these packages with another ONNX Runtime build.

## Repository Layout

- `versions.env`: ONNX Runtime and toolchain pins
- `config/`: Android and iOS build configurations
- `scripts/`: platform build and packaging entrypoints
- `patches/`: reviewable upstream build and runtime-compatibility patches
- `tests/`: portable packaged-runtime inference smoke tests
- `.github/workflows/release.yml`: native build and release matrix

Generated files are written to `build/` and `dist/`, which are ignored by Git.

## CI And Releases

The release workflow builds all targets on native GitHub-hosted runners. Android ABIs are built separately and then merged into a universal AAR. iOS is distributed as a static XCFramework for Apple Silicon development hosts and ARM64 devices; Intel iOS Simulator hosts are not supported.

```sh
gh workflow run release.yml \
  --repo laurens-pilot/ort-packaging \
  -f tag=ort-1.27.0-webgpu-pilot.6 \
  -f ort_ref=v1.27.0 \
  -f prerelease=true \
  -f scope=all
```

Use `scope=windows` for a Windows-only build probe. Probe runs do not publish releases.

Release tags are immutable. GitHub release immutability must be enabled under **Settings → General → Releases** before starting a release; the workflow verifies the published release is immutable. Packaging-only changes increment `PACKAGE_REVISION` in `versions.env`.

## Release Verification

Every binary asset includes:

- a `.sha256` checksum;
- a `.manifest.env` file identifying the ORT source and target.

The release also includes `SHA256SUMS`. CI verifies all checksums and manifests before publishing. Custom-built release binaries are stripped of or packaged without debug symbol data; Linux and Android builds additionally reject symbol tables and executable stacks. The pinned, Microsoft-signed DXC DLLs remain byte-for-byte identical to their verified upstream archive. Binary archives include the ONNX Runtime license and third-party notices; Android AARs store them under `META-INF/`. Windows archives also include the four license files shipped with the pinned DXC runtime.

Example:

```sh
tag=ort-1.27.0-webgpu-pilot.6
asset=onnxruntime-webgpu-android-1.27.0-pilot.6.aar
base=https://github.com/laurens-pilot/ort-packaging/releases/download/$tag

curl -fL -o "$asset" "$base/$asset"
curl -fL -o "$asset.sha256" "$base/$asset.sha256"
printf '%s  %s\n' "$(cat "$asset.sha256")" "$asset" | sha256sum -c -
```

Always pin an immutable release tag and checksum downstream.

## Validation Scope

CI verifies package structure, native architectures, required exports, Android JNI contents, checksums, and packaged runtime loading. It runs CPU and WebGPU inference on native Linux and Windows x64/ARM64 runners, using Mesa's software Vulkan driver on Linux and D3D12 on Windows. It runs CPU and CoreML inference on native macOS x64/ARM64 runners and in an ARM64 iOS Simulator, plus packaged CPU inference in an Android x86_64 emulator. Hosted Android emulators cannot exercise WebGPU without a host GPU. Android WebGPU, Android ARM device ABIs, and the iOS device slice receive structural validation; representative physical-device testing remains a downstream release criterion.

Releases remain prereleases until representative-device correctness and performance testing is completed downstream.

ONNX Runtime and bundled third-party components retain their upstream licenses. Runtime archives include the applicable license and notices.
