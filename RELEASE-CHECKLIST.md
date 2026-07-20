# Stable release checklist

Use this checklist for a non-prerelease package release. Pilot tags remain immutable evidence and are never renamed or replaced.

1. Update `versions.env` with the intended upstream tag, `PACKAGE_CHANNEL=stable`, and a new `PACKAGE_REVISION`. The computed label is `r<revision>` and the required release tag is `ort-<ORT_VERSION>-r<revision>`.
2. Ensure the packaging branch is merged into `main` through a PR with the `Validate / scripts` check passing.
3. Confirm representative-device correctness and performance evidence, including Android WebGPU on the supported physical-device matrix.
4. Dispatch `release.yml` from `main` with `scope=all`, the computed tag, and `prerelease=false`. The metadata job rejects an incorrect tag, channel, or source ref before native builds start.
5. Monitor every native build and the publish job. A successful publish verifies the release is immutable and has 35 assets: 11 binaries, 11 checksums, 11 manifests, `SHA256SUMS`, and `build-provenance.json`.
6. Independently download the release, verify `SHA256SUMS`, inspect the manifests and provenance, and retain the device-test record with the release notes.
7. If a packaging correction is needed, increment `PACKAGE_REVISION` and create the next immutable `r<n>` tag. Never replace or retag an existing release.
