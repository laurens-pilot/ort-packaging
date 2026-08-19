# Stable release checklist

Use this checklist for a stable package release. Existing pilot tags remain immutable evidence and are never renamed or replaced.

1. Ensure all packaging changes are merged into `main` with `Validate / scripts` passing.
2. Dispatch `build.yml` from `main` with `ort_version=<major.minor.patch>`. Omit `package_revision` for `r1`; for `r<n>`, supply `n`. The workflow requires `r<n-1>` to exist and be immutable.
3. Monitor the preflight and every native build. The candidate is complete only when the `Assemble release candidate` job succeeds.
4. Confirm representative-device correctness and performance evidence, including Android WebGPU on the supported physical-device matrix.
5. Dispatch `publish.yml` from `main` with the successful build run ID shown in the build summary. Publish within 14 days, before its candidate artifact expires.
6. Confirm that publication created the expected immutable tag and 35 assets: 11 binaries, 11 checksums, 11 manifests, `SHA256SUMS`, and `build-provenance.json`.
7. Independently download the release, verify `SHA256SUMS`, confirm `ORT_TELEMETRY=disabled` in every manifest and provenance, and retain the device-test record with the release notes. Never replace or retag an existing release.
