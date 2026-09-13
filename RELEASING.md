# Release process

Swift-CBORLD is released source-first through Swift Package Manager. Do not tag
or publish directly from the mixed development workspace.

## `0.1.0` preview gate

- [ ] The release repository contains only the reviewed allowlist.
- [ ] `LICENSE` and `THIRD_PARTY_NOTICES.md` match every retained file.
- [ ] The recorded comparator revisions and checksums pass the public pin
      workflow.
- [ ] `Scripts/validate-release.sh` passes from a fresh clone on macOS.
- [ ] Release build and tests pass on the supported Linux CI image.
- [ ] Compatibility and malformed-input checks pass with pinned comparators.
- [ ] The public API symbol graph has been reviewed for accidental exposure.
- [ ] The SemanticCompute adapter is omitted, or its exact public dependency is
      resolvable and its newer platform floors are explicit.
- [ ] The landing page and generated DocC documentation deploy successfully.
- [ ] Interop status and lab reports validate against the public evidence
      vocabulary and disclose CPU, accelerator, and fallback lanes separately.
- [ ] Every performance statement identifies its implementation, workload,
      hardware, toolchain, measurement boundary, and parity result.
- [ ] The working tree is clean and CI is green at the exact release commit.

## Tagging

After every gate is satisfied:

```sh
git tag -s 0.1.0 -m "Swift-CBORLD 0.1.0 preview"
git push origin main
git push origin 0.1.0
```

Create a GitHub prerelease from the signed tag. Include supported platforms,
test counts, compatibility results, performance boundaries, known limitations,
and dependency boundaries. GitHub's generated source archives are the primary
release assets; do not attach a matrix of precompiled libraries.

If a manual artifact is added later, publish its SHA-256 checksum and document
the exact toolchain used. An XCFramework remains an optional convenience for a
concrete consumer, not the authoritative distribution.

## Promotion to 1.0

Promote only after the public API, context-loader contract, provenance record,
Linux support, and compatibility promises are stable across real downstream
use.
