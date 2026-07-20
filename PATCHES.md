# Upstream patch inventory

Every patch in `patches/` is applied to the exact upstream tag in `versions.env` by both CI validation and platform builds. Revalidate each patch when changing the upstream ONNX Runtime version.

## `onnxruntime-coreml-runtime-availability.patch`

This patch makes CoreML availability explicit at runtime for the APIs that are newer than the package deployment targets:

- float16 CoreML inputs require macOS 12 / iOS 16;
- ANE-only CoreML execution requires macOS 13 / iOS 16;
- CoreML specialization strategies require macOS 15 / iOS 18.

Instead of relying on an unguarded availability call, the runtime returns a descriptive ONNX Runtime error on an older OS. The patch also propagates that error from model loading. It is required to support the documented iOS 15.1 deployment target safely.

Remove this patch only when the selected upstream ONNX Runtime version contains equivalent runtime guards. The release workflow rejects builds that emit unguarded-availability warnings, and `Validate` checks that the patch still applies cleanly.

## `onnxruntime-public-vcpkg.patch`

This existing build-system patch keeps the required vcpkg integration reviewable and reproducible for the pinned upstream source. Its applicability is likewise checked by `Validate` before any release is built.
