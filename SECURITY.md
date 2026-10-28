# Security policy

## Supported versions

Until the first preview tag is published, security fixes apply to the `main`
branch. After publication, the latest `0.x` preview is supported. Preview APIs
may change when a fix requires a safer contract.

## Reporting a vulnerability

Use the repository's private GitHub security-advisory flow. Do not disclose a
suspected vulnerability in a public issue before a fix or coordinated advisory
is available. Include the affected version or commit, a minimal reproducer,
expected and observed behavior, and any known impact. For a failure found by
the property tests, include the seed and iteration from the failure message.

If private advisories are temporarily unavailable, contact the repository owner
privately through the contact method shown on the GitHub organization profile.

## Trust boundary

Swift-CBORLD parses attacker-controlled bytes only within caller-selected
limits. At a trust boundary, applications should:

- start from `CBORLDDecodingConfiguration.untrustedCompatible` or
  `.untrustedDeterministic`, or configure equally conservative input,
  nesting, and container bounds, and reject duplicate map keys and
  indefinite-length items;
- bound encoded output with `CBORLDEncodingLimits` when encoding documents
  they did not construct;
- supply contexts only from a controlled registry or loader, bound loading
  with `CBORLDContextLoadingPolicy`, and pin contexts and dictionaries, for
  example with `CBORLDContextLoadingPolicy.strict`;
- bound shared caches with `CBORLDResourceCacheLimits` and batches with
  `CBORLDExecutionPolicy`; and
- authenticate transport digests in an enclosing protocol when origin matters.

The core package never fetches a context from the network. A loader that does
is application code, and it remains responsible for transport security, and
for timeouts and response-size limits before a document reaches the
processor. The loading policy bounds what the processor accepts from any
loader, including redirect counts and URL schemes, hosts, and media types
that the loader reports.

A user-supplied `CBORLDTypedValueCodec` runs in-process with the caller's
privileges. The processor verifies that every value such a codec compresses
decodes back to the original, but the codec itself is trusted code.

Streaming validation and decoding do not hold the encoded input, but memory
still grows with nesting depth, the longest string, and, when duplicate keys
or a deterministic profile are checked, the keys of open maps. The same
limits apply to streamed and whole-buffer input.

The project does not claim that a digest authenticates a producer, that a
structural fingerprint proves RDF-semantic equivalence, that a successful CBOR
scan constitutes CDDL validation, or that a matching result from a CPU or
CPU-fallback compute path demonstrates accelerated execution.
