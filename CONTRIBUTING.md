# Contributing

Thank you for improving Swift-CBORLD. Changes should preserve its narrow
contract: exact CBOR-LD transformation, bounded validation, explicit integrity
semantics, and evidence that can be reproduced without vendored repositories.

## Before opening a change

1. Run `Scripts/validate-release.sh`.
2. Add or update a known wire vector for every codec or serializer change.
3. Add negative tests for parser, resource-limit, and integrity changes.
4. Preserve compatibility-mode bytes unless the change intentionally targets a
   new format or profile.
5. Use a new fingerprint version when dictionary or structural fingerprint
   input changes.
6. Record the URL, immutable revision, license, and checksum for new external
   fixture material.

Do not commit downloaded comparator repositories, package-manager build trees,
coverage output, personal Xcode metadata, or generated benchmark runs other
than deliberately reviewed release evidence.

## Source and API expectations

- Keep the `CBORLD` target dependency-free at runtime.
- Use Swift concurrency types that satisfy `Sendable` boundaries.
- Keep compatibility serialization and deterministic serialization visibly
  distinct in API and tests.
- Treat transport hashes, structural fingerprints, context pins, dictionary
  pins, and authentication as separate concepts.
- Keep external compute backends behind granular provider protocols and validate
  every provider result before accepting it.

## Provenance

Do not remove an existing copyright or license notice. Identify whether a
change is independently authored, adapted, or copied. Include the original
license text when a retained third-party component requires it and update
`THIRD_PARTY_NOTICES.md`.

By contributing, you agree that your contribution may be distributed under the
repository's BSD-3-Clause license.
