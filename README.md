# Swift-CBORLD

[![CI](https://github.com/entertrainment/swift-cborld/actions/workflows/ci.yml/badge.svg)](https://github.com/entertrainment/swift-cborld/actions/workflows/ci.yml)
[![License: BSD-3-Clause](https://img.shields.io/badge/license-BSD--3--Clause-blue.svg)](LICENSE)
[![Preview: 0.1.0](https://img.shields.io/badge/release-0.1.0%20preview-f0a34a.svg)](CHANGELOG.md)

Swift-CBORLD is a native Swift implementation of the CBOR-LD processor. It
encodes and decodes JSON-LD-shaped values, preserves the established
JavaScript-compatible wire representation by default, exposes deterministic
serialization profiles explicitly, validates untrusted envelopes, and keeps
integrity evidence separate from authentication.

It is also the neutral host for the CBOR-LD Interop Lab: public fixtures,
portable CPU references, immutable comparator pins, and machine-readable
evidence contracts that any implementation or compute provider can use.

This is an independent implementation. It is not an official Digital Bazaar
or W3C project and is not endorsed by either organization.

> **Release status:** `0.1.0` is a source-first preview. The package
> `swift-cborld` provides two library products: `CBORLD`, the processor, and
> `CBORLDCompute`, the compute-family contracts.

## Conformance target

Swift-CBORLD 0.1.0 is a native Swift preview implementing the Digital Bazaar
compatibility wire profile, CBOR-LD 1.0 and legacy envelopes, registry entries
with processing models from a dated CBOR-LD 1.0 editor's draft, deterministic
CBOR profiles, bounded inspection and streaming, integrity primitives, pinned
resources, and experimental compute-family contracts.

| Contract | Pinned source | Evidence |
| --- | --- | --- |
| Wire compatibility | Digital Bazaar `cborld` 8.1.x at [`48bac5a`](https://github.com/digitalbazaar/cborld/tree/48bac5a57fe629c7a2271d7ca3be67a6f8f026e9) | Retained byte vectors and cross-decodes; defaults never change these bytes |
| Registry entries, processing models, codecs, error names | CBOR-LD 1.0 editor's draft, [w3c/cbor-ld](https://github.com/w3c/cbor-ld) revision `992f9335703c` of 2026-09-16 | This package's own tests; no independent implementation of processing models was available to compare against |
| Deterministic CBOR | RFC 8949 sections 4.2.1 and 4.2.3 | Known vectors and seeded property tests |

The W3C specification is an experimental editor's draft and may change. This
package does not claim complete CBOR-LD 1.0 conformance.

## Why Swift-CBORLD

- Native Swift 6 code with no third-party dependencies. On Apple platforms
  SHA-2 uses the system CryptoKit framework; elsewhere a portable Swift
  implementation produces identical digests.
- CBOR-LD 1.0 plus pre-1.0 range and legacy singleton decoding and encoding.
- Registry entries with processing models: semantic compression on or off,
  built-in `url`, `xsd-date`, `xsd-date-time`, and `multibase` codecs,
  user-supplied typed-value codecs with round-trip verification, caller-provided
  type tables, and provisional entries.
- JavaScript-compatible serialization as the default wire contract.
- Opt-in RFC 8949 length-first and core deterministic serialization.
- Remote, embedded, imported, type-scoped, and property-scoped contexts, loaded
  only from application-supplied sources under a bounded loading policy.
- Application dictionaries with validation and immutable fingerprints.
- SHA-256, SHA-384, and SHA-512 transport digests and domain-separated
  structural, context, and dictionary fingerprints.
- Pinned context and dictionary verification, integrity manifests, and
  aggregate verification reports.
- Bounded parsing and encoding, untrusted-input presets, strict decoding
  policies, typed error codes with byte-offset diagnostics, and lossless CBOR
  inspection.
- Streaming validation, decoding, and encoding of single documents with
  incremental transport digests.
- A native `Codable` encoder and decoder for `JSONValue`.
- Prepared sessions with a bounded resource cache, and bounded concurrent batch
  execution with streamed results.
- Stable, versioned compute-family contracts with deterministic CPU references
  and shadow verification, in the separate `CBORLDCompute` module.

## Requirements

- Swift 6.0 or newer
- macOS 13 or newer
- iOS and tvOS 16 or newer
- watchOS 9 or newer
- visionOS 1 or newer
- Linux with a compatible Swift 6 toolchain

CI builds and tests with Swift 6.0 on macOS and Linux and with the current
Swift release on Linux, and runs an advisory nightly-toolchain lane. It builds
the package for generic iOS, tvOS, watchOS, and visionOS devices, but tests
run only on macOS and Linux: the other platforms are build-verified, not
runtime-tested.

## Installation

Add the `0.1.0` preview as a source package:

```swift
dependencies: [
  .package(
    url: "https://github.com/entertrainment/swift-cborld.git",
    from: "0.1.0")
]
```

Then add the library products your target uses:

```swift
.product(name: "CBORLD", package: "swift-cborld"),
// Only if you implement or verify compute backends:
.product(name: "CBORLDCompute", package: "swift-cborld"),
```

## Encode and decode

`JSONValue` represents the complete JSON data model and supports Swift
literals:

```swift
import CBORLD

let document: JSONValue = [
  "@context": [
    "type": "@type",
    "Note": "https://www.w3.org/ns/activitystreams#Note",
    "summary": "https://www.w3.org/ns/activitystreams#summary"
  ],
  "type": "Note",
  "summary": "CBOR-LD from Swift"
]

let bytes = try await CBORLDEncoder().encode(document)
let restored = try await CBORLDDecoder().decode(bytes)
precondition(restored == document)
```

`Encodable` and `Decodable` models convert directly. `CBORLDValueEncoder` and
`CBORLDValueDecoder` build and read `JSONValue` trees without a JSON text
round trip, with date, data, non-conforming float, and key strategies and
`userInfo`:

```swift
struct Note: Codable, Sendable {
  var type = "Note"
  var summary: String
}

var valueEncoder = CBORLDValueEncoder()
valueEncoder.keyEncodingStrategy = .convertToSnakeCase
let value = try valueEncoder.encode(Note(summary: "typed"))
let note = try CBORLDValueDecoder().decode(Note.self, from: value)
```

## Registry entries and processing models

A CBOR-LD 1.0 envelope names a registry entry. Entry `0` carries the plain
CBOR encoding of the document, and entry `1` uses the default processing
model with no type tables. Any other entry comes from a dictionary or from a
`registryEntryLoader`, and selects:

- whether terms are semantically compressed, which replaces keys with integer
  identifiers derived from the referenced contexts;
- which typed-value codecs compress values of which JSON-LD types; and
- the type tables that compress context URLs and typed values.

```swift
// Semantic term compression off, but still compress xsd:dateTime values.
let entry = CBORLDRegistryEntry(
  id: 100,
  processingModel: .init(
    semanticCompression: false,
    codecs: [CBORLDProcessingModel.xsdDateTimeType: .xsdDateTime]))

let options = CBORLDEncodingOptions(
  registryEntryID: 100,
  documentLoader: registry.documentLoader,
  registryEntryLoader: { id in id == 100 ? entry : nil })
let compact = try await CBORLD.encode(document, options: options)
```

A processing model that names a codec identifier other than the four built-in
ones requires a matching `CBORLDTypedValueCodec`; an unknown identifier fails
with `ERR_UNKNOWN_CODEC` before any work starts. A user codec may decline a
value by returning `nil`, and the value is then carried through unchanged.
Every value a user codec compresses is decoded again and compared, so a codec
that does not round-trip exactly fails with `ERR_CODEC_NOT_INVERTIBLE`.

Without semantic compression, keys stay strings, but contexts are still loaded
so that codecs and type tables can apply. Plural values then carry no marker,
so a decoder could read an array of typed values as one compressed value.
When that could happen, the encoder carries the array's elements without
codecs, and it refuses with `ERR_AMBIGUOUS_VALUE` a value that would still
decode differently.

Provisional entries are accepted by default and can be refused with
`allowsProvisionalRegistryEntries: false`.

## Controlled and pinned contexts

Compression and expansion must use the same JSON-LD context. The core package
never fetches a context from the network: every context comes from a registry
or loader that the application supplies. A controlled registry can pin the
parsed context structure before it is used:

```swift
let contextURL = "https://example.com/contexts/notes-v1"
let context: JSONValue = [
  "@context": [
    "type": "@type",
    "Note": "https://example.com/Note",
    "summary": "https://example.com/summary"
  ]
]

let expected = try CBORLD.contextFingerprint(of: context)
let registry = CBORLDContextRegistry(
  documents: [contextURL: context],
  expectedFingerprints: [contextURL: expected]
)

let encoder = CBORLDEncoder(
  contextPolicy: .strict,
  contextDocumentLoader: registry.contextDocumentLoader
)
```

Applications decide whether a fallback loader is allowed. The registry
verifies fallback results against configured pins before the processor
consumes them. A `contextDocumentLoader` returns `CBORLDLoadedDocument`
values that carry each context's pin and, from a fallback, its canonical URL,
media type, byte count, and redirect chain, so `CBORLDContextLoadingPolicy`
can bound the number of documents, aggregate
bytes, import depth, redirects, and term definitions per operation, restrict
URL schemes, hosts, and media types, and require every context to be pinned.
`CBORLDContextLoadingPolicy.strict` sets conservative values for all of them.

`CBORLDResourceCache` shares loaded contexts across prepared sessions with a
maximum entry count, a maximum byte size, and an optional time to live.

## Compatibility and deterministic bytes

Compatibility encoding remains the default so established JavaScript byte
fixtures do not move:

```swift
let compatible = try await CBORLDEncoder().encode(document)

let deterministic = try await CBORLDEncoder(
  serializationMode: .lengthFirstDeterministic
).encode(document)
```

Serialization modes are separate contracts:

| Mode | Contract |
| --- | --- |
| `.compatibility` | Existing JavaScript-compatible representation; default |
| `.deterministic` | Original package length-first deterministic behavior |
| `.lengthFirstDeterministic` | RFC 8949 section 4.2.3 key ordering |
| `.coreDeterministic` | RFC 8949 section 4.2.1 bytewise lexical ordering |

The named deterministic profiles emit floating-point values in the shortest
exact width and normalize NaN to the preferred half-precision representation.

## Digests and integrity

Transport bytes and parsed structure have different meanings and therefore
different hash domains:

```swift
let transport = CBORLD.transportDigest(of: bytes, algorithm: .sha256)
try CBORLD.verify(bytes, against: transport)

let structure = try CBORLD.structuralFingerprint(
  of: document,
  algorithm: .sha512
)
try CBORLD.verifyDocument(document, against: structure)
```

- `encoded-bytes` is an ordinary hash of the exact transport bytes.
- `document-structure`, `context-document`, and `document-dictionary` use
  deterministic CBOR with a versioned, domain-separated prefix.
- `CBORLDDigest` carries and validates its algorithm, domain, version, and
  digest bytes.
- Verification avoids data-dependent early exit.
- Long-lived encoders, decoders, registries, and prepared sessions verify a
  dictionary pin or a registered context pin once, not once per document.

The optional integrity manifest is a versioned sidecar and never changes the
CBOR-LD envelope. It contains no signature, key, certificate, or
authentication material. Authenticate a transport digest in the enclosing
protocol when producer identity matters.

## Inspect and constrain untrusted input

Start from a preset at a trust boundary:

```swift
let configuration = CBORLDDecodingConfiguration.untrustedCompatible
let inspection = try CBORLD.inspect(bytes, configuration: configuration)
print(inspection.format)
print(inspection.transportDigest)

let decoder = CBORLDDecoder(configuration: .untrustedDeterministic)
```

`untrustedCompatible` accepts any JavaScript-compatible representation within
16 MiB of input, 64 levels of nesting, and 65,536 items per container, and
rejects duplicate map keys and indefinite-length items.
`untrustedDeterministic` additionally requires preferred integer, length, and
floating-point widths and the exact RFC 8949 length-first byte representation.
Both are ordinary `CBORLDDecodingLimits` and `CBORLDDecodingPolicy` values that
can be adjusted.

Inspection parses the complete envelope without loading contexts. Encoding is
bounded too: `CBORLDEncodingLimits` caps output bytes, nesting depth, and
container items while the output is built, so an oversized document fails
before its output crosses the limit.

## Streaming

Registry entry `0` documents can be processed without holding the whole
encoded form in memory:

```swift
let chunks = CBORLDFileChunks(url: inputURL, chunkSize: 64 * 1_024)
let validation = try await CBORLD.validateStream(chunks, limits: .strict)
print(validation.transportDigest)

var sink = try CBORLDFileSink(url: outputURL)
let result = try await CBORLD.encodeUncompressed(document, to: &sink)
try sink.close()
```

- `validateStream` validates any CBOR-LD envelope with the same limits and
  policy as whole-buffer inspection while computing the transport digest.
- `decodeUncompressedStream` rebuilds a registry-entry-zero document, and
  `decodeUncompressedEvents` delivers it as JSON events without building a
  tree.
- `encodeUncompressed(_:to:)` writes bounded chunks to a `CBORLDByteSink` and
  digests them as they are emitted.

Memory still grows with nesting depth, the longest string, and, when
duplicate keys or a deterministic profile are checked, the keys of open maps.
Semantic compression needs the whole document and its contexts, so compressed
registry entries are not streamed and constant-memory compression is not
claimed.

## Batches

Prepared sessions build dictionary indexes and resolve registry entries once
and then encode or decode many documents concurrently under a
`CBORLDExecutionPolicy` that bounds concurrency, document count, and total
input bytes. Streamed batches deliver each outcome as soon as it is ready, or
in input order with a bounded reorder buffer:

```swift
let prepared = try decoder.prepare(contextRegistry: registry)
for try await item in prepared.decodeBatchStream(
  documents, order: .inputOrder(maximumReorderBuffer: 64))
{
  print(item.index, item.outcome.value != nil)
}
```

Batch accounting uses a structural cost computed from the value itself,
equal to its registry-entry-zero payload size, rather than serializing JSON
text.

## Errors

Every failure is a `CBORLDError` whose `code` is a `CBORLDErrorCode`, such as
`.resourceLimit` or `.unknownCBORLDTermID`. Codes keep the JavaScript
processor's names. When the editor's draft names the same condition
differently, `specificationCode` reports the draft's name without changing
`code`. Parser errors carry a `CBORLDSourceDiagnostic` with the byte offset
and CBOR head, and `CBORLDError` conforms to `LocalizedError`.

## Compute-family boundary

`CBORLDCompute` defines versioned provider protocols and deterministic CPU
references for SHA-256 batches, byte diff, CBOR structural scan, integer prefix
scan and compaction, byte statistics, canonical key ordering, UTF-8 validation,
multibase, unsigned varint, immutable dictionary probes, bounded whole-document
transform, and CDDL validation through an injected independent oracle.

```swift
import CBORLDCompute

let verified = CBORLDShadowVerifyingProvider(
  candidate: backend,
  policy: .deterministicSample(rate: 0.1, seed: 42)
)
let digests = try await verified.batchedSHA256(slices)
let receipts = verified.receipts()
```

These contracts let an application validate results from SemanticCompute, MCP,
or another backend one family at a time. `CBORLDShadowVerifyingProvider`
recomputes every call, or a reproducible sample of calls, with the CPU
reference and records a receipt for every call. A receipt keeps the backend's reported execution
kind: a matching result from a CPU or CPU-fallback path is not evidence of
accelerated execution, and only a match that the backend observed on
accelerator hardware counts as acceleration evidence. The CPU provider is
reference evidence only; it does not prove accelerator catalogue
registration, legality, lowering, compilation, hardware execution, or doctor
parity.

The SemanticCompute adapter is intentionally not included in the `0.1.0`
tree. The intended companion distribution is `swift-cborld-semanticcompute`,
after SemanticCompute `1.23.0` is publicly resolvable and independently
verified. Importing that future package will add a separately licensed
commercial binary dependency and newer Apple deployment floors; neither is
required to build, test, or use Swift-CBORLD.

The public family identifiers and acceptance rules remain owned by this
package. There are 12 conceptual additions and 13 stable identifiers because
prefix scan and byte compaction are represented separately. Another
implementation is free to provide the same protocols without SemanticCompute.

## Correctness and performance evidence

The retained Swift fixtures cover CBOR-LD envelope bytes asserted by independent
Rust and Python processors and a small RFC 8949 CBOR corpus. Source, version,
and license metadata live beside the vectors. Seeded property tests compare
the whole-buffer and streaming parsers on arbitrary bytes and every
truncation, round-trip random documents and contexts through every
serialization mode and envelope format, and check integer and floating-point
width boundaries; a nightly
workflow runs them with far more cases from a fresh seed. CI also runs the
suite under the address and thread sanitizers, enforces line-coverage floors,
and compares the public API with a checked-in baseline.

On the recorded Apple-silicon test setup, the Swift and Rust implementations
both passed all 11 measured fixtures with byte-identical encoding. Swift had the
lower in-process round-trip median in 11 of 11 fixtures and a 2.22x aggregate
round-trip speedup for that corpus. This is fixture-, machine-, toolchain-, and
measurement-bound evidence—not a universal performance claim and not a claim
about cold CLI startup. It is a Swift CPU result: SemanticCompute did not cause
the recorded 2.22x speedup.

- [Human-readable benchmark](Interop/reports/performance-macos-arm64.md)
- [Machine-readable benchmark](Interop/reports/performance-macos-arm64.json)
- [CBOR-LD Interop Lab](Interop/README.md)
- [Current evidence status](Interop/STATUS.md)
- [Challenge-fixture contract](Interop/CHALLENGE_FIXTURES.md)
- [Portable lab-result schema](Interop/schemas/lab-result.schema.json)

Future acceleration reports use three separately labelled lanes: Rust CPU,
Swift CPU, and Swift plus an optional provider. A conforming report states the
backend, hardware, toolchains, batch and byte counts, dispatch overhead,
crossover point, memory boundary, exact parity result, and whether execution
used hardware or fell back to the CPU. Unmeasured or unavailable lanes remain
explicitly unavailable rather than inheriting a result from another lane.

## What this package does not prove

Swift-CBORLD performs the CBOR-LD transform used by the reference processor. It
is not a complete JSON-LD expansion, compaction, framing, or RDF dataset
canonicalization engine.

A structural fingerprint proves equality of JSON-shaped structure under the
package's deterministic ordering. It does not prove that two different JSON-LD
documents describe the same RDF dataset. Use an appropriate JSON-LD/RDF
canonicalization algorithm before signing semantic claims.

Processing-model behavior follows a dated editor's draft and has been checked
only by this package's own tests, because the pinned reference processor
predates processing models.

The package does not provide digital signatures, certificate trust, Merkle
proofs, content-addressed persistence, or network context fetching.

## Development

Run the local release gates:

```sh
Scripts/validate-release.sh
```

Or invoke the principal checks separately:

```sh
swift format lint --strict --recursive Sources Tests Package.swift
swift build -c release -Xswiftc -warnings-as-errors \
  --explicit-target-dependency-import-check error
swift test -c release --disable-swift-testing
Scripts/public-api.sh
Scripts/check-coverage.sh
```

Replay a property-test failure with the seed and case count from its message:

```sh
CBORLD_FUZZ_SEED=c0b01d5eed000001 CBORLD_FUZZ_ITERATIONS=20000 \
  swift test --filter PropertyTests
```

The default suite remains offline. An additional opt-in, digest-only
SemanticCompute Live byte-parity check is documented in
[SEMANTICCOMPUTE_LIVE.md](SEMANTICCOMPUTE_LIVE.md); it is integration evidence,
not an authentication or accelerator-execution claim.

See [CONTRIBUTING.md](CONTRIBUTING.md), [SECURITY.md](SECURITY.md), and
[RELEASING.md](RELEASING.md) before proposing changes or a tag.

## Provenance and license

Swift-CBORLD is distributed under the BSD-3-Clause license. Portions of the
implementation, interoperability fixtures, and reference material originate
from or are derived from Digital Bazaar's `cborld` project and retain the
required notices. Independent fixture sources retain their own license and
attribution.

See [LICENSE](LICENSE), [PROVENANCE.md](PROVENANCE.md), and
[THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
