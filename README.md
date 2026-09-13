# Swift-CBORLD

[![CI](https://github.com/entertrainment/swift-cborld/actions/workflows/ci.yml/badge.svg)](https://github.com/entertrainment/swift-cborld/actions/workflows/ci.yml)
[![License: BSD-3-Clause](https://img.shields.io/badge/license-BSD--3--Clause-blue.svg)](LICENSE)
[![Preview: 0.1.0](https://img.shields.io/badge/release-0.1.0%20preview-f0a34a.svg)](CHANGELOG.md)

Swift-CBORLD is a native Swift implementation of the CBOR-LD processor. It
encodes and decodes JSON-LD-shaped values, preserves the established
JavaScript-compatible wire representation by default, exposes deterministic
serialization profiles explicitly, validates untrusted envelopes, and keeps
integrity evidence separate from authentication.

This is an independent implementation. It is not an official Digital Bazaar
or W3C project and is not endorsed by either organization.

> **Release status:** the repository is being prepared as a source-first
> `0.1.0` preview. The module and product are named `CBORLD`; the repository and
> package identity are `swift-cborld`.

## Why Swift-CBORLD

- Native Swift 6 code with no third-party runtime dependencies.
- CBOR-LD 1.0 plus pre-1.0 range and legacy singleton decoding/encoding.
- JavaScript-compatible serialization as the default wire contract.
- Opt-in RFC 8949 length-first and core deterministic serialization.
- Remote, embedded, imported, type-scoped, and property-scoped contexts.
- Application dictionaries with validation and immutable fingerprints.
- SHA-256, SHA-384, and SHA-512 transport digests and domain-separated
  structural, context, and dictionary fingerprints.
- Pinned context and dictionary verification, integrity manifests, and
  aggregate verification reports.
- Bounded parsing, strict decoding policies, byte-offset diagnostics, and
  lossless CBOR inspection.
- Prepared sessions and bounded concurrent batch/stream execution.
- Stable, versioned compute-family contracts with deterministic CPU references.

## Requirements

- Swift 6.0 or newer
- macOS 13 or newer
- iOS and tvOS 16 or newer
- watchOS 9 or newer
- visionOS 1 or newer
- Linux with a compatible Swift 6 toolchain

Apple platforms listed in `Package.swift` are source compatibility floors, not
a claim that every OS/toolchain combination has been runtime tested. macOS and
Linux release builds are CI gates for the preview.

## Installation

After the `0.1.0` preview tag is published, add the source package:

```swift
dependencies: [
  .package(
    url: "https://github.com/entertrainment/swift-cborld.git",
    from: "0.1.0")
]
```

Then add the library product to your target:

```swift
.product(name: "CBORLD", package: "swift-cborld")
```

Import the module with:

```swift
import CBORLD
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

The static API also accepts `Encodable & Sendable` values and materializes
`Decodable & Sendable` models directly.

## Controlled and pinned contexts

Compression and expansion must use the same JSON-LD context. A controlled
registry can pin the parsed context structure before it is used:

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

let encoder = CBORLDEncoder(documentLoader: registry.documentLoader)
```

Applications should explicitly decide whether a network fallback is allowed.
The registry verifies fallback results against configured pins before the
processor consumes them.

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

The optional integrity manifest is a versioned sidecar and never changes the
CBOR-LD envelope. It contains no signature, key, certificate, or
authentication material. Authenticate a transport digest in the enclosing
protocol when producer identity matters.

## Inspect and constrain untrusted input

```swift
let limits = CBORLDDecodingLimits(
  maximumInputBytes: 8 * 1_024 * 1_024,
  maximumNestingDepth: 64,
  maximumContainerItems: 100_000,
  rejectDuplicateMapKeys: true,
  allowsIndefiniteLengthItems: false
)

let inspection = try CBORLD.inspect(bytes, limits: limits)
print(inspection.format)
print(inspection.transportDigest)
```

Inspection parses the complete envelope without loading contexts. Strict
decoding can additionally reject non-preferred integer, length, and floating
point widths and require a named deterministic representation.

## Compute-family boundary

The core package defines versioned provider protocols and deterministic CPU
references for SHA-256 batches, byte diff, CBOR structural scan, integer prefix
scan and compaction, byte statistics, canonical key ordering, UTF-8 validation,
multibase, unsigned varint, immutable dictionary probes, bounded whole-document
transform, and CDDL validation through an injected independent oracle.

These contracts let an application validate results from SemanticCompute, MCP,
or another backend one family at a time. The CPU provider is reference evidence
only; it does not prove accelerator catalogue registration, legality, lowering,
compilation, hardware execution, or doctor parity.

The SemanticCompute adapter is intentionally not included in the `0.1.0` core
tree. Its remote dependency and newer Apple deployment floors will be released
as an optional, separate package after SemanticCompute `1.23.0` is publicly
resolvable and independently verified.

## Correctness and performance evidence

The retained Swift fixtures cover CBOR-LD envelope bytes asserted by independent
Rust and Python processors and a small RFC 8949 CBOR corpus. Source, version,
and license metadata live beside the vectors.

On the recorded Apple-silicon test setup, the Swift and Rust implementations
both passed all 11 measured fixtures with byte-identical encoding. Swift had the
lower in-process round-trip median in 11 of 11 fixtures and a 2.22x aggregate
round-trip speedup for that corpus. This is fixture-, machine-, toolchain-, and
measurement-bound evidence—not a universal performance claim and not a claim
about cold CLI startup.

- [Human-readable benchmark](Interop/reports/performance-macos-arm64.md)
- [Machine-readable benchmark](Interop/reports/performance-macos-arm64.json)
- [Interoperability boundary](Interop/README.md)

## What this package does not prove

Swift-CBORLD performs the CBOR-LD transform used by the reference processor. It
is not a complete JSON-LD expansion, compaction, framing, or RDF dataset
canonicalization engine.

A structural fingerprint proves equality of JSON-shaped structure under the
package's deterministic ordering. It does not prove that two different JSON-LD
documents describe the same RDF dataset. Use an appropriate JSON-LD/RDF
canonicalization algorithm before signing semantic claims.

The package does not provide digital signatures, certificate trust, Merkle
proofs, or content-addressed persistence.

## Development

Run the local release gates:

```sh
Scripts/validate-release.sh
```

Or invoke the principal checks separately:

```sh
swift format lint --recursive Sources Tests Package.swift
swift build -c release -Xswiftc -warnings-as-errors \
  --explicit-target-dependency-import-check error
swift test -c release
```

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
