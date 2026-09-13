# CBOR-LD Interop Lab

Compare CBOR-LD implementations against the same documents, dictionaries,
malformed inputs, and canonical byte expectations. This directory contains the
public fixtures, evidence contracts, and reviewed release results; it does not
contain downloaded comparator repositories.

Swift-CBORLD is the neutral interoperability and conformance platform.
SemanticCompute is a possible optional commercial accelerator whose output must
be checked against the public CPU reference. External implementations and
accelerators must never become dependencies of the core Swift target.

## Evidence language

Lab conclusions use explicit, composable states:

- `source-present`: relevant source or a declared public contract is present.
- `build-validated`: the named revision built in the recorded environment.
- `runtime-validated`: the named workload executed successfully.
- `hardware-executed`: the requested accelerator backend actually ran.
- `byte-identical`: output bytes match the named reference.
- `semantically-equivalent`: decoded meaning matches although bytes may differ.
- `performance-win`, `performance-wash`, or `performance-loss`: the recorded
  statistical comparison supports that classification.
- `unavailable`: the lane or evidence was not available; it is not a failure
  and cannot be counted as a pass.

Each claim names its implementation, revision or binary identity, workload,
machine, toolchain, and measurement boundary. Source presence is not hardware
execution, CPU fallback is not accelerator execution, and semantic equivalence
is not byte identity. See [STATUS.md](STATUS.md) for the current matrix.

## Retained fixtures

- `Interop/fixtures/cases.json` contains the eight-case input corpus used by
  the retained cross-language snapshot: six four-way modern fixtures and two
  three-way legacy fixtures.
- `Tests/CBORLDTests/Fixtures/cborld-cross-language.json` contains ten small
  envelope vectors with source URL, compared version, source file, and license.
- `Tests/CBORLDTests/Fixtures/rfc8949-curated.json` contains a small CBOR reader
  and deterministic-writer corpus derived from public standards examples.

The fixture tests validate exact bytes, envelope metadata, round-trip behavior,
deterministic encoding, malformed input, and strict-policy rejection.
`FIXTURE_SHA256SUMS` fixes the exact reviewed fixture bytes independently of
their source metadata.

## Recorded cross-language evidence

`reports/interop-macos-arm64.json` is a scrubbed, machine-readable snapshot of
the dated development-lab run used by the website. It records 114 successful
cross-decodes out of 114 attempted across Swift, Digital Bazaar JavaScript,
LDC Labs Rust, and Subfile Python, plus 63 RFC-valid raw-CBOR vectors and one
expected legacy rejection checked by the fxamacker Go oracle. Seven of eight
CBOR-LD fixtures had exact byte consensus; the JSON-shapes case had semantic
consensus with permitted byte variation.

The clean release retains the fixture inputs, output evidence, timestamps,
environment, and checksums, but deliberately excludes adapters that depended
on sibling development checkouts. This means the result is runtime-validated
retained evidence, while rerunning the full external matrix from this checkout
remains unavailable. The website copy at `docs/interop-data.json` must remain
byte-for-byte identical to the reviewed report.

## Recorded performance evidence

The reviewed macOS/arm64 run under `reports/` measures in-process codec work
after protocol parsing. Each implementation warms up, consumes results through
a barrier, and reports aggregate timing. Process startup and JSON protocol I/O
are outside the timed region.

Result: 11 of 11 fixtures were correct and byte-identical; Swift had the lower
round-trip median for 11 of 11 fixtures and a 2.22x aggregate speedup on that
recorded setup. The report does not claim lower cold-process latency, lower
latency for every isolated encode/decode operation, or universal performance
across machines and toolchains. This is strictly a Swift CPU versus Rust CPU
result. No SemanticCompute code participated in the recorded benchmark.

## Three-lane acceleration evidence

A future accelerated report keeps these lanes independent:

| Lane | Whole-document transform | Bounded families | Current public result |
| --- | --- | --- | --- |
| Rust CBOR-LD | Rust CPU | Rust CPU where available | CPU benchmark recorded |
| Swift-CBORLD | Swift CPU | Public Swift CPU references | CPU benchmark recorded |
| Swift-CBORLD plus provider | Swift CPU | Named backend or explicit CPU fallback | Unavailable |

For every eligible family, the report records family and contract version,
batch size, total bytes, hardware and OS, compiler settings, dispatch overhead,
crossover point, exact output agreement, first mismatch and diagnosis, memory
measurement, binary hash, and actual backend or fallback. The CPU reference
remains the semantic authority. `schemas/lab-result.schema.json` defines the
portable record; it deliberately permits honest wins, washes, losses, and
unavailable lanes.

SemanticCompute is a commercial binary product. It is not required to build,
test, or use Swift-CBORLD. A future result using it must identify the exact
SemanticCompute version, binary SHA-256, backend, hardware, fallback status,
and independent post-dispatch parity result. The planned adapter distribution
is the separate `swift-cborld-semanticcompute` package.

## Implementation-neutral matrix

The lab gives equal status to Digital Bazaar JavaScript, Swift-CBORLD, LDC
Labs Rust, Subfile Python, Iridium Java, the fxamacker Go raw-CBOR oracle, the
anweiss CDDL oracle, and Swift-CBORLD with an optional provider. A row appears
only at the evidence level actually demonstrated. The current machine-readable
matrix is [lab-status.json](lab-status.json).

## Bring a hard fixture

Submit a small fixture that exposes a compatibility, performance,
canonicalization, resource-limit, or diagnostic question. The target outcome
is a portable regression fixture and a public result across every supported
implementation—not a promotional ranking. Wins, washes, losses, fallbacks,
semantic-only matches, byte mismatches, and unavailable implementations all
remain visible. See [CHALLENGE_FIXTURES.md](CHALLENGE_FIXTURES.md) for the
required provenance, expected behavior, minimization, and security fields.

## Comparator pinning gate

`comparators.json` records a public project URL, observed or selected version,
license, immutable 40-character Git revision, commit-addressed archive URL, and
SHA-256 checksum. `Scripts/verify-comparator-pins.sh` downloads every archive
into a temporary directory, rejects mismatches, and checks archive integrity.
The public pin workflow must pass before a tag.

Archive verification establishes the exact external source input; it does not
by itself rerun the full multi-language matrix. Reintroducing executable
adapters is a separate reviewed release step because the development adapters
still assume local `RUST/`, JavaScript, and Python checkout paths.

The public lab must never open promotional issues upstream. Upstream contact is
appropriate only for a minimized, reproducible compatibility finding, useful
fixture, or concrete fix, with the originating project credited prominently.
