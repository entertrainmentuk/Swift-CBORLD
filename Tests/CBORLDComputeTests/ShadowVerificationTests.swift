import CBORLD
import Foundation
import XCTest

@testable import CBORLDCompute

final class ShadowVerificationTests: XCTestCase {
  private let slices = [Data(), Data("abc".utf8), Data(repeating: 7, count: 200)]

  func testCPUCandidateIsRecordedAsCPUExecutionNotAcceleration() async throws {
    let shadow = CBORLDShadowVerifyingProvider(candidate: CBORLDCPUComputeProvider())
    let digests = try await CBORLD.batchedTransportDigests(of: slices, using: shadow)
    XCTAssertEqual(digests, slices.map { CBORLD.transportDigest(of: $0) })
    let receipt = try XCTUnwrap(shadow.receipts().last)
    XCTAssertEqual(receipt.family, .batchedSHA256)
    XCTAssertEqual(receipt.contractVersion, 1)
    XCTAssertEqual(receipt.parity, .match)
    XCTAssertEqual(receipt.workItemCount, 3)
    XCTAssertEqual(receipt.candidate.executionKind, .cpuReference)
    XCTAssertTrue(receipt.isCPUExecution)
    XCTAssertFalse(receipt.isAccelerationEvidence)
    XCTAssertNotNil(receipt.referenceDurationNanoseconds)
  }

  func testMismatchIsLocatedAndEitherThrownOrReplacedByTheReference() async throws {
    let strict = CBORLDShadowVerifyingProvider(candidate: CorruptingBackend())
    do {
      _ = try await strict.batchedSHA256(slices)
      XCTFail("Expected a parity mismatch.")
    } catch let error as CBORLDError {
      XCTAssertEqual(error.code, .shadowParityMismatch)
      XCTAssertTrue(error.message.contains("work item 1"), error.message)
    }
    let receipt = try XCTUnwrap(strict.receipts().last)
    XCTAssertEqual(receipt.parity, .mismatch)
    XCTAssertEqual(receipt.firstMismatch?.workItemIndex, 1)
    XCTAssertEqual(receipt.firstMismatch?.field, "stateWords")
    XCTAssertFalse(receipt.isAccelerationEvidence)

    let failSafe = CBORLDShadowVerifyingProvider(
      candidate: CorruptingBackend(), onMismatch: .returnReference)
    let results = try await failSafe.batchedSHA256(slices)
    XCTAssertEqual(results, slices.map(CBORLDCPUComputeProvider.sha256))
    XCTAssertEqual(failSafe.receipts().last?.parity, .mismatch)

    let short = CBORLDShadowVerifyingProvider(candidate: ShortBackend())
    await assertThrows { _ = try await short.batchedByteStatistics(self.slices) }
    XCTAssertEqual(short.receipts().last?.firstMismatch?.cardinalityDiffers, true)
    XCTAssertEqual(short.receipts().last?.firstMismatch?.workItemIndex, 2)
  }

  func testReportedAcceleratorExecutionIsEvidenceOnlyWhenObservedAndMatching() async throws {
    for observed in [true, false] {
      let shadow = CBORLDShadowVerifyingProvider(
        candidate: DescribedBackend(kind: .metal, observed: observed))
      _ = try await shadow.batchedUTF8Validation(slices)
      let receipt = try XCTUnwrap(shadow.receipts().last)
      XCTAssertEqual(receipt.candidate.name, "Example Metal backend")
      XCTAssertEqual(receipt.candidate.version, "2.0")
      XCTAssertEqual(receipt.isAccelerationEvidence, observed)
      XCTAssertFalse(receipt.isCPUExecution)
    }
    let fallback = CBORLDShadowVerifyingProvider(
      candidate: DescribedBackend(kind: .cpuFallback, observed: true))
    _ = try await fallback.batchedUTF8Validation(slices)
    XCTAssertEqual(fallback.receipts().last?.isCPUExecution, true)
    XCTAssertEqual(fallback.receipts().last?.isAccelerationEvidence, false)

    let undescribed = CBORLDShadowVerifyingProvider(candidate: CorruptingBackend())
    _ = try await undescribed.batchedByteDiff([CBORLDBytePair(Data([1]), Data([2]))])
    XCTAssertEqual(undescribed.receipts().last?.candidate.executionKind, .unknown)
  }

