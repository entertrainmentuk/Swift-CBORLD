import CBORLD
import Foundation

/// How often a candidate backend's results are recomputed by the CPU reference.
public enum CBORLDShadowVerificationPolicy: Sendable, Hashable {
  /// Pass calls through without verification; receipts report `notSampled`.
  case disabled
  /// Verify every call.
  case always
  /// Verify a pseudo-random fraction of calls. The same seed and sequence of
  /// calls always select the same calls, so a verification run can be
  /// reproduced exactly.
  case deterministicSample(rate: Double, seed: UInt64)
}

/// Where a backend actually executed a call.
public enum CBORLDComputeExecutionKind: String, Sendable, Hashable, Codable, CaseIterable {
  /// The package's own deterministic CPU reference.
  case cpuReference = "cpu-reference"
  /// A backend's own CPU implementation.
  case cpu
  /// A backend that intended to accelerate the call but ran it on the CPU.
  case cpuFallback = "cpu-fallback"
  case metal
  case gpu
  /// A remote service whose hardware is not observed.
  case remote
  case unknown

  /// Whether the kind names accelerator hardware.
  public var isAccelerator: Bool { self == .metal || self == .gpu }
}

/// A backend's identity and the execution facts it reports for a call.
public struct CBORLDComputeBackendIdentity: Sendable, Hashable, Codable {
  public var name: String
  public var version: String?
  public var buildIdentifier: String?
  /// A digest of the backend binary, when the backend can report one.
  public var binaryDigest: CBORLDDigest?
  public var executionKind: CBORLDComputeExecutionKind
  /// Whether the backend observed the call running on the named hardware,
  /// rather than merely selecting it.
  public var hardwareExecutionObserved: Bool

  public init(
    name: String,
    version: String? = nil,
    buildIdentifier: String? = nil,
    binaryDigest: CBORLDDigest? = nil,
    executionKind: CBORLDComputeExecutionKind,
    hardwareExecutionObserved: Bool = false
  ) {
    self.name = name
    self.version = version
    self.buildIdentifier = buildIdentifier
    self.binaryDigest = binaryDigest
    self.executionKind = executionKind
    self.hardwareExecutionObserved = hardwareExecutionObserved
  }
}

/// Adopted by backends that can describe how they executed a family call.
/// Backends that do not adopt it are recorded with an `unknown` execution
/// kind, which is never reported as acceleration evidence.
public protocol CBORLDComputeBackendDescribing: Sendable {
  func backendIdentity(for family: CBORLDComputeFamilyID) async -> CBORLDComputeBackendIdentity
}

public enum CBORLDShadowParityStatus: String, Sendable, Hashable, Codable, CaseIterable {
  /// The candidate's complete result equals the CPU reference.
  case match
  case mismatch
  /// The call was not selected for verification.
  case notSampled = "not-sampled"
  /// The CPU reference could not run, for example without a CDDL oracle.
  case referenceUnavailable = "reference-unavailable"
  /// The candidate threw.
  case candidateFailed = "candidate-failed"
}

/// The first place a candidate's result differs from the reference.
public struct CBORLDShadowMismatch: Sendable, Hashable, Codable {
  /// The first differing work item, or `nil` for a single-result family.
  public let workItemIndex: Int?
  /// The first differing result field, when it can be named.
  public let field: String?
  /// Whether the candidate returned a different number of work items.
  public let cardinalityDiffers: Bool
}

/// Provenance for one verified, or deliberately unverified, family call.
public struct CBORLDShadowVerificationReceipt: Sendable, Hashable, Codable {
  public let family: CBORLDComputeFamilyID
  public let contractVersion: Int
  public let candidate: CBORLDComputeBackendIdentity
  public let parity: CBORLDShadowParityStatus
  public let firstMismatch: CBORLDShadowMismatch?
  public let workItemCount: Int
  public let candidateDurationNanoseconds: UInt64?
  public let referenceDurationNanoseconds: UInt64?

