# ``CBORLD``

Encode, decode, inspect, constrain, and verify CBOR-LD documents in native
Swift.

## Overview

Swift-CBORLD preserves the established JavaScript-compatible representation by
default and exposes deterministic CBOR profiles as explicit opt-ins. Use
``CBORLDEncoder`` and ``CBORLDDecoder`` for configured processors, or the
static ``CBORLD`` facade for one-shot operations.

At a trust boundary, combine ``CBORLDDecodingLimits`` with
``CBORLDDecodingPolicy`` to bound work and enforce a reproducible
representation. Use ``CBORLD/inspect(_:limits:policy:)`` when envelope and
transport metadata are needed before semantic context loading.

Transport digests, structural fingerprints, context pins, and dictionary pins
are deliberately distinct. An integrity result detects mismatch; it does not
authenticate a producer.

## Topics

### Documents

- ``JSONValue``
- ``CBORLD``
- ``CBORLDEncoder``
- ``CBORLDDecoder``
- ``CBORLDFormat``
- ``CBORLDSerializationMode``

### Contexts and dictionaries

- ``CBORLDContextRegistry``
- ``CBORLDDocumentLoader``
- ``CBORLDDocumentDictionary``

### Inspection and strict decoding

- ``CBORLDInspection``
- ``CBORLDDecodingLimits``
- ``CBORLDDecodingPolicy``
- ``CBORLDValidatedDocument``
- ``CBORLDRawNode``
- ``CBORLDError``

### Integrity

- ``CBORLDDigest``
- ``CBORLDHashAlgorithm``
- ``CBORLDHashDomain``
- ``CBORLDIntegrityManifest``
- ``CBORLDVerificationReport``

### Prepared and batch execution

- ``CBORLDPreparedEncoder``
- ``CBORLDPreparedDecoder``
- ``CBORLDExecutionPolicy``
- ``CBORLDBatchOutcome``

### Compute integration

- ``CBORLDCPUComputeProvider``
- ``CBORLDComputeFamilyID``
- ``CBORLDWholeDocumentTransformConfiguration``
- ``CBORLDCDDLCPUOracle``
