# Stable release checklist

Follow the canonical procedure in [README.md](README.md#release-process).

Before building:

- [ ] The exact packaging code to release is on `main`.
- [ ] The **Validate** workflow for that `main` commit succeeded.

Before publishing:

- [ ] **Assemble release candidate** succeeded for the intended ORT version and package revision.
- [ ] Android WebGPU passed on representative supported physical devices.
- [ ] The iOS device slice and vendor-GPU behavior were validated.
- [ ] The candidate build is less than 14 days old.

After publishing:

- [ ] The release tag is correct, the release is immutable, and all 35 assets are present.
- [ ] `SHA256SUMS` verifies every package.
- [ ] Every manifest and `build-provenance.json` records `ORT_TELEMETRY=disabled`.

Never replace or retag an existing release. Create the next package revision instead.
