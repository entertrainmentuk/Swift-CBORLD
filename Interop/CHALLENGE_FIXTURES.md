# Challenge fixtures

Bring the smallest fixture that exposes a CBOR-LD compatibility, deterministic
encoding, resource-limit, malformed-input, diagnostic, or performance question.
Accepted fixtures become portable regression evidence; submission does not
guarantee that every implementation can execute the case.

## Submission contract

A proposal must include:

- A stable fixture identifier and short description.
- The original JSON-LD or CBOR-LD input as a repository file, not a remote-only
  link. Binary input should also include a lowercase hexadecimal rendering.
- The operation under test and the expected outcome: exact bytes, decoded JSON
  structure, semantic-only equivalence, or a named rejection with byte offset.
- Context documents and application dictionaries materialized locally. Remote
  loading must not be required for the default conformance run.
- SHA-256 checksums for every retained input, context, dictionary, and expected
  output.
- Source, author, license, and redistribution permission. Do not submit private,
  personal, credential-bearing, or confidential data.
- A reason the case is distinct from the existing corpus and, for a failure, a
  minimized reproducer or enough information to minimize it.
- Resource expectations: input bytes, nesting, item count, and any deliberately
  adversarial behavior.
- For performance cases, the proposed batch size, total bytes, warm-up,
  iterations, samples, and measurement boundary. A single favorable timing is
  not evidence.

## Review and publication

The lab will:

1. Validate provenance, checksums, license, and bounded resource behavior.
2. Run the case against every available lane without treating unavailable
   implementations as failures.
3. Separate byte identity, structural equality, and semantic equivalence.
4. Record the first differing byte and diagnostic when exact parity fails.
5. Publish wins, washes, losses, fallbacks, and failures with the same evidence
   fields as successful runs.
6. Credit the contributor and affected upstream projects.

An acceleration lane must additionally name its binary version and SHA-256,
backend, hardware, dispatch overhead, actual hardware-versus-fallback status,
and independent CPU-reference parity. SemanticCompute or any other commercial
provider is optional; the fixture and CPU conformance path remain public.

Security-sensitive malformed inputs should be disclosed privately first using
[`SECURITY.md`](../SECURITY.md). Upstream issues should be opened only for a
genuine minimized finding or useful fix, never as promotion.
