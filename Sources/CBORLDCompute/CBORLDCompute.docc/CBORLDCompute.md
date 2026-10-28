# ``CBORLDCompute``

Delegate bounded CBOR-LD work to a compute backend one family at a time, and
check every result against a deterministic CPU reference.

## Overview

`CBORLDCompute` defines versioned contracts for dense, bounded work that a
CBOR-LD pipeline can hand to another backend: batched SHA-256, byte diff, CBOR
structural scan, integer prefix scan and byte compaction, byte statistics,
canonical key ordering, UTF-8 validation, multibase, unsigned varint,
immutable dictionary probes, bounded whole-document transforms, and CDDL
validation. The 13 stable ``CBORLDComputeFamilyID`` values cover 12 conceptual
additions, because prefix scan and byte compaction are separate identifiers.

``CBORLDCPUComputeProvider`` implements every family on the CPU and is the
reference that other backends are measured against. CDDL validation runs only
when an independent ``CBORLDCDDLCPUOracle`` is injected; a structural CBOR scan
is not CDDL validation.

Structural acceptance rules can show that a backend's output is well-formed,
but not that a digest, scan, or ordering is correct.
``CBORLDShadowVerifyingProvider`` wraps a candidate backend, recomputes every
call, or a reproducible sample of calls, with the CPU reference, and records a
``CBORLDShadowVerificationReceipt`` for each one. A receipt carries the
backend's reported ``CBORLDComputeExecutionKind``: a CPU or CPU-fallback run
that matches the reference is parity evidence for that CPU path only, and only
``CBORLDShadowVerificationReceipt/isAccelerationEvidence`` identifies a match
that the backend observed running on accelerator hardware.

The CPU provider is reference evidence. It does not prove accelerator
catalogue registration, legality, lowering, compilation, hardware execution,
or doctor parity for any other backend.

## Topics

### Providers

- ``CBORLDComputeProvider``
- ``CBORLDCPUComputeProvider``
- ``CBORLDComputeBackendDescribing``
- ``CBORLDComputeCapabilityReporting``
- ``CBORLDComputeBackendIdentity``
- ``CBORLDComputeExecutionKind``
- ``CBORLDComputeCPUReferenceKind``

### Family contracts

- ``CBORLDComputeFamilyID``
- ``CBORLDComputeFamilyContract``
- ``CBORLDComputeFamilyCapability``
- ``CBORLDComputeFamilyAvailability``
- ``CBORLDComputeFamilyPriority``

### Shadow verification

- ``CBORLDShadowVerifyingProvider``
- ``CBORLDShadowVerificationPolicy``
- ``CBORLDShadowMismatchAction``
- ``CBORLDShadowVerificationReceipt``
- ``CBORLDShadowParityStatus``
- ``CBORLDShadowMismatch``

### Hashing and byte comparison

- ``CBORLDBatchedSHA256Computing``
- ``CBORLDSHA256Result``
- ``CBORLDByteDiffComputing``
- ``CBORLDByteDiffResult``
- ``CBORLDBytePair``
- ``CBORLDComputePackedByteBatch``
- ``CBORLDComputeByteSpan``

### CBOR structure and key ordering

- ``CBORLDStructuralScanComputing``
- ``CBORLDStructuralScanResult``
- ``CBORLDCanonicalKeyOrderingComputing``
- ``CBORLDCanonicalKeyOrdering``
- ``CBORLDCanonicalKeyOrderResult``

### Scans, compaction, and statistics

- ``CBORLDPrefixScanComputing``
- ``CBORLDExclusiveScanUInt32Result``
- ``CBORLDExclusiveScanUInt64Result``
- ``CBORLDByteCompactionResult``
- ``CBORLDByteStatisticsComputing``
- ``CBORLDByteStatistics``

### Text and integer encodings

- ``CBORLDUTF8ValidationComputing``
- ``CBORLDUTF8ValidationResult``
- ``CBORLDMultibaseComputing``
- ``CBORLDMultibaseEncoding``
- ``CBORLDMultibaseDecodeResult``
- ``CBORLDUnsignedVarintComputing``
- ``CBORLDUnsignedVarintDecodeResult``

### Dictionary probes

- ``CBORLDDictionaryProbeComputing``
- ``CBORLDDictionaryProbe``
- ``CBORLDDictionaryProbeResult``

### Whole-document transforms

- ``CBORLDWholeDocumentTransformComputing``
- ``CBORLDWholeDocumentTransformConfiguration``
- ``CBORLDWholeDocumentTransformOperation``
- ``CBORLDWholeDocumentTransformRequest``
- ``CBORLDWholeDocumentTransformResult``

### CDDL validation

- ``CBORLDCDDLValidationComputing``
- ``CBORLDCDDLCPUOracle``
- ``CBORLDCDDLValidationRequest``
- ``CBORLDCDDLValidationResult``
- ``CBORLDCDDLValidationLimits``
- ``CBORLDCDDLDiagnostic``
- ``CBORLDCDDLDiagnosticPhase``
- ``CBORLDCDDLDiagnosticSeverity``
- ``CBORLDCDDLDocumentEncoding``
- ``CBORLDCDDLRegexPolicy``