  func testDeterministicSamplingIsReproducible() async throws {
    func pattern(seed: UInt64) async throws -> [CBORLDShadowParityStatus] {
      let shadow = CBORLDShadowVerifyingProvider(
        candidate: CBORLDCPUComputeProvider(),
        policy: .deterministicSample(rate: 0.5, seed: seed))
      for _ in 0..<100 { _ = try await shadow.batchedUnsignedVarintEncode([1, 300]) }
      return shadow.receipts().map(\.parity)
    }
    let first = try await pattern(seed: 42)
    let again = try await pattern(seed: 42)
    let other = try await pattern(seed: 7)
    XCTAssertEqual(first, again)
    XCTAssertNotEqual(first, other)
    let sampled = first.filter { $0 == .match }.count
    XCTAssertTrue((30...70).contains(sampled), "\(sampled) of 100 calls were verified.")
    XCTAssertEqual(first.filter { $0 == .notSampled }.count, 100 - sampled)

    let disabled = CBORLDShadowVerifyingProvider(
      candidate: CorruptingBackend(), policy: .disabled)
    let unverified = try await disabled.batchedSHA256(slices)
    XCTAssertNotEqual(unverified, slices.map(CBORLDCPUComputeProvider.sha256))
    XCTAssertEqual(disabled.receipts().last?.parity, .notSampled)
    XCTAssertNil(disabled.receipts().last?.referenceDurationNanoseconds)
  }

  func testCandidateFailureAndUnavailableReferenceAreRecorded() async throws {
    let failing = CBORLDShadowVerifyingProvider(candidate: FailingBackend())
    await assertThrows { _ = try await failing.batchedSHA256(self.slices) }
    XCTAssertEqual(failing.receipts().last?.parity, .candidateFailed)

    // The default reference has no CDDL oracle, so parity cannot be checked
    // and the candidate's result is returned unverified.
    let request = CBORLDCDDLValidationRequest(
      schema: "root = uint", document: Data([0x01]), documentEncoding: .cbor)
    let cddl = CBORLDShadowVerifyingProvider(candidate: CDDLBackend())
    let results = try await CBORLD.batchedCDDLValidation([request], using: cddl)
    XCTAssertEqual(results.first?.documentIsValid, true)
    XCTAssertEqual(cddl.receipts().last?.parity, .referenceUnavailable)
  }

  func testReceiptsAreBoundedHandledAndCodable() async throws {
    let seen = ReceiptCounter()
    let shadow = CBORLDShadowVerifyingProvider(
      candidate: CBORLDCPUComputeProvider(),
      maximumRetainedReceipts: 3,
      receiptHandler: { _ in seen.increment() })
    for value in 0..<5 { _ = try await shadow.exclusiveScanUInt32([UInt32(value), 1]) }
    XCTAssertEqual(shadow.receipts().count, 3)
    XCTAssertEqual(seen.value, 5)
    XCTAssertEqual(shadow.receipts().first?.family, .prefixScan)

    let receipt = try XCTUnwrap(shadow.receipts().last)
    let decoded = try JSONDecoder().decode(
      CBORLDShadowVerificationReceipt.self, from: JSONEncoder().encode(receipt))
    XCTAssertEqual(decoded, receipt)
    XCTAssertEqual(shadow.cborldComputeCapabilities.count, CBORLDComputeFamilyID.allCases.count)
    XCTAssertTrue(CBORLDComputeFamilyID.allCases.allSatisfy { $0.contractVersion == 1 })
  }

