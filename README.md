# Custom ONNX Runtime Packaging

Builds pinned, self-contained ONNX Runtime runtime packages for Android, iOS, Linux, macOS, and Windows without consuming Microsoft-provided ONNX Runtime binaries. Shared toolchain and platform policy lives in [`build.env`](build.env); each release build resolves its requested upstream tag to an immutable commit.

This repository's release tags describe a **custom packaging** of upstream ONNX Runtime, not an upstream Microsoft release. Stable package revisions are named `ort-<upstream-version>-r<revision>`. See [Releases](https://github.com/ente/ort-packaging/releases) for available versions and assets.

## Packages

| Platform | Architectures | Asset family | Contents |
| --- | --- | --- | --- |
| Android | arm64-v8a, armeabi-v7a, x86_64 | `onnxruntime-webgpu-android-*` | API 24+ ABI-specific and universal AARs with ORT, Java/JNI, built-in WebGPU, XNNPACK, and CPU fallback |
| iOS | ARM64 device and Apple Silicon Simulator | `onnxruntime-coreml-ios-*` | Static-library XCFramework with CoreML and CPU; deployment target 15.1 |
| Linux | x64, ARM64 | `onnxruntime-webgpu-linux-*` | GLIBC 2.28-compatible ORT runtime plus a shared WebGPU plugin |
| macOS | Intel x64, Apple Silicon ARM64 | `onnxruntime-coreml-macos-*` | CoreML-enabled ORT runtime with CPU fallback; deployment target 13.3; no WebGPU plugin |
| Windows | x64, ARM64 | `onnxruntime-webgpu-windows-*` | ORT runtime, WebGPU plugin, required DXC DLLs, and DXC licences |

The provider in an asset name is intentional: Android/Linux/Windows support WebGPU, while Apple packages intentionally use CoreML rather than WebGPU. Do not mix a packaged runtime, plugin, or headers with another ONNX Runtime build.

Telemetry is compiled out of every package. Platform build jobs pass ONNX Runtime's `--no_telemetry` option and reject generated CMake configurations unless `onnxruntime_USE_TELEMETRY=OFF`, so an upstream default change cannot silently enable telemetry in a future release.

## Consumer requirements

- Android: the AAR has a package minimum of API 24. WebGPU still depends on the physical device's Android/Vulkan GPU support; CPU and XNNPACK remain fallbacks.
- iOS: link `Foundation`, weak-link `CoreML`, and link `c++`. CPU and standard CoreML usage support iOS 15.1. CoreML float16 inputs and ANE-only execution require iOS 16+, while CoreML specialization strategies require iOS 18+ and fail with a clear runtime error on older systems.
- macOS: link `Foundation`, weak-link `CoreML`, and target macOS 13.3+. CoreML is built into the core runtime; there is no WebGPU plugin to register.
- Linux: install a compatible Vulkan loader and driver for WebGPU. The package ABI supports Ubuntu 20.04 and newer (GLIBC 2.28 maximum, GLIBCXX 3.4.28 maximum), but GPU-driver correctness and performance remain environment-specific.
- Windows: install the Microsoft Visual C++ 2015–2022 runtime, as required by Microsoft's own ONNX Runtime binaries. Keep the DXC DLLs that ship in the archive beside the ORT runtime and WebGPU plugin.

iOS frameworks include their public headers. Linux, macOS, and Windows archives are runtime packages: C/C++ consumers should obtain the matching public headers from the pinned upstream source revision (or vendor them with their own build) rather than mixing headers from another ORT version.

For Linux and Windows, register the shared WebGPU plugin and select an EP device through ORT's V2 device API or automatic device selection. The legacy built-in WebGPU registration API does not load plugin EPs.

## Repository layout

