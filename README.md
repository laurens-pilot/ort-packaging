# ONNX Runtime WebGPU packaging

Reproducible, GitHub-hosted builds of ONNX Runtime's native WebGPU Execution Provider for Android, iOS, Linux, macOS, and Windows. The repository intentionally keeps compilation off developer machines and publishes immutable, checksummed GitHub Release assets.

Runtime and package versions are pinned in [`versions.env`](versions.env); the workflow separately pins Microsoft's ONNX Runtime build-tool action, CMake, and vcpkg. Releases use a separate packaging revision so a script or toolchain correction does not pretend to be a new ONNX Runtime version.

## What is packaged

| Platform | Architectures | Asset model |
| --- | --- | --- |
| Android | arm64-v8a, armeabi-v7a, x86_64 | One merged AAR containing a custom full ONNX Runtime core with WebGPU and XNNPACK built in, plus ABI-specific AARs |
| iOS 16.3+ | arm64 device and arm64 simulator | Static `onnxruntime.xcframework` with WebGPU, CoreML, and XNNPACK built in |
| Linux | x64, ARM64 | `libonnxruntime_providers_webgpu.so` plugin archive |
| macOS | x64, ARM64 | Ad-hoc-signed `libonnxruntime_providers_webgpu.dylib` plugin archive |
| Windows | x64, ARM64 | `onnxruntime_providers_webgpu.dll`, `dxcompiler.dll`, and `dxil.dll` archive |

This split is deliberate. ONNX Runtime's mobile packaging paths statically include providers in the custom core package. Its current WebGPU plugin release pipeline covers desktop shared libraries. A mobile asset therefore replaces the ordinary ONNX Runtime mobile package; it is not an add-on that can be placed beside the stock AAR or CocoaPod. Desktop archives are add-on provider libraries and require a compatible ONNX Runtime core.

## Build and release

The manually dispatched **Build and release** workflow fans out across GitHub-hosted native runners. Android ABIs build independently and are merged only after their non-ABI content is proven byte-identical. The iOS script preserves finished framework slices between builds to stay within hosted-runner disk limits.

The workflow performs structural checks only. It does not run inference, an emulator, a simulator, or a GPU benchmark. A successful release means the libraries compiled and the expected architectures and package entries exist; it does not establish model coverage, accuracy, or device performance.

To create a release:

```bash
gh workflow run release.yml \
  --repo laurens-pilot/ort-packaging \
  -f tag=ort-1.27.0-webgpu-pilot.1 \
  -f ort_ref=v1.27.0 \
  -f prerelease=true
```

## Consuming an asset

Fetch an immutable release URL and verify it against `SHA256SUMS`. For example:

```bash
curl --fail --location --output onnxruntime-webgpu.aar \
  https://github.com/laurens-pilot/ort-packaging/releases/download/ort-1.27.0-webgpu-pilot.1/onnxruntime-webgpu-android-1.27.0-pilot.1.aar
```

Do not fetch from a mutable branch URL in a production build. Pin both the release tag and checksum in the downstream build configuration.

For Android, use the released AAR instead of `com.microsoft.onnxruntime:onnxruntime-android` to avoid duplicate Java classes and native libraries. For iOS, use the released XCFramework instead of the stock ONNX Runtime framework. Desktop consumers must load/register the plugin through ONNX Runtime's plugin EP API and keep the provider library (and the two DXC DLLs on Windows) beside the application binary.

Provider ABI compatibility is not a promise across arbitrary ONNX Runtime versions. Use the same pinned ORT release as the package and upgrade the core and plugin together. macOS/iOS application bundles must perform their normal final code-signing step after embedding the library/framework.

## Design notes

- Source is the exact upstream ONNX Runtime tag, recorded with its commit in every manifest.
- A small patch removes Microsoft's internal-only vcpkg asset-cache flag from the upstream Android packaging helper. A second packaging patch compiles Dawn's manual-reference-counted Objective-C++ utility without ARC on iOS, counteracting the upstream iOS toolchain's global ARC setting. Neither patch changes runtime behavior.
- Mobile outputs keep CPU fallback and include XNNPACK; the iOS output also keeps CoreML. This allows a custom package to replace, rather than reduce, the ordinary mobile runtime options.
- The iOS deployment target is 16.3 because ONNX Runtime WebGPU uses floating-point `std::to_chars`, which Apple's standard library marks available starting in iOS 16.3.
- WebGPU uses Dawn: Vulkan on Android/Linux, Metal on Apple platforms, and D3D12 on Windows.
- The release remains a prerelease until representative-device correctness and performance testing has been completed downstream.

ONNX Runtime and its bundled third-party components retain their upstream licenses. Each archive includes the applicable upstream license/notices where its package format permits it.