  /// Whether the candidate ran on the CPU, including the package reference.
  /// Parity of a CPU run says nothing about accelerated execution.
  public var isCPUExecution: Bool {
    switch candidate.executionKind {
    case .cpuReference, .cpu, .cpuFallback: return true
    default: return false
    }
  }

  /// True only for a verified match that the candidate reports as observed on
  /// accelerator hardware.
  public var isAccelerationEvidence: Bool {
    parity == .match && candidate.executionKind.isAccelerator
      && candidate.hardwareExecutionObserved
  }
}

/// What a shadow verifier returns when the candidate disagrees with the
/// reference.
public enum CBORLDShadowMismatchAction: Sendable, Hashable {
  /// Throw `CBORLDErrorCode.shadowParityMismatch`.
  case throwError
  /// Return the CPU reference's result, so callers keep correct output.
  case returnReference
}

/// Wraps a candidate compute backend and recomputes selected calls with
/// ``CBORLDCPUComputeProvider``, comparing complete results.
///
/// Structural acceptance rules can prove that a backend's output is
/// well-formed, but not that a digest, scan, or ordering is correct. The
/// shadow verifier checks exact parity and records a
/// ``CBORLDShadowVerificationReceipt`` for every call, including the
/// backend's reported execution kind, so that CPU execution is never
/// mistaken for accelerated parity.
public struct CBORLDShadowVerifyingProvider<Candidate: Sendable>: Sendable {
  public let candidate: Candidate
  public let reference: CBORLDCPUComputeProvider
  public let policy: CBORLDShadowVerificationPolicy
  public let onMismatch: CBORLDShadowMismatchAction
  private let log: ReceiptLog
  private let receiptHandler: (@Sendable (CBORLDShadowVerificationReceipt) -> Void)?

  /// Wraps `candidate` and checks it against `reference` on the calls that
  /// `policy` selects.
  ///
  /// ``receipts()`` keeps the `maximumRetainedReceipts` most recent receipts;
  /// `receiptHandler` sees every receipt.
  public init(
    candidate: Candidate,
    reference: CBORLDCPUComputeProvider = .init(),
    policy: CBORLDShadowVerificationPolicy = .always,
    onMismatch: CBORLDShadowMismatchAction = .throwError,
    maximumRetainedReceipts: Int = 1_024,
    receiptHandler: (@Sendable (CBORLDShadowVerificationReceipt) -> Void)? = nil
  ) {
    self.candidate = candidate
    self.reference = reference
    self.policy = policy
    self.onMismatch = onMismatch
    self.log = ReceiptLog(capacity: max(0, maximumRetainedReceipts))
    self.receiptHandler = receiptHandler
  }

  /// The most recent receipts, oldest first.
  public func receipts() -> [CBORLDShadowVerificationReceipt] {
    log.snapshot()
  }

  /// Runs one family call on the candidate and, when selected, on the
  /// reference, returning the candidate's result unless the mismatch action
  /// says otherwise.
  fileprivate func verify<Result>(
    _ family: CBORLDComputeFamilyID,
    workItemCount: Int,
    candidate candidateCall: () async throws -> Result,
    reference referenceCall: () async throws -> Result,
    compare: (Result, Result) -> CBORLDShadowMismatch?
  ) async throws -> Result {
    let clock = ContinuousClock()
    let sampled = log.shouldSample(policy)
    let started = clock.now
    let candidateResult: Result
    do {
      candidateResult = try await candidateCall()
    } catch {
      let identity = await identity(for: family)
      record(
        family, identity, .candidateFailed, nil, workItemCount,
        candidateDuration: clock.now - started, referenceDuration: nil)
      throw error
    }
    let candidateDuration = clock.now - started
    let identity = await identity(for: family)
    guard sampled else {
      record(
        family, identity, .notSampled, nil, workItemCount,
        candidateDuration: candidateDuration, referenceDuration: nil)
      return candidateResult
    }
    let referenceStarted = clock.now
    let referenceResult: Result
    do {
      referenceResult = try await referenceCall()
    } catch {
      record(
        family, identity, .referenceUnavailable, nil, workItemCount,
        candidateDuration: candidateDuration, referenceDuration: nil)
      return candidateResult
    }
    let referenceDuration = clock.now - referenceStarted
    guard let mismatch = compare(candidateResult, referenceResult) else {
      record(
        family, identity, .match, nil, workItemCount,
        candidateDuration: candidateDuration, referenceDuration: referenceDuration)
      return candidateResult
    }
    record(
      family, identity, .mismatch, mismatch, workItemCount,
      candidateDuration: candidateDuration, referenceDuration: referenceDuration)
    switch onMismatch {
    case .returnReference:
      return referenceResult
    case .throwError:
      let location = [
        mismatch.workItemIndex.map { "work item \($0)" },
        mismatch.field.map { "field \($0)" },
        mismatch.cardinalityDiffers ? "work item count" : nil,
      ].compactMap { $0 }.joined(separator: ", ")
      throw CBORLDError(
        code: .shadowParityMismatch,
        message:
          "\(identity.name) disagreed with the CPU reference for \(family.rawValue)"
          + (location.isEmpty ? "." : " at \(location)."))
    }
  }

