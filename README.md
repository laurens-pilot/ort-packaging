# Custom ONNX Runtime Packaging

Builds pinned, self-contained ONNX Runtime runtime packages for Android, iOS, Linux, macOS, and Windows without consuming Microsoft-provided ONNX Runtime binaries. Shared toolchain and platform policy lives in [`build.env`](build.env); each release build resolves its requested upstream tag to an immutable commit.

This repository's release tags describe a **custom packaging** of upstream ONNX Runtime, not an upstream Microsoft release. Stable package revisions are named `ort-<upstream-version>-r<revision>`. See [Releases](https://github.com/ente/ort-packaging/releases) for available versions and assets.

## Release process

A routine ONNX Runtime release requires no repository changes. Do not edit `build.env` to select an ONNX Runtime version; change it only when the shared build policy or toolchain must change.

Prerequisites:

- The exact packaging code to release is on `main`.
- The **Validate** workflow for that `main` commit succeeded.

### 1. Check compatibility before merging

The **Validate** workflow runs static checks and offline negative tests. **Platform preflight** checks the last shipped source against native compilers, CMake, Apple SDKs and Android setup on upstream PRs and every Monday. It does not compile ONNX Runtime. It can also be dispatched with an explicit new ORT version.

For a full branch trial, dispatch **Build release candidate** with **Mode: trial**, choose a platform or all platforms, and enter the ORT version. Trials may reuse an existing package revision. They use the same platform scripts as release builds and never assemble a publishable candidate. Normal release builds retain **Mode: release**, **Platform: all**, and **Branch: main**.

### 2. Build a release candidate

