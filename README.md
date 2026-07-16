# ONNX Runtime WebGPU Packaging

Builds pinned, self-contained ONNX Runtime WebGPU packages for Android and desktop without depending on Microsoft-provided ONNX Runtime binaries.

## What This Produces

| Platform | Architectures | Contents |
| --- | --- | --- |
| Android | arm64-v8a, armeabi-v7a, x86_64 | ABI-specific and universal AARs with ORT, Java/JNI, WebGPU, XNNPACK, and CPU fallback |
| Linux | x64, ARM64 | ORT shared runtime and WebGPU plugin |
| macOS | Intel x64, Apple Silicon ARM64 | ORT shared runtime and WebGPU plugin |
| Windows | x64, ARM64 | ORT runtime, WebGPU plugin, and required DXC DLLs |

iOS is intentionally excluded; use the official ONNX Runtime package with CoreML there.

The Android AAR packages WebGPU into the runtime and replaces `onnxruntime-android`. Desktop archives contain a matching ORT core and WebGPU plugin built from the same source revision. The desktop plugin must be registered before creating WebGPU sessions.

Do not mix these packages with another ONNX Runtime build.

## Repository Layout

- `versions.env`: ONNX Runtime and toolchain pins
- `config/`: Android build configuration
- `scripts/`: platform build and packaging entrypoints
- `patches/`: reviewable upstream build-system patches
- `.github/workflows/release.yml`: native build and release matrix

Generated files are written to `build/` and `dist/`, which are ignored by Git.

## CI And Releases

The release workflow builds all targets on native GitHub-hosted runners. Android ABIs are built separately and then merged into a universal AAR.

```sh
gh workflow run release.yml \
  --repo laurens-pilot/ort-packaging \
  -f tag=ort-1.27.0-webgpu-pilot.2 \
  -f ort_ref=v1.27.0 \
  -f prerelease=true \
  -f scope=all
```

Use `scope=windows` for a Windows-only build probe. Probe runs do not publish releases.

Release tags are immutable. Packaging-only changes increment `PACKAGE_REVISION` in `versions.env`.

## Release Verification

Every binary asset includes:

- a `.sha256` checksum;
- a `.manifest.env` file identifying the ORT source and target.

The release also includes `SHA256SUMS`. CI verifies all checksums and manifests before publishing.

Example:

```sh
tag=ort-1.27.0-webgpu-pilot.2
asset=onnxruntime-webgpu-android-1.27.0-pilot.2.aar
base=https://github.com/laurens-pilot/ort-packaging/releases/download/$tag

curl -fL -o "$asset" "$base/$asset"
curl -fL -o "$asset.sha256" "$base/$asset.sha256"
printf '%s  %s\n' "$(cat "$asset.sha256")" "$asset" | sha256sum -c -
```

Always pin an immutable release tag and checksum downstream.

## Validation Scope

CI verifies package structure, native architectures, required exports, Android JNI contents, and checksums. It does not run inference or benchmark GPU performance.

Releases remain prereleases until representative-device correctness and performance testing is completed downstream.

ONNX Runtime and bundled third-party components retain their upstream licenses. Runtime archives include the applicable license and notices.