  private func identity(for family: CBORLDComputeFamilyID) async -> CBORLDComputeBackendIdentity {
    if candidate is CBORLDCPUComputeProvider {
      return .init(name: "CBORLDCPUComputeProvider", executionKind: .cpuReference)
    }
    if let describing = candidate as? any CBORLDComputeBackendDescribing {
      return await describing.backendIdentity(for: family)
    }
    return .init(name: String(describing: Candidate.self), executionKind: .unknown)
  }

  private func record(
    _ family: CBORLDComputeFamilyID,
    _ identity: CBORLDComputeBackendIdentity,
    _ parity: CBORLDShadowParityStatus,
    _ mismatch: CBORLDShadowMismatch?,
    _ workItemCount: Int,
    candidateDuration: Duration,
    referenceDuration: Duration?
  ) {
    let receipt = CBORLDShadowVerificationReceipt(
      family: family,
      contractVersion: family.contractVersion,
      candidate: identity,
      parity: parity,
      firstMismatch: mismatch,
      workItemCount: workItemCount,
      candidateDurationNanoseconds: candidateDuration.nanoseconds,
      referenceDurationNanoseconds: referenceDuration?.nanoseconds)
    log.append(receipt)
    receiptHandler?(receipt)
  }
}

// MARK: - Family conformances

extension CBORLDShadowVerifyingProvider: CBORLDComputeCapabilityReporting
where Candidate: CBORLDComputeCapabilityReporting {
  public var cborldComputeCapabilities: [CBORLDComputeFamilyCapability] {
    candidate.cborldComputeCapabilities
  }
}

extension CBORLDShadowVerifyingProvider: CBORLDBatchedSHA256Computing
where Candidate: CBORLDBatchedSHA256Computing {
  public func batchedSHA256(_ slices: [Data]) async throws -> [CBORLDSHA256Result] {
    try await verify(
      .batchedSHA256, workItemCount: slices.count,
      candidate: { try await candidate.batchedSHA256(slices) },
      reference: { try await reference.batchedSHA256(slices) },
      compare: ShadowComparison.elements)
  }
}

extension CBORLDShadowVerifyingProvider: CBORLDByteDiffComputing
where Candidate: CBORLDByteDiffComputing {
  public func batchedByteDiff(_ pairs: [CBORLDBytePair]) async throws -> [CBORLDByteDiffResult] {
    try await verify(
      .byteDiff, workItemCount: pairs.count,
      candidate: { try await candidate.batchedByteDiff(pairs) },
      reference: { try await reference.batchedByteDiff(pairs) },
      compare: ShadowComparison.elements)
  }
}

extension CBORLDShadowVerifyingProvider: CBORLDStructuralScanComputing
where Candidate: CBORLDStructuralScanComputing {
  public func batchedCBORStructuralScan(
    _ documents: [Data],
    limits: CBORLDDecodingLimits
  ) async throws -> [CBORLDStructuralScanResult] {
    try await verify(
      .structuralScan, workItemCount: documents.count,
      candidate: { try await candidate.batchedCBORStructuralScan(documents, limits: limits) },
      reference: { try await reference.batchedCBORStructuralScan(documents, limits: limits) },
      compare: ShadowComparison.elements)
  }
}

