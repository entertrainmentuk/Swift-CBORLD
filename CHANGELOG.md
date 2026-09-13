# Changelog

All notable changes to Swift-CBORLD will be documented in this file. The
project follows Semantic Versioning after the preview API has stabilized.

## 0.1.0 - Unreleased

Initial source-first preview.

### Added

- Native Swift CBOR-LD 1.0, pre-1.0 range, and legacy singleton processing.
- JavaScript-compatible default encoding and two explicit RFC 8949
  deterministic profiles.
- Async JSON-LD context processing, scoped contexts, application dictionaries,
  URI and typed-value codecs.
- Structured SHA-2 digests; transport, structural, context, and dictionary
  fingerprint domains; pinned resource verification; and integrity sidecars.
- Strict decoding policies, bounded parser resources, inspection metadata,
  byte-offset diagnostics, and lossless raw-CBOR retention.
- Prepared sessions, direct `Decodable` materialization, and bounded batch and
  stream execution.
- Versioned compute-family contracts, acceptance facades, deterministic CPU
  references, whole-document transformation, and independent CDDL oracle hooks.
- Curated, attributed interoperability fixtures and measured Swift/Rust
  evidence.
- A neutral CBOR-LD Interop Lab with immutable comparator pins, explicit
  evidence states, portable result schemas, a challenge-fixture intake, and a
  three-lane CPU/provider benchmark contract.
- A responsive GitHub Pages product and Interop Lab experience backed by a
  checksummed 114/114 cross-decode snapshot and exact retained fixture inputs.

### Release boundaries

- Public API is preview quality and may change before 1.0.
- Compatibility serialization is the default; deterministic encoding is
  opt-in.
- The SemanticCompute adapter and commercial binary are not part of this
  release; any future integration is a separate optional companion package.
- The core package contains no signature or authentication wire format.
- A complete JSON-LD/RDF canonicalization engine is out of scope.
