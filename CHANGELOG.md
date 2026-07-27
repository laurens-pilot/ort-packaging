# Changelog

## 1.27.0-r3 — 2026-07-27

- Package iOS as one static-library XCFramework whose device and ARM64 Simulator slices each contain `libonnxruntime.a` and public headers.
- Remove the duplicate framework-wrapped archives and top-level `static-lib` copies from the iOS ZIP.
- Add a provenance-preserving path for packaging-only releases to reuse verified binaries from an immutable source release without recompiling them.

## 1.27.0-r2 — 2026-07-20

- Add pre-thinned device and ARM64 Simulator `libonnxruntime.a` archives to the iOS ZIP for Rust and other consumers that cannot link the XCFramework directly.
- Run the iOS Simulator CPU and CoreML inference smoke test against the packaged pre-thinned archive.

## 1.27.0-r1 — 2026-07-20

- First stable custom packaging release derived from ONNX Runtime `v1.27.0`.
- Android uses built-in WebGPU/XNNPACK/CPU; Linux and Windows use a shared WebGPU plugin; iOS and macOS use built-in CoreML/CPU.
- Native CI verifies packaged runtime inference, symbol/debug-data constraints, package licences, checksums, manifests, and release provenance.
- Stable releases use immutable `r<n>` tags and assets rather than pilot labels.