- `build.env`: shared toolchain, deployment-target, ABI, and telemetry policy
- `config/`: Android and iOS build configurations
- `scripts/`: workflow implementation helpers for platform builds, packaging, and packaged-runtime smoke tests
- `patches/`: reviewable upstream compatibility patches; see [`PATCHES.md`](PATCHES.md)
- `tests/`: portable packaged-runtime inference smoke tests
- [`RELEASE-CHECKLIST.md`](RELEASE-CHECKLIST.md): required stable-release promotion steps
- `.github/workflows/build.yml`: version-driven native build and release-candidate assembly
- `.github/workflows/publish.yml`: immutable publication of one successful build run

The build and smoke-test helpers under `scripts/` are workflow implementation details, not supported standalone release commands. The release workflow supplies their resolved metadata and writes to `.build/` and `.dist/`; local fallback directories `build/` and `dist/` are also ignored by Git.

## CI and releases

The build workflow builds every target on its native GitHub-hosted runner. Linux compilation runs in checksum-pinned PyPA `manylinux_2_28` job containers on native x64 and ARM64 hosts, decoupling the package ABI from the GitHub runner image. Android ABIs are built independently and merged into a universal AAR. iOS is distributed for ARM64 devices and Apple Silicon Simulator hosts; Intel Simulator hosts are not supported. Its XCFramework contains ordinary `libonnxruntime.a` slices and public headers, so Swift Package Manager and consumers that link the archive directly use the same single copy of the machine code.

### Publishing a release

No repository file needs a version bump for a routine upstream release. Leave `build.env` unchanged unless shared build policy or toolchain pins need to change.

In GitHub Actions, run **Build release candidate** from `main` and enter the stable upstream version. The package revision defaults to `1`; enter `2` or higher only for a packaging correction. The CLI equivalent is:

```sh
ort_version=X.Y.Z
gh workflow run build.yml \
  --repo ente/ort-packaging \
  --ref main \
  -f "ort_version=$ort_version"
```

The workflow verifies that the corresponding Microsoft release is published and stable, pins its tag to a full commit, checks the repository patches, and builds and tests every target. When it succeeds, run **Publish release** with the build run ID shown in the summary. The equivalent CLI command is:

```sh
build_run_id=123456789
gh workflow run publish.yml \
  --repo ente/ort-packaging \
  --ref main \
  -f "build_run_id=$build_run_id"
```

Publication accepts only a successful `build.yml` run from `main`, revalidates its provenance and checksums, and tags the exact packaging commit used by that build. Candidate artifacts expire after 14 days. Rebuild if the candidate has expired.

## Verification and provenance

Every binary asset includes a `.sha256` checksum and `.manifest.env` file. Manifests record the upstream ref and commit, packaging commit, telemetry policy, package channel/revision/label, target, provider topology, and build configuration. The release also includes `SHA256SUMS` and `build-provenance.json`.

Custom-built binaries are stripped of or packaged without debug-symbol data. Linux and Android builds additionally reject debug/symbol-table sections and executable stacks. Archives contain the ONNX Runtime licence and third-party notices; Android AARs store them under `META-INF/`. Windows archives include the licence files shipped with the pinned DXC runtime.

Always pin a release tag and verify its checksum sidecar downstream.

## Validation scope

CI verifies package structure, native architectures, required exports, Android JNI contents, checksums, provenance metadata, and packaged runtime loading. It runs CPU and WebGPU inference on native Linux and Windows x64/ARM64 runners, using Mesa's software Vulkan driver on Linux and D3D12 on Windows. It runs CPU and CoreML inference on native macOS x64/ARM64 runners and in an ARM64 iOS Simulator, plus packaged CPU inference in an Android x86_64 emulator.

Hosted Android emulators cannot exercise WebGPU without a host GPU. Android WebGPU and Android ARM device ABIs require representative physical-device validation before a stable release; iOS device-slice and vendor-GPU performance validation are also downstream release criteria. Smoke tests prove runtime loading and basic provider inference, not application-specific operator coverage or performance.

ONNX Runtime and bundled third-party components retain their upstream licences. Runtime archives include the applicable licence and notices.