  func testEveryFamilyIsVerifiedThroughItsAcceptanceFacade() async throws {
    let shadow = CBORLDShadowVerifyingProvider(candidate: CBORLDCPUComputeProvider())
    let provider: any CBORLDComputeProvider = shadow
    XCTAssertEqual(provider.cborldComputeCapabilities.count, CBORLDComputeFamilyID.allCases.count)

    _ = try await CBORLD.batchedTransportDigests(of: slices, using: shadow)
    _ = try await CBORLD.batchedByteDiff([CBORLDBytePair(Data([1, 2]), Data([1]))], using: shadow)
    _ = try await CBORLD.batchedCBORStructuralScan([Data([0x80])], using: shadow)
    _ = try await CBORLD.exclusiveScanUInt32([1, 2], using: shadow)
    _ = try await CBORLD.exclusiveScanUInt64([1, 2], using: shadow)
    _ = try await CBORLD.compactByteSlices(slices, using: shadow)
    _ = try await CBORLD.batchedByteStatistics(slices, using: shadow)
    _ = try await CBORLD.segmentedCanonicalKeyOrder(
      [[Data([0x61]), Data([0x01])]], ordering: .bytewise, using: shadow)
    _ = try await CBORLD.batchedUTF8Validation(slices, using: shadow)
    let encoded = try await CBORLD.batchedMultibaseEncode(slices, as: .base58BTC, using: shadow)
    _ = try await CBORLD.batchedMultibaseDecode(encoded, using: shadow)
    let varints = try await CBORLD.batchedUnsignedVarintEncode([0, 300], using: shadow)
    _ = try await CBORLD.batchedUnsignedVarintDecode(varints, using: shadow)
    let dictionary = CBORLDDocumentDictionary(code: 42, contexts: ["urn:a": 32_768])
    _ = try await CBORLD.batchedDictionaryProbe(
      [CBORLDDictionaryProbe(table: "context", value: "urn:a")],
      dictionary: dictionary, requiredFingerprint: try dictionary.fingerprint(), using: shadow)
    _ = try await CBORLD.batchedWholeDocumentTransform(
      [.encoding(["a": 1]), .decoding(try CBORLD.encodeUncompressed(["b": 2]))], using: shadow)

    let receipts = shadow.receipts()
    XCTAssertTrue(receipts.allSatisfy { $0.parity == .match }, "\(receipts.map(\.parity))")
    let verified = Set(receipts.map(\.family))
    XCTAssertEqual(verified, Set(CBORLDComputeFamilyID.allCases).subtracting([.cddlValidation]))
  }

  private func assertThrows(
    file: StaticString = #filePath,
    line: UInt = #line,
    _ body: () async throws -> Void
  ) async {
    do {
      try await body()
      XCTFail("Expected an error.", file: file, line: line)
    } catch {
    }
  }
}

// MARK: - Test backends

/// Correct except that the second SHA-256 work item has a flipped state word.
private struct CorruptingBackend: CBORLDBatchedSHA256Computing, CBORLDByteDiffComputing {
  func batchedSHA256(_ slices: [Data]) async throws -> [CBORLDSHA256Result] {
    var results = slices.map(CBORLDCPUComputeProvider.sha256)
    if results.count > 1 {
      var words = results[1].stateWords
      words[0] ^= 1
      results[1] = CBORLDSHA256Result(
        inputByteCount: results[1].inputByteCount, stateWords: words, digest: results[1].digest)
    }
    return results
  }

  func batchedByteDiff(_ pairs: [CBORLDBytePair]) async throws -> [CBORLDByteDiffResult] {
    pairs.map { CBORLDCPUComputeProvider.byteDiff($0.left, $0.right) }
  }
}

/// Returns one result fewer than requested.
private struct ShortBackend: CBORLDByteStatisticsComputing {
  func batchedByteStatistics(_ slices: [Data]) async throws -> [CBORLDByteStatistics] {
    Array(slices.dropLast().map(CBORLDCPUComputeProvider.byteStatistics))
  }
}

/// A correct backend that reports its own execution facts.
private struct DescribedBackend: CBORLDUTF8ValidationComputing, CBORLDComputeBackendDescribing {
  let kind: CBORLDComputeExecutionKind
  let observed: Bool

  func batchedUTF8Validation(_ slices: [Data]) async throws -> [CBORLDUTF8ValidationResult] {
    slices.map(CBORLDCPUComputeProvider.validateUTF8)
  }

  func backendIdentity(for family: CBORLDComputeFamilyID) async -> CBORLDComputeBackendIdentity {
    .init(
      name: "Example Metal backend", version: "2.0", executionKind: kind,
      hardwareExecutionObserved: observed)
  }
}

private struct FailingBackend: CBORLDBatchedSHA256Computing {
  func batchedSHA256(_ slices: [Data]) async throws -> [CBORLDSHA256Result] {
    throw CBORLDError(code: .computeFamilyUnavailable, message: "Device lost.")
  }
}

private struct CDDLBackend: CBORLDCDDLValidationComputing {
  func batchedCDDLValidation(
    _ requests: [CBORLDCDDLValidationRequest]
  ) async throws -> [CBORLDCDDLValidationResult] {
    requests.map {
      CBORLDCDDLValidationResult(
        schemaByteCount: $0.schemaByteCount, documentByteCount: $0.document.count,
        schemaIsValid: true, documentIsValid: true, astNodeCount: 3,
        maximumValidationDepth: 1, diagnostics: [])
    }
  }
}

private final class ReceiptCounter: @unchecked Sendable {
  private let lock = NSLock()
  private var count = 0

  func increment() {
    lock.lock()
    count += 1
    lock.unlock()
  }

  var value: Int {
    lock.lock()
    defer { lock.unlock() }
    return count
  }
}
