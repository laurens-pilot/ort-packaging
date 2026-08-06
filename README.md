# Custom ONNX Runtime Packaging

Builds pinned, self-contained ONNX Runtime runtime packages for Android, iOS, Linux, macOS, and Windows without consuming Microsoft-provided ONNX Runtime binaries. The current upstream base is **ONNX Runtime 1.28.0** from `v1.28.0`; package-channel and toolchain pins live in [`versions.env`](versions.env).

This repository's release tags describe a **custom packaging** of upstream ONNX Runtime, not an upstream Microsoft release. A stable package revision is named `ort-<upstream-version>-r<revision>`; the first stable 1.28 release is therefore `ort-1.28.0-r1`.

## Packages

| Platform | Architectures | Asset family | Contents |
| --- | --- | --- | --- |
| Android | arm64-v8a, armeabi-v7a, x86_64 | `onnxruntime-webgpu-android-*` | API 24+ ABI-specific and universal AARs with ORT, Java/JNI, built-in WebGPU, XNNPACK, and CPU fallback |
| iOS | ARM64 device and Apple Silicon Simulator | `onnxruntime-coreml-ios-*` | Static-library XCFramework with CoreML and CPU; deployment target 15.1 |
| Linux | x64, ARM64 | `onnxruntime-webgpu-linux-*` | GLIBC 2.28-compatible ORT runtime plus a shared WebGPU plugin |
| macOS | Intel x64, Apple Silicon ARM64 | `onnxruntime-coreml-macos-*` | CoreML-enabled ORT runtime with CPU fallback; deployment target 13.3; no WebGPU plugin |
| Windows | x64, ARM64 | `onnxruntime-webgpu-windows-*` | ORT runtime, WebGPU plugin, required DXC DLLs, and DXC licences |

The provider in an asset name is intentional: Android/Linux/Windows support WebGPU, while Apple packages intentionally use CoreML rather than WebGPU. Do not mix a packaged runtime, plugin, or headers with another ONNX Runtime build.

## Consumer requirements

- Android: the AAR has a package minimum of API 24. WebGPU still depends on the physical device's Android/Vulkan GPU support; CPU and XNNPACK remain fallbacks.
- iOS: link `Foundation`, weak-link `CoreML`, and link `c++`. CPU and standard CoreML usage support iOS 15.1. CoreML float16 inputs and ANE-only execution require iOS 16+, while CoreML specialization strategies require iOS 18+ and fail with a clear runtime error on older systems.
- macOS: link `Foundation`, weak-link `CoreML`, and target macOS 13.3+. CoreML is built into the core runtime; there is no WebGPU plugin to register.
- Linux: install a compatible Vulkan loader and driver for WebGPU. The package ABI supports Ubuntu 20.04 and newer (GLIBC 2.28 maximum, GLIBCXX 3.4.28 maximum), but GPU-driver correctness and performance remain environment-specific.
- Windows: install the Microsoft Visual C++ 2015–2022 runtime, as required by Microsoft's own ONNX Runtime binaries. Keep the DXC DLLs that ship in the archive beside the ORT runtime and WebGPU plugin.

iOS frameworks include their public headers. Linux, macOS, and Windows archives are runtime packages: C/C++ consumers should obtain the matching public headers from the pinned upstream source revision (or vendor them with their own build) rather than mixing headers from another ORT version.

For Linux and Windows, register the shared WebGPU plugin and select an EP device through ORT's V2 device API or automatic device selection. The legacy built-in WebGPU registration API does not load plugin EPs.

## Repository layout

- `versions.env`: upstream version, release channel/revision, and toolchain pins
- `config/`: Android and iOS build configurations
- `scripts/`: platform build, packaging, and packaged-runtime smoke-test entrypoints
- `patches/`: reviewable upstream compatibility patches; see [`PATCHES.md`](PATCHES.md)
- `tests/`: portable packaged-runtime inference smoke tests
- [`RELEASE-CHECKLIST.md`](RELEASE-CHECKLIST.md): required stable-release promotion steps
- `.github/workflows/release.yml`: native build and immutable-release matrix

Local scripts write to `build/` and `dist/` by default. CI sets the equivalent hidden directories `.build/` and `.dist/`; all four are ignored by Git.