Open [Build release candidate](https://github.com/ente/ort-packaging/actions/workflows/build.yml), select **Run workflow**, and use:

- **Mode:** `release`
- **Platform:** `all`
- **Branch:** `main`
- **ORT version:** the stable upstream version without a `v` prefix, such as `1.28.1`
- **Package revision:** `1` for the first package of that ORT version; use the next integer only to correct the packaging. Revisions must be sequential.

The equivalent CLI command is:

```sh
gh workflow run build.yml \
  --repo ente/ort-packaging \
  --ref main \
  -f ort_version=1.28.1 \
  -f package_revision=1
```

The workflow verifies the upstream release, resolves its tag to a commit, applies the repository patches, and builds and tests every package. The candidate is ready only when **Assemble release candidate** succeeds. Candidates expire after 14 days.

### 3. Complete physical-device validation

Download the successful run's release-candidate artifact and check out the packaging commit in its provenance. Run the reusable device harness from the repository root with Python 3.12 or newer. Choose an external work directory for generated files. Android needs a configured SDK/NDK, Java, CMake and Ninja; iOS needs Xcode and the signing identity, provisioning profile and entitlements for the smoke app's bundle ID.

```sh
python3 scripts/validate-device.py /path/to/candidate \
  --platform android --device ANDROID_SERIAL \
  --description 'Device model, Android version and GPU' \
  --work-dir /external/work/android --evidence /path/to/device-evidence.json

export IOS_SIGNING_IDENTITY='Apple Development: ...'
export IOS_PROVISIONING_PROFILE=/path/to/smoke.mobileprovision
export IOS_ENTITLEMENTS=/path/to/smoke.entitlements
python3 scripts/validate-device.py /path/to/candidate \
  --platform ios --device IPHONE_UDID \
  --description 'Device model and iOS version' \
  --work-dir /external/work/ios --evidence /path/to/device-evidence.json
```

Android acceptance exercises the universal AAR's ARM64 runtime and Java/JNI loading. Both native harnesses require provider execution without CPU fallback and repeat session creation. The evidence records the exact tested archive hashes; representative Android acceptance does not claim that every Android ABI was executed. Use a fresh evidence file for each candidate.

If Windows CI reports no WebGPU device, run the same helper on a GPU-capable Windows machine with `--platform windows-x64` or `windows-arm64`. Supply a local machine identifier through `--device` and include its OS/GPU in `--description`; CMake and the matching Visual Studio generator must be available. Publication requires Android and iOS device results and any Windows GPU results missing from CI.

### 4. Publish the candidate

Copy the numeric run ID from the successful candidate build. Open [Publish release](https://github.com/ente/ort-packaging/actions/workflows/publish.yml), select **Run workflow** on `main`, and enter that ID. Paste the generated device-evidence JSON into **Device evidence**.

The equivalent CLI command is:

```sh
gh workflow run publish.yml \
  --repo ente/ort-packaging \
  --ref main \
  -f build_run_id=123456789 \
  -f device_evidence="$(cat /path/to/device-evidence.json)"
```

Publication accepts only a successful `build.yml` run from this repository's `main` branch. It revalidates the candidate provenance, checksums, upstream commit, package revision, and target tag before creating an immutable release from the exact packaging commit that produced the candidate. If the candidate expired, run a new build instead.

### 5. Verify the published release

Confirm that the release:

- uses the tag `ort-<ORT version>-r<package revision>`;
- is immutable and contains 35 assets;
- includes 11 packages, their 11 checksum sidecars, their 11 manifests, `SHA256SUMS`, and `build-provenance.json`;
- passes `sha256sum -c SHA256SUMS` after download.

Verify the release attestation with `gh release verify <tag> --repo ente/ort-packaging`. Never replace or retag an existing release. Create the next package revision instead.

## Packages

| Platform | Architectures | Asset family | Contents |
| --- | --- | --- | --- |
| Android | arm64-v8a, armeabi-v7a, x86_64 | `onnxruntime-webgpu-android-*` | API 24+ ABI-specific and universal AARs with ORT, Java/JNI, built-in WebGPU, XNNPACK, and CPU fallback |
| iOS | ARM64 device and Apple Silicon Simulator | `onnxruntime-coreml-ios-*` | Static-library XCFramework with CoreML and CPU; deployment target 15.1 |
| Linux | x64, ARM64 | `onnxruntime-webgpu-linux-*` | GLIBC 2.28-compatible ORT runtime plus a shared WebGPU plugin |
| macOS | Intel x64, Apple Silicon ARM64 | `onnxruntime-coreml-macos-*` | CoreML-enabled ORT runtime with CPU fallback; deployment target 13.3; no WebGPU plugin |
| Windows | x64, ARM64 | `onnxruntime-webgpu-windows-*` | ORT runtime, WebGPU plugin, required DXC DLLs, and DXC licences |

The provider in an asset name is intentional: Android/Linux/Windows support WebGPU, while Apple packages intentionally use CoreML rather than WebGPU. Do not mix a packaged runtime, plugin, or headers with another ONNX Runtime build.

Telemetry is compiled out of every package. Every build explicitly sets `onnxruntime_USE_TELEMETRY=OFF`, uses ONNX Runtime's `--no_telemetry` option when that release supports it, and rejects generated CMake configurations unless telemetry is disabled.

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
- `config/`: platform build templates, package contracts, pinned tool downloads, patches and warning exceptions
- `scripts/`: workflow implementation helpers for platform builds, packaging, and packaged-runtime smoke tests
- `patches/`: reviewable upstream compatibility patches; see [`PATCHES.md`](PATCHES.md)
- `tests/`: portable packaged-runtime inference smoke tests
- [`RELEASE-CHECKLIST.md`](RELEASE-CHECKLIST.md): required stable-release promotion steps
- `.github/workflows/build.yml`: version-driven native build and release-candidate assembly
- `.github/workflows/publish.yml`: immutable publication of one successful build run

The build helpers under `scripts/` are workflow implementation details. `validate-device.py` is the supported entry point for local candidate acceptance. The release workflow supplies their resolved metadata and writes to `.build/` and `.dist/`; local fallback directories `build/` and `dist/` are also ignored by Git.

## Build and validation design

The build workflow builds every target on its native GitHub-hosted runner. Linux compilation runs in checksum-pinned PyPA `manylinux_2_28` job containers on native x64 and ARM64 hosts, decoupling the package ABI from the GitHub runner image. Android ABIs are built independently and merged into a universal AAR. iOS is distributed for ARM64 devices and Apple Silicon Simulator hosts; Intel Simulator hosts are not supported. Its XCFramework contains ordinary `libonnxruntime.a` slices and public headers, so Swift Package Manager and consumers that link the archive directly use the same single copy of the machine code.

## Verification and provenance

Every binary asset includes a `.sha256` checksum and `.manifest.env` file. Manifests record the upstream ref and commit, packaging commit, telemetry policy, package channel/revision/label, target, provider topology, and build configuration. The release also includes `SHA256SUMS` and `build-provenance.json`.

Custom-built binaries are stripped of or packaged without debug-symbol data. Linux and Android builds additionally reject debug/symbol-table sections and executable stacks. Archives contain the ONNX Runtime licence and third-party notices; Android AARs store them under `META-INF/`. Windows archives include the licence files shipped with the pinned DXC runtime.

Always pin a release tag and verify its checksum sidecar downstream.

## Validation scope

CI verifies final archive structure, native architectures, required exports, checksums, provenance metadata, and packaged runtime loading. It requires CPU and WebGPU inference on Linux x64/ARM64 using Mesa's software Vulkan driver. Windows x64/ARM64 requires CPU inference and plugin registration; WebGPU execution is reported separately and may be skipped when a runner has no device. macOS and the iOS Simulator require CoreML execution without CPU fallback. Android x86_64 runs packaged CPU and Java/JNI inference in an emulator. Numeric checks reject NaN and infinity.

Each candidate keeps the existing 35-asset contract. Its versioned provenance embeds archive-bound validation results, compiler/toolchain identities and patch statuses. The publisher checks candidate/run identities, the exact asset set, all manifest fields, checksums and physical-device evidence before publication. Device evidence is retained as a publication-workflow artifact for 90 days. Trial artifacts are never accepted as release candidates.

Hosted Android emulators cannot exercise WebGPU without a host GPU. Android WebGPU and Android ARM device ABIs require representative physical-device validation before a stable release; iOS device-slice and vendor-GPU performance validation are also downstream release criteria. Smoke tests prove runtime loading and basic provider inference, not application-specific operator coverage or performance.

ONNX Runtime and bundled third-party components retain their upstream licences. Runtime archives include the applicable licence and notices.

## Compatibility policy

The last shipped source and the next requested stable release are the compatibility checkpoints. Version-independent dispatch does not guarantee that future upstream source compiles without a reviewed compatibility change. Patch conditions and removal criteria live in `config/patches.json`. Known ARM64 warning exceptions are constrained by target, source path, diagnostic and the pinned dependency/source fingerprint in `config/warnings.json`; every other compiler diagnostic fails validation. Reassess these exceptions on an upstream or compiler upgrade. Disabling KleidiAI and Linux ARM64 LTO remains an explicit existing platform tradeoff, not an automatically restored optimization.

Pinned CMake/vcpkg installation is shared by preflight and package builds. Ccache is not downloaded while compilation caching is disabled. Only verified downloads are retried; failed Android builds are not automatically repeated.