extension CBORLDShadowVerifyingProvider: CBORLDPrefixScanComputing
where Candidate: CBORLDPrefixScanComputing {
  public func exclusiveScanUInt32(
    _ values: [UInt32]
  ) async throws -> CBORLDExclusiveScanUInt32Result {
    try await verify(
      .prefixScan, workItemCount: 1,
      candidate: { try await candidate.exclusiveScanUInt32(values) },
      reference: { try await reference.exclusiveScanUInt32(values) },
      compare: ShadowComparison.single)
  }

  public func exclusiveScanUInt64(
    _ values: [UInt64]
  ) async throws -> CBORLDExclusiveScanUInt64Result {
    try await verify(
      .prefixScan, workItemCount: 1,
      candidate: { try await candidate.exclusiveScanUInt64(values) },
      reference: { try await reference.exclusiveScanUInt64(values) },
      compare: ShadowComparison.single)
  }

  public func compactByteSlices(_ slices: [Data]) async throws -> CBORLDByteCompactionResult {
    try await verify(
      .byteCompaction, workItemCount: slices.count,
      candidate: { try await candidate.compactByteSlices(slices) },
      reference: { try await reference.compactByteSlices(slices) },
      compare: ShadowComparison.single)
  }
}

extension CBORLDShadowVerifyingProvider: CBORLDByteStatisticsComputing
where Candidate: CBORLDByteStatisticsComputing {
  public func batchedByteStatistics(_ slices: [Data]) async throws -> [CBORLDByteStatistics] {
    try await verify(
      .byteStatistics, workItemCount: slices.count,
      candidate: { try await candidate.batchedByteStatistics(slices) },
      reference: { try await reference.batchedByteStatistics(slices) },
      compare: ShadowComparison.elements)
  }
}

extension CBORLDShadowVerifyingProvider: CBORLDCanonicalKeyOrderingComputing
where Candidate: CBORLDCanonicalKeyOrderingComputing {
  public func segmentedCanonicalKeyOrder(
    _ segments: [[Data]],
    ordering: CBORLDCanonicalKeyOrdering
  ) async throws -> [CBORLDCanonicalKeyOrderResult] {
    try await verify(
      .canonicalKeyOrdering, workItemCount: segments.count,
      candidate: { try await candidate.segmentedCanonicalKeyOrder(segments, ordering: ordering) },
      reference: { try await reference.segmentedCanonicalKeyOrder(segments, ordering: ordering) },
      compare: ShadowComparison.elements)
  }
}

extension CBORLDShadowVerifyingProvider: CBORLDUTF8ValidationComputing
where Candidate: CBORLDUTF8ValidationComputing {
  public func batchedUTF8Validation(_ slices: [Data]) async throws -> [CBORLDUTF8ValidationResult] {
    try await verify(
      .utf8Validation, workItemCount: slices.count,
      candidate: { try await candidate.batchedUTF8Validation(slices) },
      reference: { try await reference.batchedUTF8Validation(slices) },
      compare: ShadowComparison.elements)
  }
}

extension CBORLDShadowVerifyingProvider: CBORLDMultibaseComputing
where Candidate: CBORLDMultibaseComputing {
  public func batchedMultibaseEncode(
    _ values: [Data],
    as encoding: CBORLDMultibaseEncoding,
    maximumInputBytes: Int
  ) async throws -> [String] {
    try await verify(
      .multibaseCodec, workItemCount: values.count,
      candidate: {
        try await candidate.batchedMultibaseEncode(
          values, as: encoding, maximumInputBytes: maximumInputBytes)
      },
      reference: {
        try await reference.batchedMultibaseEncode(
          values, as: encoding, maximumInputBytes: maximumInputBytes)
      },
      compare: ShadowComparison.elements)
  }

  public func batchedMultibaseDecode(
    _ values: [String],
    maximumInputBytes: Int
  ) async throws -> [CBORLDMultibaseDecodeResult] {
    try await verify(
      .multibaseCodec, workItemCount: values.count,
      candidate: {
        try await candidate.batchedMultibaseDecode(values, maximumInputBytes: maximumInputBytes)
      },
      reference: {
        try await reference.batchedMultibaseDecode(values, maximumInputBytes: maximumInputBytes)
      },
      compare: ShadowComparison.elements)
  }
}