## CI and releases

The release workflow builds every target on its native GitHub-hosted runner. Linux compilation runs in checksum-pinned PyPA `manylinux_2_28` job containers on native x64 and ARM64 hosts, decoupling the package ABI from the GitHub runner image. Android ABIs are built independently and merged into a universal AAR. iOS is distributed for ARM64 devices and Apple Silicon Simulator hosts; Intel Simulator hosts are not supported. Its XCFramework contains ordinary `libonnxruntime.a` slices and public headers, so Swift Package Manager and consumers that link the archive directly use the same single copy of the machine code.

For a packaging-only correction, `scope=repackage` can derive a complete release from an existing immutable 35-asset release without recompiling native code. Android binaries are copied byte-for-byte, desktop archives receive updated package manifests, and the iOS static archives are rewrapped with `xcodebuild -create-xcframework`. Every resulting manifest records the source tag, asset name, and SHA-256, and CI runs the iOS CPU/CoreML smoke test against the new package structure.

`versions.env` is the release source of truth. The workflow derives the required tag from `ORT_VERSION`, `PACKAGE_CHANNEL`, and `PACKAGE_REVISION`; a release rejects a mismatched tag, a mismatched prerelease flag, or any ref other than `main` before starting platform builds.

For a Linux-only follow-up that rebuilds Linux while reusing verified non-Linux binaries from the preceding immutable release, first increment `PACKAGE_REVISION`, then dispatch the new tag with its source tag. For example:

```sh
gh workflow run release.yml \
  --repo ente/ort-packaging \
  --ref main \
  -f tag=ort-1.28.0-r2 \
  -f source_tag=ort-1.28.0-r1 \
  -f prerelease=false \
  -f scope=linux
```

Use `scope=all` for a fresh native build of every target, `scope=repackage` for a packaging-only release, or `scope=windows` for a Windows-only probe. The `linux` scope requires a source release, rebuilds and tests both Linux architectures, and reuses the other platforms with per-asset provenance. Probe runs do not publish a release and may omit the tag.

GitHub release immutability must be enabled under **Settings → General → Releases**. The workflow rejects an existing tag and verifies that the completed release is immutable with the expected asset count.

## Verification and provenance

Every binary asset includes a `.sha256` checksum and `.manifest.env` file. Manifests record the upstream ref and commit, packaging commit, package channel/revision/label, target, provider topology, and build configuration. The release also includes `SHA256SUMS` and `build-provenance.json`.

Custom-built binaries are stripped of or packaged without debug-symbol data. Linux and Android builds additionally reject debug/symbol-table sections and executable stacks. Archives contain the ONNX Runtime licence and third-party notices; Android AARs store them under `META-INF/`. Windows archives include the licence files shipped with the pinned DXC runtime.

Example:

```sh
tag=ort-1.28.0-r1
asset=onnxruntime-webgpu-android-1.28.0-r1.aar
base=https://github.com/ente/ort-packaging/releases/download/$tag

curl -fL -o "$asset" "$base/$asset"
curl -fL -o "$asset.sha256" "$base/$asset.sha256"
printf '%s  %s\n' "$(cat "$asset.sha256")" "$asset" | sha256sum -c -
```

Always pin a release tag and checksum downstream.

## Validation scope

CI verifies package structure, native architectures, required exports, Android JNI contents, checksums, provenance metadata, and packaged runtime loading. It runs CPU and WebGPU inference on native Linux and Windows x64/ARM64 runners, using Mesa's software Vulkan driver on Linux and D3D12 on Windows. It runs CPU and CoreML inference on native macOS x64/ARM64 runners and in an ARM64 iOS Simulator, plus packaged CPU inference in an Android x86_64 emulator.

Hosted Android emulators cannot exercise WebGPU without a host GPU. Android WebGPU and Android ARM device ABIs require representative physical-device validation before a stable release; iOS device-slice and vendor-GPU performance validation are also downstream release criteria. Smoke tests prove runtime loading and basic provider inference, not application-specific operator coverage or performance.

ONNX Runtime and bundled third-party components retain their upstream licences. Runtime archives include the applicable licence and notices.
