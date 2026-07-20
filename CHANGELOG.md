# Changelog

## 1.27.0-r1 — unreleased

- First stable custom packaging release derived from ONNX Runtime `v1.27.0`.
- Android uses built-in WebGPU/XNNPACK/CPU; Linux and Windows use a shared WebGPU plugin; iOS and macOS use built-in CoreML/CPU.
- Native CI verifies packaged runtime inference, symbol/debug-data constraints, package licences, checksums, manifests, and release provenance.
- Stable releases use immutable `r<n>` tags and assets rather than pilot labels.
