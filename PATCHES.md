# Upstream patch inventory

Every patch in `patches/` is applied to the exact upstream commit resolved by the release-candidate workflow. Its preflight job verifies the patches and compiles the portable smoke test against the requested ONNX Runtime release before any platform build starts.

## `onnxruntime-coreml-runtime-availability.patch`

This patch makes CoreML availability explicit at runtime for the APIs that are newer than the package deployment targets:

- float16 CoreML inputs require macOS 12 / iOS 16;
- ANE-only CoreML execution requires macOS 13 / iOS 16;
- CoreML specialization strategies require macOS 15 / iOS 18.

Instead of relying on an unguarded availability call, the runtime returns a descriptive ONNX Runtime error on an older OS. The patch also propagates that error from model loading. It is required to support the documented iOS 15.1 deployment target safely.

Remove this patch only when the selected upstream ONNX Runtime version contains equivalent runtime guards. Apple platform builds reject unguarded-availability warnings, and the release-candidate preflight checks that the patch still applies cleanly to the requested upstream version.

## `onnxruntime-public-vcpkg.patch`

This existing build-system patch keeps the required vcpkg integration reviewable and reproducible for the resolved upstream source. Its applicability is likewise checked by the release-candidate preflight before any platform build starts.