extension CBORLDShadowVerifyingProvider: CBORLDUnsignedVarintComputing
where Candidate: CBORLDUnsignedVarintComputing {
  public func batchedUnsignedVarintEncode(_ values: [UInt64]) async throws -> [Data] {
    try await verify(
      .unsignedVarint, workItemCount: values.count,
      candidate: { try await candidate.batchedUnsignedVarintEncode(values) },
      reference: { try await reference.batchedUnsignedVarintEncode(values) },
      compare: ShadowComparison.elements)
  }

  public func batchedUnsignedVarintDecode(
    _ values: [Data]
  ) async throws -> [CBORLDUnsignedVarintDecodeResult] {
    try await verify(
      .unsignedVarint, workItemCount: values.count,
      candidate: { try await candidate.batchedUnsignedVarintDecode(values) },
      reference: { try await reference.batchedUnsignedVarintDecode(values) },
      compare: ShadowComparison.elements)
  }
}

extension CBORLDShadowVerifyingProvider: CBORLDDictionaryProbeComputing
where Candidate: CBORLDDictionaryProbeComputing {
  public func batchedDictionaryProbe(
    _ probes: [CBORLDDictionaryProbe],
    dictionary: CBORLDDocumentDictionary,
    requiredFingerprint: CBORLDDigest
  ) async throws -> [CBORLDDictionaryProbeResult] {
    try await verify(
      .dictionaryProbe, workItemCount: probes.count,
      candidate: {
        try await candidate.batchedDictionaryProbe(
          probes, dictionary: dictionary, requiredFingerprint: requiredFingerprint)
      },
      reference: {
        try await reference.batchedDictionaryProbe(
          probes, dictionary: dictionary, requiredFingerprint: requiredFingerprint)
      },
      compare: ShadowComparison.elements)
  }
}

extension CBORLDShadowVerifyingProvider: CBORLDWholeDocumentTransformComputing
where Candidate: CBORLDWholeDocumentTransformComputing {
  public func batchedWholeDocumentTransform(
    _ requests: [CBORLDWholeDocumentTransformRequest]
  ) async throws -> [CBORLDWholeDocumentTransformResult] {
    try await verify(
      .wholeDocumentTransform, workItemCount: requests.count,
      candidate: { try await candidate.batchedWholeDocumentTransform(requests) },
      reference: { try await reference.batchedWholeDocumentTransform(requests) },
      compare: {
        ShadowComparison.elements(
          $0.map(WholeDocumentFields.init), $1.map(WholeDocumentFields.init))
      })
  }
}

extension CBORLDShadowVerifyingProvider: CBORLDCDDLValidationComputing
where Candidate: CBORLDCDDLValidationComputing {
  public func batchedCDDLValidation(
    _ requests: [CBORLDCDDLValidationRequest]
  ) async throws -> [CBORLDCDDLValidationResult] {
    try await verify(
      .cddlValidation, workItemCount: requests.count,
      candidate: { try await candidate.batchedCDDLValidation(requests) },
      reference: { try await reference.batchedCDDLValidation(requests) },
      compare: ShadowComparison.elements)
  }
}

extension CBORLDShadowVerifyingProvider: CBORLDComputeProvider
where Candidate: CBORLDComputeProvider {}

// MARK: - Support

extension CBORLDComputeFamilyID {
  /// The contract version encoded in the identifier's `.vN` suffix.
  public var contractVersion: Int {
    guard let suffix = rawValue.split(separator: ".").last, suffix.first == "v" else { return 0 }
    return Int(suffix.dropFirst()) ?? 0
  }
}

