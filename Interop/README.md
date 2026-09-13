# Interoperability evidence

This directory contains reviewed release evidence, not downloaded comparator
repositories. External implementations must be resolved into temporary CI
directories at immutable revisions and must never become Swift package inputs.

## Retained fixtures

- `Tests/CBORLDTests/Fixtures/cborld-cross-language.json` contains ten small
  envelope vectors with source URL, compared version, source file, and license.
- `Tests/CBORLDTests/Fixtures/rfc8949-curated.json` contains a small CBOR reader
  and deterministic-writer corpus derived from public standards examples.

The fixture tests validate exact bytes, envelope metadata, round-trip behavior,
deterministic encoding, malformed input, and strict-policy rejection.
`FIXTURE_SHA256SUMS` fixes the exact reviewed fixture bytes independently of
their source metadata.

## Recorded performance evidence

The reviewed macOS/arm64 run under `reports/` measures in-process codec work
after protocol parsing. Each implementation warms up, consumes results through
a barrier, and reports aggregate timing. Process startup and JSON protocol I/O
are outside the timed region.

Result: 11 of 11 fixtures were correct and byte-identical; Swift had the lower
round-trip median for 11 of 11 fixtures and a 2.22x aggregate speedup on that
recorded setup. The report does not claim lower cold-process latency, lower
latency for every isolated encode/decode operation, or universal performance
across machines and toolchains.

## Comparator pinning gate

`comparators.json` records the known project, version, and license metadata. The
immutable revision and archive checksum fields intentionally remain `null`
until they are verified against the public upstream repositories. Interop CI
must not count a comparator as available until both fields are populated and
verified. This gate prevents a version label, moving branch, or local checkout
from being mistaken for reproducible evidence.
