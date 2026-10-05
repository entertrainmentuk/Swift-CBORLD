# Release process

Swift-CBORLD is released source-first through Swift Package Manager. Do not tag
or publish directly from the mixed development workspace.

## `0.1.0` preview gate

- [ ] The release repository contains only the reviewed allowlist.
- [ ] `LICENSE` and `THIRD_PARTY_NOTICES.md` match every retained file.
- [ ] The recorded comparator revisions and checksums pass the public pin
      workflow.
- [ ] `Scripts/validate-release.sh` passes from a fresh clone on macOS. It
      runs the evidence checks, strict formatting, the warnings-as-errors
      release build, the release tests, the public API baseline, the coverage
      floors, and both DocC catalogs.
- [ ] CI is green at the exact release commit: the Swift 6.0 macOS and Linux
      lanes, the current Swift lane, every Apple device build, both
      sanitizers, coverage, and the evidence job. The nightly-toolchain lane
      is advisory; record any failure it shows in the release notes.
- [ ] The nightly property-test workflow has passed since the last change to
      a parser, serializer, or codec, and no failing seed is open.
- [ ] Compatibility and malformed-input checks pass with pinned comparators.
- [ ] Every difference in `API/` since the previous release is intentional
      and listed in `CHANGELOG.md`, and the listing has been reviewed for
      accidental exposure.
- [ ] The conformance target in `README.md`, the editor's draft revision and
      the reference processor pin, is still the one the code implements.
- [ ] The SemanticCompute adapter is omitted, or its exact public dependency is
      resolvable and its newer platform floors are explicit.
- [ ] The landing page and both generated DocC references deploy
      successfully.
- [ ] `Interop/STATUS.md` and `Interop/lab-status.json` cite the public CI run
      for the release commit, validate against the public evidence
      vocabulary, and disclose CPU, accelerator, and fallback lanes
      separately.
- [ ] Every performance statement identifies its implementation, workload,
      hardware, toolchain, measurement boundary, and parity result.
- [ ] `CHANGELOG.md` carries the release date.
- [ ] `CommandLineTool.version` in `Sources/CBORLDCommandLine` matches the
      tag, so `cborld --version` reports the release.
- [ ] The working tree is clean.

## Tagging

After every gate is satisfied:

```sh
git tag -s 0.1.0 -m "Swift-CBORLD 0.1.0 preview"
git push origin main
git push origin 0.1.0
```

Create a GitHub prerelease from the signed tag. Include supported platforms,
the CI run for the tagged commit, test counts, compatibility results, the
conformance target, performance boundaries, known limitations, and dependency
boundaries. GitHub's generated source archives are the primary release assets;
do not attach a matrix of precompiled libraries.

If a manual artifact is added later, publish its SHA-256 checksum and document
the exact toolchain used. An XCFramework remains an optional convenience for a
concrete consumer, not the authoritative distribution.

Once the tag is public, submit the repository URL to the Swift Package Index.
`.spi.yml` asks it to build documentation for both library targets. From the
next release on, CI also reports `swift package
diagnose-api-breaking-changes` against the latest tag.

## Promotion to 1.0

Promote only after the public API, context-loader contract, provenance record,
Linux support, and compatibility promises are stable across real downstream
use, and after the CBOR-LD 1.0 specification has left the editor's-draft
stage.
