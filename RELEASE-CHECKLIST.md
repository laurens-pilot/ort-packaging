# Stable release checklist

Follow the canonical procedure in [README.md](README.md#release-process).

Before building:

- [ ] The exact packaging code to release is on `main`.
- [ ] The **Validate** workflow for that `main` commit succeeded.

Before publishing:

- [ ] **Assemble release candidate** succeeded for the intended ORT version and package revision.
- [ ] The generated device-evidence JSON records Android WebGPU and Java/JNI acceptance against the candidate hash.
- [ ] The same evidence records iOS device/CoreML acceptance and any Windows GPU checks missing from CI.
- [ ] The candidate build is less than 14 days old.

After publishing:

- [ ] The release tag is correct, the release is immutable, and all 35 assets are present.
- [ ] `SHA256SUMS` verifies every package.
- [ ] Every manifest and `build-provenance.json` records `ORT_TELEMETRY=disabled`.

Never replace or retag an existing release. Create the next package revision instead.
