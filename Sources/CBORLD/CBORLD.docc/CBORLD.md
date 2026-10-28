# ``CBORLD``

Encode, decode, inspect, constrain, and verify CBOR-LD documents in native
Swift.

## Overview

Swift-CBORLD preserves the established JavaScript-compatible representation by
default and exposes deterministic CBOR profiles as explicit opt-ins. Use
``CBORLDEncoder`` and ``CBORLDDecoder`` for configured processors, or the
static ``CBORLD/CBORLD`` facade for one-shot operations. ``CBORLDValueEncoder``
and ``CBORLDValueDecoder`` convert `Codable` models to and from ``JSONValue``
without a JSON text round trip.

Registry entries select how a document is compressed. A
``CBORLDRegistryEntry`` combines type tables with a ``CBORLDProcessingModel``
that states whether terms are semantically compressed and which typed-value
codecs apply. The four codecs defined by the CBOR-LD 1.0 editor's draft are
built in; supply any other codec as a ``CBORLDTypedValueCodec``. An unknown
codec identifier is rejected rather than ignored, and a user codec must
round-trip exactly.

At a trust boundary, start from
``CBORLDDecodingConfiguration/untrustedCompatible`` or
``CBORLDDecodingConfiguration/untrustedDeterministic`` to bound work and
enforce a reproducible representation, bound output with
``CBORLDEncodingLimits``, and bound context loading with
``CBORLDContextLoadingPolicy``. The package never fetches a context from the
network by itself: every context comes from a registry or loader that the
application supplies. Use ``CBORLD/CBORLD/inspect(_:configuration:)`` when
envelope and transport metadata are needed before semantic context loading.

Transport digests, structural fingerprints, context pins, and dictionary pins
are deliberately distinct. An integrity result detects mismatch; it does not
authenticate a producer.

Compute-family contracts, CPU references, and shadow verification live in the
separate `CBORLDCompute` module.

## Topics

### Essentials

- ``CBORLD/CBORLD``
- ``CBORLDEncoder``
- ``CBORLDDecoder``
- ``JSONValue``
- ``CBORLDFormat``
- ``CBORLDSerializationMode``
- ``CBORLDEncodingOptions``
- ``CBORLDDecodingOptions``

### Swift values

- ``CBORLDValueEncoder``
- ``CBORLDValueDecoder``

### Registry entries and processing models

- ``CBORLDRegistryEntry``
- ``CBORLDRegistryEntryLoader``
- ``CBORLDProcessingModel``
- ``CBORLDTypeTable``
- ``CBORLDTypeTableLoader``
- ``CBORLDValueTable``

### Typed-value codecs

- ``CBORLDTypedValueCodec``
- ``CBORLDCodecIdentifier``
- ``CBORLDCodecContext``
- ``CBORLDDataItem``
- ``CBORLDMapEntry``

### Contexts and dictionaries

- ``CBORLDContextRegistry``
- ``CBORLDContextLoadingPolicy``
- ``CBORLDContextRequest``
- ``CBORLDLoadedDocument``
- ``CBORLDContextDocumentLoader``
- ``CBORLDDocumentLoader``
- ``CBORLDDocumentDictionary``
- ``CBORLDDictionaryBinding``

### Untrusted input and bounded output

- ``CBORLDDecodingConfiguration``
- ``CBORLDDecodingLimits``
- ``CBORLDDecodingPolicy``
- ``CBORLDEncodingLimits``
- ``CBORLDInspection``
- ``CBORLDEnvelopeMetadata``
- ``CBORLDValidatedDocument``
- ``CBORLDRawNode``
- ``CBORLDResourceProvenance``

### Errors

- ``CBORLDError``
- ``CBORLDErrorCode``
- ``CBORLDSourceDiagnostic``

### Streaming

- ``CBORLDByteSink``
- ``CBORLDDataSink``
- ``CBORLDFileSink``
- ``CBORLDFileChunks``
- ``CBORLDStreamingResult``
- ``CBORLDStreamValidation``
- ``CBORLDStreamedDocument``
- ``CBORLDJSONEvent``

### Integrity

- ``CBORLDDigest``
- ``CBORLDHashAlgorithm``
- ``CBORLDHashDomain``
- ``CBORLDIntegrityManifest``
- ``CBORLDVerificationPolicy``
- ``CBORLDVerificationReport``
- ``CBORLDVerificationCheck``
- ``CBORLDVerificationKind``
- ``CBORLDVerificationStatus``

### Prepared sessions and caching

- ``CBORLDPreparedEncoder``
- ``CBORLDPreparedDecoder``
- ``CBORLDResourceCache``
- ``CBORLDResourceCacheLimits``
- ``CBORLDResourceCacheStatistics``

### Batch execution

- ``CBORLDExecutionPolicy``
- ``CBORLDBatchOutcome``
- ``CBORLDBatchFailure``
- ``CBORLDBatchObservation``
- ``CBORLDBatchInputMeasure``
- ``CBORLDBatchOutputMeasure``
- ``CBORLDStructuralCost``
- ``CBORLDBatchResultOrder``
- ``CBORLDBatchOutcomeStream``
- ``CBORLDIndexedOutcome``
