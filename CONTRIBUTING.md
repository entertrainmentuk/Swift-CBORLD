# Contributing

Thank you for improving Swift-CBORLD. Changes should preserve its narrow
contract: exact CBOR-LD transformation, bounded validation, explicit integrity
semantics, and evidence that can be reproduced without vendored repositories.

## Before opening a change

1. Run `Scripts/validate-release.sh`.
2. Add or update a known wire vector for every codec or serializer change.
3. Add negative tests for parser, resource-limit, and integrity changes, and
   extend the seeded property tests when a change affects parsing,
   serialization, or streaming.
4. Preserve compatibility-mode bytes unless the change intentionally targets a
   new format or profile.
5. Use a new fingerprint version when dictionary or structural fingerprint
   input changes.
6. Record the URL, immutable revision, license, and checksum for new external
   fixture material.
7. For an intentional public API change, run `Scripts/public-api.sh --update`
   and describe the change in `CHANGELOG.md`. Before 1.0 a breaking change is
   allowed but never accidental.
8. Keep line coverage above the floors that `Scripts/check-coverage.sh`
   enforces; add tests rather than lowering a floor.

A property-test failure names its seed and iteration. Replay it with
`CBORLD_FUZZ_SEED` and `CBORLD_FUZZ_ITERATIONS`, reduce the input, and commit
it as a permanent fixture next to the fix.

Do not commit downloaded comparator repositories, package-manager build trees,
coverage output, personal Xcode metadata, or generated benchmark runs other
than deliberately reviewed release evidence.

## Source and API expectations

- Keep both library targets free of third-party dependencies. A system
  framework, such as CryptoKit, is allowed only behind `#if canImport` with a
  portable fallback that tests check for agreement.
- Use Swift concurrency types that satisfy `Sendable` boundaries.
- Keep compatibility serialization and deterministic serialization visibly
  distinct in API and tests.
- Treat transport hashes, structural fingerprints, context pins, dictionary
  pins, and authentication as separate concepts.
- Never add network access to the core; contexts come from loaders that
  applications supply.
- Keep external compute backends behind the granular provider protocols in
  `CBORLDCompute`, and validate every provider result before accepting it.

## Provenance

Do not remove an existing copyright or license notice. Identify whether a
change is independently authored, adapted, or copied. Include the original
license text when a retained third-party component requires it and update
`THIRD_PARTY_NOTICES.md`.

By contributing, you agree that your contribution may be distributed under the
repository's BSD-3-Clause license.