/// The comparable content of a whole-document result.
private struct WholeDocumentFields: Hashable {
  let operation: CBORLDWholeDocumentTransformOperation
  let jsonLDDocument: JSONValue?
  let cborldBytes: Data?
  let outputByteCount: Int
  let transportDigest: CBORLDDigest
  let inspection: CBORLDInspection

  init(_ result: CBORLDWholeDocumentTransformResult) {
    operation = result.operation
    jsonLDDocument = result.jsonLDDocument
    cborldBytes = result.cborldBytes
    outputByteCount = result.outputByteCount
    transportDigest = result.transportDigest
    inspection = result.inspection
  }
}

enum ShadowComparison {
  static func single<Value: Hashable>(_ candidate: Value, _ reference: Value)
    -> CBORLDShadowMismatch?
  {
    guard candidate != reference else { return nil }
    return .init(
      workItemIndex: nil, field: firstDifferingField(candidate, reference),
      cardinalityDiffers: false)
  }

  static func elements<Value: Hashable>(_ candidate: [Value], _ reference: [Value])
    -> CBORLDShadowMismatch?
  {
    for (index, (left, right)) in zip(candidate, reference).enumerated() where left != right {
      return .init(
        workItemIndex: index, field: firstDifferingField(left, right), cardinalityDiffers: false)
    }
    guard candidate.count == reference.count else {
      return .init(
        workItemIndex: min(candidate.count, reference.count), field: nil, cardinalityDiffers: true)
    }
    return nil
  }

  /// Names the first stored property that differs, using reflection only on
  /// the mismatch path.
  static func firstDifferingField<Value>(_ candidate: Value, _ reference: Value) -> String? {
    let left = Mirror(reflecting: candidate)
    let right = Mirror(reflecting: reference)
    for (leftChild, rightChild) in zip(left.children, right.children) {
      guard let label = leftChild.label else { continue }
      let same: Bool
      if let leftValue = leftChild.value as? AnyHashable,
        let rightValue = rightChild.value as? AnyHashable
      {
        same = leftValue == rightValue
      } else {
        same = String(describing: leftChild.value) == String(describing: rightChild.value)
      }
      if !same { return label }
    }
    return nil
  }
}

/// A bounded, thread-safe receipt log and call counter.
private final class ReceiptLog: @unchecked Sendable {
  private let lock = NSLock()
  private let capacity: Int
  private var receipts: [CBORLDShadowVerificationReceipt] = []
  private var calls: UInt64 = 0

  init(capacity: Int) {
    self.capacity = capacity
  }

  func shouldSample(_ policy: CBORLDShadowVerificationPolicy) -> Bool {
    lock.lock()
    let call = calls
    calls &+= 1
    lock.unlock()
    switch policy {
    case .disabled:
      return false
    case .always:
      return true
    case .deterministicSample(let rate, let seed):
      guard rate > 0 else { return false }
      guard rate < 1 else { return true }
      // SplitMix64 of the seed and call number, as a fraction in [0, 1).
      var value = seed &+ 0x9e37_79b9_7f4a_7c15 &* (call &+ 1)
      value = (value ^ (value >> 30)) &* 0xbf58_476d_1ce4_e5b9
      value = (value ^ (value >> 27)) &* 0x94d0_49bb_1331_11eb
      value ^= value >> 31
      return Double(value >> 11) / Double(UInt64(1) << 53) < rate
    }
  }

  func append(_ receipt: CBORLDShadowVerificationReceipt) {
    guard capacity > 0 else { return }
    lock.lock()
    receipts.append(receipt)
    if receipts.count > capacity { receipts.removeFirst(receipts.count - capacity) }
    lock.unlock()
  }

  func snapshot() -> [CBORLDShadowVerificationReceipt] {
    lock.lock()
    defer { lock.unlock() }
    return receipts
  }
}

extension Duration {
  fileprivate var nanoseconds: UInt64 {
    let components = self.components
    let seconds = UInt64(max(0, components.seconds))
    let (whole, overflow) = seconds.multipliedReportingOverflow(by: 1_000_000_000)
    guard !overflow else { return .max }
    return whole &+ UInt64(max(0, components.attoseconds)) / 1_000_000_000
  }
}
