# Changelog

All notable changes to Swift-CBORLD will be documented in this file. The
project follows Semantic Versioning after the preview API has stabilized.

## 0.1.0 - Unreleased

Initial source-first preview. The date is set when the signed tag is created.

### Added

- Native Swift CBOR-LD 1.0, pre-1.0 range, and legacy singleton processing.
- JavaScript-compatible default encoding and two explicit RFC 8949
  deterministic profiles.
- Async JSON-LD context processing, scoped contexts, application dictionaries,
  URI and typed-value codecs.
- Registry entries and processing models from the CBOR-LD 1.0 editor's draft,
  w3c/cbor-ld revision `992f9335703c`: semantic compression on or off, codec
  bindings, user-supplied typed-value codecs with round-trip verification,
  rejection of unknown codecs, caller-provided type tables, provisional
  entries, and type tables without term compression. Established
  compatibility vectors are unchanged.
- Typed `CBORLDErrorCode` values that keep the JavaScript processor's names,
  the editor's draft names through `specificationCode`, and `LocalizedError`
  conformance.
- Structured SHA-2 digests; transport, structural, context, and dictionary
  fingerprint domains; pinned resource verification; and integrity sidecars.
  On Apple platforms SHA-2 uses CryptoKit, with the portable implementation
  kept as the fallback and as an agreement oracle in the tests.
- Strict decoding policies, bounded parser resources, the
  `untrustedCompatible` and `untrustedDeterministic` presets, inspection
  metadata, byte-offset diagnostics, and lossless raw-CBOR retention.
- `CBORLDEncodingLimits`, enforced while output is written, so encoding stops
  before the output crosses `maximumOutputBytes`.
- `CBORLDContextLoadingPolicy` and context document loaders that report load
  metadata, bounding documents, bytes, import depth, redirects, and term
  definitions per operation, with URL scheme, host, and media-type allowlists
  and optional mandatory pinning. The core never fetches contexts itself.
- `CBORLDValueEncoder`, which produces `JSONValue` directly with date, data,
  non-conforming float, and key strategies, and a matching
  `CBORLDValueDecoder`.
- Streaming validation, registry-entry-zero decoding and JSON events, and
  streaming registry-entry-zero encoding to byte sinks, each with an
  incremental transport digest.
- Prepared sessions with a bounded, optionally expiring
  `CBORLDResourceCache`, direct `Decodable` materialization, and bounded batch
  execution with results streamed in completion order or in input order with a
  bounded reorder buffer. Batch accounting uses a structural cost instead of
  serializing JSON.
- The `CBORLDCompute` module and product: versioned compute-family contracts,
  acceptance facades, deterministic CPU references, whole-document
  transformation, independent CDDL oracle hooks, and a shadow-verifying
  provider whose receipts keep CPU and CPU-fallback execution distinct from
  accelerated parity.
- Curated, attributed interoperability fixtures and measured Swift/Rust
  evidence.
- A neutral CBOR-LD Interop Lab with immutable comparator pins, explicit
  evidence states, portable result schemas, a challenge-fixture intake, and a
  three-lane CPU/provider benchmark contract.
- A responsive GitHub Pages product and Interop Lab experience backed by a
  checksummed 114/114 cross-decode snapshot and exact retained fixture inputs.
- Seeded, reproducible property and differential tests; CI lanes for the
  Swift 6.0 minimum, the current Swift release, and an advisory nightly
  toolchain; generic iOS, tvOS, watchOS, and visionOS device builds; address
  and thread sanitizers; line-coverage floors; a checked-in public API
  baseline; nightly property runs; and weekly comparator-pin verification.
- `cborld`, a command-line tool that encodes, decodes, inspects, digests, and
  verifies CBOR-LD offline, reading contexts only from local files.
- An opt-in, digest-only SemanticCompute Live byte-parity check and workflow
  with no core dependency and no authentication or accelerator-execution
  claim.

### Changed since the preview candidate

Code that followed `main` before the tag should note these differences from
the 2026-09-13 candidate, commit `af20539`:

- The compute-family contracts, CPU references, and CDDL oracle hooks moved
  from `CBORLD` to the new `CBORLDCompute` module and product.
- `CBORLDError.code` is a `CBORLDErrorCode` instead of a `String`. Codes keep
  their `ERR_*` spellings, and string literals still convert.
- `.coreDeterministic` now orders the keys of registry-entry-zero documents by
  their encoded form, as RFC 8949 section 4.2.1 requires. The candidate
  ordered keys of different lengths by raw UTF-8 bytes on that path, which its
  own strict validation rejected, so those documents now encode to different
  bytes. Other modes, other registry entries, and all fingerprints are
  unchanged.
- Typed values no longer pass through JSON text on their way to CBOR-LD. A
  `UInt64` above `Int64.max` now throws `EncodingError.invalidValue` instead
  of becoming a rounded floating-point number. Otherwise the encoder
  reproduces the values `JSONEncoder` produced, which the tests compare type
  by type, so existing bytes do not change.
- `CBORLDValueDecoder` throws `DecodingError.valueNotFound` for `null` where a
  value is required, and `superDecoder(forKey:)` decodes `null` for a missing
  key, both as `JSONDecoder` does.
- Prepared sessions reject more than one context source instead of ignoring
  `documentLoader` when `contextRegistry` is also given.
- Dictionary validation rejects type tables for the unsupported literal types
  `xsd:integer`, `xsd:double`, and `xsd:boolean` with
  `ERR_UNSUPPORTED_LITERAL_TYPE`.
- The whole-document transform family enforces `maximumOutputBytes` while it
  encodes rather than after.

### Release boundaries

- Public API is preview quality and may change before 1.0. Every change to it
  is recorded in the checked-in baseline under `API/`.
- The W3C CBOR-LD specification is an experimental editor's draft. This
  release targets revision `992f9335703c` and does not claim complete
  CBOR-LD 1.0 conformance.
- Compatibility serialization is the default; deterministic encoding is
  opt-in.
- Streaming covers registry entry 0 and envelope validation. Semantic
  compression needs the whole document, and constant-memory compression is not
  claimed.
- The SemanticCompute adapter and commercial binary are not part of this
  release; any future integration is a separate optional companion package.
- The core package contains no signature or authentication wire format and
  never fetches contexts from the network.
- A complete JSON-LD/RDF canonicalization engine is out of scope.
