import Foundation
import XCTest

@testable import CBORLD

final class ComputeFamiliesTests: XCTestCase {
  private let cpu = CBORLDCPUComputeProvider()

  func testCPUFamilyCatalogueIsCompleteAndUnique() {
    let contracts = CBORLDComputeFamilyContract.cborldCPUReferences
    XCTAssertEqual(contracts.count, CBORLDComputeFamilyID.allCases.count)
    XCTAssertEqual(Set(contracts.map(\.id)).count, contracts.count)
    XCTAssertTrue(contracts.allSatisfy { !$0.workItem.isEmpty && !$0.exactSemantics.isEmpty })

    let capabilities = cpu.cborldComputeCapabilities
    XCTAssertEqual(capabilities.count, contracts.count)
    XCTAssertEqual(
      capabilities.first(where: { $0.id == .cddlValidation })?.availability,
      .unavailable)
    XCTAssertEqual(
      CBORLDCPUComputeProvider(cddlOracle: StubCDDLOracle()).cborldComputeCapabilities.first(
        where: { $0.id == .cddlValidation })?.availability,
      .available)
  }

  func testPackedByteBatchBridgesUInt32SCBuffersWithoutLosingEmptySlices() throws {
    let slices = [Data([0, 1, 255]), Data(), Data("abc".utf8)]
    let packed = try CBORLDComputePackedByteBatch(slices: slices)
    XCTAssertEqual(packed.bytes, [0, 1, 255, 97, 98, 99])
    XCTAssertEqual(
      packed.spans,
      [
        .init(offset: 0, length: 3),
        .init(offset: 3, length: 0),
        .init(offset: 3, length: 3),
      ])
    XCTAssertEqual(try packed.slices(), slices)

    XCTAssertThrowsError(
      try CBORLDComputePackedByteBatch(
        bytes: [256],
        spans: [.init(offset: 0, length: 1)]))
  }

  func testAcceptanceFacadeRejectsMalformedProviderOutput() async throws {
    let input = [Data("abc".utf8)]
    let accepted = try await CBORLD.batchedTransportDigests(of: input, using: cpu)
    XCTAssertEqual(accepted, [CBORLD.transportDigest(of: input[0])])

    do {
      _ = try await CBORLD.batchedTransportDigests(of: input, using: MalformedSHAProvider())
      XCTFail("Expected malformed SHA output to be rejected")
    } catch let error as CBORLDError {
      XCTAssertEqual(error.code, "ERR_INVALID_COMPUTE_OUTPUT")
    }

    do {
      _ = try await CBORLD.batchedByteDiff(
        [.init(Data([1]), Data([2]))],
        using: EmptyByteDiffProvider())
      XCTFail("Expected missing byte-diff output to be rejected")
    } catch let error as CBORLDError {
      XCTAssertEqual(error.code, "ERR_INVALID_COMPUTE_OUTPUT")
    }

    do {
      _ = try await CBORLD.batchedCBORStructuralScan(
        [Data([0])],
        using: ContradictoryScanProvider())
      XCTFail("Expected contradictory scan output to be rejected")
    } catch let error as CBORLDError {
      XCTAssertEqual(error.code, "ERR_INVALID_COMPUTE_OUTPUT")
    }
  }

  func testBatchedSHA256MatchesNISTAndTransportReference() async throws {
    let messages = [
      Data(),
      Data("abc".utf8),
      Data("abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq".utf8),
      Data(repeating: 0x61, count: 1_000_000),
    ]
    let expected = [
      "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
      "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad",
      "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1",
      "cdc76e5c9914fb9281a1c7e284d73e67f1809a48a497200e046d39ccc7112cd0",
    ]

    let results = try await cpu.batchedSHA256(messages)
    XCTAssertEqual(results.count, messages.count)
    for index in messages.indices {
      XCTAssertEqual(results[index].inputByteCount, messages[index].count)
      XCTAssertEqual(results[index].stateWords.count, 8)
      XCTAssertEqual(results[index].digest.hex, expected[index])
      XCTAssertEqual(results[index].digest, CBORLD.transportDigest(of: messages[index]))
    }
  }

  func testByteDiffDefinesUnequalLengthAndFirstMismatch() async throws {
    let results = try await cpu.batchedByteDiff([
      .init(Data([0, 1, 2]), Data([0, 1, 2])),
      .init(Data([0, 1, 2]), Data([0, 9, 2])),
      .init(Data([1, 2]), Data([1, 2, 3, 4])),
      .init(Data([1, 9, 3, 4]), Data([1, 2])),
    ])
    XCTAssertEqual(results[0].mismatchCount, 0)
    XCTAssertNil(results[0].firstMismatchOffset)
    XCTAssertEqual(results[1].mismatchCount, 1)
    XCTAssertEqual(results[1].firstMismatchOffset, 1)
    XCTAssertEqual(results[2].mismatchCount, 2)
    XCTAssertEqual(results[2].firstMismatchOffset, 2)
    XCTAssertEqual(results[3].mismatchCount, 3)
    XCTAssertEqual(results[3].firstMismatchOffset, 1)
  }

  func testBatchedCBORStructuralScanReportsExactMetricsAndOffsets() async throws {
    let validMap = Data(computeHex: "a26161016162820203")
    let envelope = Data(computeHex: "d9cb1d8200a0")
    let scans = try await cpu.batchedCBORStructuralScan([validMap, envelope, Data([0xf0])])

    XCTAssertTrue(scans[0].isValid)
    XCTAssertEqual(scans[0].maximumDepth, 2)
    XCTAssertEqual(scans[0].itemCount, 7)
    XCTAssertTrue(scans[1].isValid)
    XCTAssertEqual(scans[1].maximumDepth, 2)
    XCTAssertEqual(scans[1].itemCount, 4)
    XCTAssertTrue(scans[2].isValid, "Unassigned simple values remain structurally valid CBOR.")

    for count in 0..<validMap.count {
      let truncated = Data(validMap.prefix(count))
      let result = try await cpu.batchedCBORStructuralScan([truncated])
      XCTAssertFalse(result[0].isValid, "truncation at \(count)")
      XCTAssertLessThanOrEqual(result[0].firstErrorOffset ?? Int.max, count)
    }

    let malformed = try await cpu.batchedCBORStructuralScan([
      Data(computeHex: "61ff"),
      validMap + Data([0]),
      Data(computeHex: "f81f"),
    ])
    XCTAssertEqual(malformed[0].firstErrorOffset, 1)
    XCTAssertEqual(malformed[1].firstErrorOffset, validMap.count)
    XCTAssertEqual(malformed[2].firstErrorOffset, 0)
  }

  func testStructuralScanHonorsLimitsAndIndefinitePolicy() async throws {
    let indefinite = Data(computeHex: "9f01ff")
    let accepted = try await cpu.batchedCBORStructuralScan([indefinite])
    XCTAssertTrue(accepted[0].isValid)
    XCTAssertEqual(accepted[0].itemCount, 2)
    XCTAssertEqual(accepted[0].maximumDepth, 1)

    let rejected = try await cpu.batchedCBORStructuralScan(
      [indefinite],
      limits: .init(allowsIndefiniteLengthItems: false))
    XCTAssertFalse(rejected[0].isValid)
    XCTAssertEqual(rejected[0].firstErrorOffset, 0)

    let depthLimited = try await cpu.batchedCBORStructuralScan(
      [Data(computeHex: "818100")],
      limits: .init(maximumNestingDepth: 0))
    XCTAssertFalse(depthLimited[0].isValid)
    XCTAssertEqual(depthLimited[0].errorCode, "ERR_RESOURCE_LIMIT")
    XCTAssertEqual(depthLimited[0].firstErrorOffset, 1)

    let duplicate = try await cpu.batchedCBORStructuralScan(
      [Data(computeHex: "a2616101616102")],
      limits: .init(rejectDuplicateMapKeys: true))
    XCTAssertFalse(duplicate[0].isValid)
    XCTAssertEqual(duplicate[0].firstErrorOffset, 4)
  }

  func testExactPrefixScansAndDeterministicCompaction() async throws {
    let scan32 = try await CBORLD.exclusiveScanUInt32([3, 0, 2], using: cpu)
    XCTAssertEqual(scan32.offsets, [0, 3, 3])
    XCTAssertEqual(scan32.total, 5)

    let scan64 = try await CBORLD.exclusiveScanUInt64([UInt64(UInt32.max), 2], using: cpu)
    XCTAssertEqual(scan64.offsets, [0, UInt64(UInt32.max)])
    XCTAssertEqual(scan64.total, UInt64(UInt32.max) + 2)

    do {
      _ = try await cpu.exclusiveScanUInt32([UInt32.max, 1])
      XCTFail("Expected exact UInt32 overflow")
    } catch let error as CBORLDError {
      XCTAssertEqual(error.code, "ERR_INTEGER_OVERFLOW")
    }

    let compacted = try await CBORLD.compactByteSlices(
      [Data("ab".utf8), Data(), Data("c".utf8)],
      using: cpu)
    XCTAssertEqual(compacted.offsets, [0, 2, 2, 3])
    XCTAssertEqual(compacted.bytes, Data("abc".utf8))
  }

  func testExactByteHistogramAndEntropy() async throws {
    let results = try await CBORLD.batchedByteStatistics(
      [Data([0, 1, 1, 255]), Data()],
      using: cpu)
    XCTAssertEqual(results[0].histogram.count, 256)
    XCTAssertEqual(results[0].histogram.reduce(0, +), results[0].byteCount)
    XCTAssertEqual(results[0].histogram[0], 1)
    XCTAssertEqual(results[0].histogram[1], 2)
    XCTAssertEqual(results[0].histogram[255], 1)
    XCTAssertEqual(results[0].shannonEntropyBitsPerByte, 1.5, accuracy: 0.000_000_1)
    XCTAssertEqual(results[1].histogram.reduce(0, +), 0)
    XCTAssertEqual(results[1].shannonEntropyBitsPerByte, 0)
  }

  func testSegmentedCanonicalOrderingDistinguishesProfilesAndIsStable() async throws {
    let keys = [
      Data(computeHex: "1864"), Data(computeHex: "20"), Data(computeHex: "20"),
    ]
    let lengthFirst = try await CBORLD.segmentedCanonicalKeyOrder(
      [keys, []], ordering: .lengthFirst, using: cpu)
    let bytewise = try await CBORLD.segmentedCanonicalKeyOrder(
      [keys], ordering: .bytewise, using: cpu)
    XCTAssertEqual(lengthFirst[0].orderedIndices, [1, 2, 0])
    XCTAssertTrue(lengthFirst[1].orderedIndices.isEmpty)
    XCTAssertEqual(bytewise[0].orderedIndices, [0, 1, 2])
  }

  func testBatchedUTF8ValidationCoversBoundaryFailures() async throws {
    let values = [
      Data("ASCII £ € 😀".utf8),
      Data([0xc0, 0x80]),
      Data([0xed, 0xa0, 0x80]),
      Data([0xf4, 0x90, 0x80, 0x80]),
      Data([0x80]),
      Data([0xe2, 0x82]),
    ]
    let results = try await CBORLD.batchedUTF8Validation(values, using: cpu)
    XCTAssertTrue(results[0].isValid)
    XCTAssertEqual(results.dropFirst().map(\.firstInvalidByteOffset), [0, 1, 1, 0, 0])
  }

  func testMultibaseCPUReferencePreservesZerosAndReportsInvalidOffsets() async throws {
    let bytes = Data([0, 0, 1, 2, 3])
    let base58 = try await CBORLD.batchedMultibaseEncode(
      [bytes], as: .base58BTC, using: cpu)[0]
    XCTAssertEqual(base58, "z11Ldp")
    let base64URL = try await CBORLD.batchedMultibaseEncode(
      [bytes], as: .base64URL, using: cpu)[0]
    let base64 = try await CBORLD.batchedMultibaseEncode(
      [bytes], as: .base64, using: cpu)[0]

    let decoded = try await CBORLD.batchedMultibaseDecode(
      [base58, base64URL, base64, "z0", "xabc", "uA"],
      using: cpu)
    XCTAssertEqual(decoded[0].decoded, bytes)
    XCTAssertEqual(decoded[1].decoded, bytes)
    XCTAssertEqual(decoded[2].decoded, bytes)
    XCTAssertEqual(decoded[3].firstInvalidByteOffset, 1)
    XCTAssertEqual(decoded[4].firstInvalidByteOffset, 0)
    XCTAssertEqual(decoded[5].firstInvalidByteOffset, 2)

    let bounded = try await CBORLD.batchedMultibaseDecode(
      [base58], maximumInputBytes: 2, using: cpu)
    XCTAssertNil(bounded[0].decoded)
    XCTAssertEqual(bounded[0].firstInvalidByteOffset, 2)
  }

  func testUnsignedVarintCPUReferenceHasExactOverflowAndTerminationRules() async throws {
    let values: [UInt64] = [0, 127, 128, 300, UInt64.max]
    let encoded = try await CBORLD.batchedUnsignedVarintEncode(values, using: cpu)
    let decoded = try await CBORLD.batchedUnsignedVarintDecode(encoded, using: cpu)
    XCTAssertEqual(decoded.map(\.value), values.map(Optional.some))
    XCTAssertTrue(decoded.allSatisfy { $0.firstErrorOffset == nil })

    let failures = try await CBORLD.batchedUnsignedVarintDecode(
      [
        Data(),
        Data([0]), Data([0]),
        Data(repeating: 0xff, count: 9) + Data([2]),
        Data([0x80]),
      ],
      using: cpu)
    XCTAssertEqual(failures[0].firstErrorOffset, 0)
    XCTAssertEqual(failures[1].value, 0)
    XCTAssertEqual(failures[2].value, 0)
    XCTAssertEqual(failures[3].firstErrorOffset, 9)
    XCTAssertEqual(failures[4].firstErrorOffset, 0)

    let trailing = try await CBORLD.batchedUnsignedVarintDecode([Data([0, 1])], using: cpu)
    XCTAssertEqual(trailing[0].firstErrorOffset, 1)
  }

  func testDictionaryProbeRequiresValidatedImmutableIdentity() async throws {
    let dictionary = CBORLDDocumentDictionary(
      code: 42,
      contexts: ["https://example.com/context": 32_768],
      typedValues: ["https://example.com/Status": ["ready": 32_769]],
      uris: ["https://example.com/value": 32_770],
      untypedValues: ["common": 32_771])
    let fingerprint = try dictionary.fingerprint()
    let probes = [
      CBORLDDictionaryProbe(table: "context", value: "https://example.com/context"),
      CBORLDDictionaryProbe(table: "url", value: "https://example.com/value"),
      CBORLDDictionaryProbe(table: "none", value: "common"),
      CBORLDDictionaryProbe(table: "https://example.com/Status", value: "ready"),
      CBORLDDictionaryProbe(table: "none", value: "missing"),
    ]
    let results = try await CBORLD.batchedDictionaryProbe(
      probes,
      dictionary: dictionary,
      requiredFingerprint: fingerprint,
      using: cpu)
    XCTAssertEqual(results.map(\.identifier), [32_768, 32_770, 32_771, 32_769, nil])

    let wrongFingerprint = try CBORLDDocumentDictionary(code: 43).fingerprint()
    await assertThrowsErrorAsync {
      _ = try await self.cpu.batchedDictionaryProbe(
        probes,
        dictionary: dictionary,
        requiredFingerprint: wrongFingerprint)
    }
  }

  func testWholeDocumentFamilyUsesExistingCPUProcessorAndValidatesResults() async throws {
    let document: JSONValue = [
      "@context": ["name": "https://schema.org/name"],
      "name": "Ada",
    ]
    let configuration = CBORLDWholeDocumentTransformConfiguration(
      dictionary: .init(code: 0),
      maximumOutputBytes: 4_096)
    let encoded = try await CBORLD.batchedWholeDocumentTransform(
      [.encoding(document, configuration: configuration)],
      using: cpu)
    let bytes = try XCTUnwrap(encoded[0].cborldBytes)
    XCTAssertEqual(encoded[0].transportDigest, CBORLD.transportDigest(of: bytes))

    let decoded = try await CBORLD.batchedWholeDocumentTransform(
      [.decoding(bytes, configuration: configuration)],
      using: cpu)
    XCTAssertEqual(decoded[0].jsonLDDocument, document)
    XCTAssertEqual(decoded[0].transportDigest, encoded[0].transportDigest)

    let contextURL = "urn:compute-context"
    let remoteContext: JSONValue = [
      "@context": ["name": "https://schema.org/name"]
    ]
    let remoteDocument: JSONValue = [
      "@context": .string(contextURL),
      "name": "Grace",
    ]
    let remoteDictionary = CBORLDDocumentDictionary(
      code: 42,
      contexts: [contextURL: 32_768])
    let remoteConfiguration = CBORLDWholeDocumentTransformConfiguration(
      dictionary: remoteDictionary,
      requiredDictionaryFingerprint: try remoteDictionary.fingerprint(),
      requiredContextFingerprints: [
        contextURL: try CBORLD.contextFingerprint(of: remoteContext)
      ])
    let remoteCPU = CBORLDCPUComputeProvider(documentLoader: { _ in remoteContext })
    let remoteEncoded = try await CBORLD.batchedWholeDocumentTransform(
      [.encoding(remoteDocument, configuration: remoteConfiguration)],
      using: remoteCPU)
    let remoteBytes = try XCTUnwrap(remoteEncoded[0].cborldBytes)
    let remoteDecoded = try await CBORLD.batchedWholeDocumentTransform(
      [.decoding(remoteBytes, configuration: remoteConfiguration)],
      using: remoteCPU)
    XCTAssertEqual(remoteDecoded[0].jsonLDDocument, remoteDocument)

    let unpinnedDictionary = CBORLDWholeDocumentTransformConfiguration(
      dictionary: .init(code: 42, contexts: ["https://example.test/context": 32_768]))
    await assertThrowsErrorAsync {
      _ = try await self.cpu.batchedWholeDocumentTransform([
        .encoding(document, configuration: unpinnedDictionary)
      ])
    }

    do {
      _ = try await CBORLD.batchedWholeDocumentTransform(
        [.encoding(document, configuration: configuration)],
        using: MalformedWholeDocumentProvider())
      XCTFail("Expected malformed whole-document output to be rejected")
    } catch let error as CBORLDError {
      XCTAssertEqual(error.code, "ERR_INVALID_COMPUTE_OUTPUT")
    }
  }

  func testCDDLFamilyHasBoundedABIAndExplicitCPUOracle() async throws {
    let request = CBORLDCDDLValidationRequest(
      schema: "root = uint",
      rootRule: "root",
      document: Data([0x01]),
      documentEncoding: .cbor)

    await assertThrowsErrorAsync {
      _ = try await self.cpu.batchedCDDLValidation([request])
    }

    let provider = CBORLDCPUComputeProvider(cddlOracle: StubCDDLOracle())
    let results = try await CBORLD.batchedCDDLValidation([request], using: provider)
    XCTAssertTrue(results[0].schemaIsValid)
    XCTAssertTrue(results[0].documentIsValid)
    XCTAssertEqual(results[0].schemaByteCount, request.schemaByteCount)

    do {
      _ = try await CBORLD.batchedCDDLValidation(
        [request],
        using: MalformedCDDLProvider())
      XCTFail("Expected malformed CDDL output to be rejected")
    } catch let error as CBORLDError {
      XCTAssertEqual(error.code, "ERR_INVALID_COMPUTE_OUTPUT")
    }
  }
}

private func assertThrowsErrorAsync(
  _ expression: () async throws -> Void,
  file: StaticString = #filePath,
  line: UInt = #line
) async {
  do {
    try await expression()
    XCTFail("Expected expression to throw", file: file, line: line)
  } catch {}
}

extension Data {
  fileprivate init(computeHex: String) {
    self.init()
    var index = computeHex.startIndex
    while index < computeHex.endIndex {
      let next = computeHex.index(index, offsetBy: 2)
      append(UInt8(computeHex[index..<next], radix: 16)!)
      index = next
    }
  }
}

private struct MalformedSHAProvider: CBORLDBatchedSHA256Computing {
  func batchedSHA256(_ slices: [Data]) async throws -> [CBORLDSHA256Result] {
    let reference = CBORLDCPUComputeProvider.sha256(slices[0])
    return [
      .init(
        inputByteCount: slices[0].count,
        stateWords: Array(reference.stateWords.dropLast()),
        digest: reference.digest)
    ]
  }
}

private struct EmptyByteDiffProvider: CBORLDByteDiffComputing {
  func batchedByteDiff(_ pairs: [CBORLDBytePair]) async throws -> [CBORLDByteDiffResult] {
    []
  }
}

private struct ContradictoryScanProvider: CBORLDStructuralScanComputing {
  func batchedCBORStructuralScan(
    _ documents: [Data],
    limits: CBORLDDecodingLimits
  ) async throws -> [CBORLDStructuralScanResult] {
    [
      .init(
        byteCount: documents[0].count,
        isValid: true,
        firstErrorOffset: 0,
        maximumDepth: 0,
        itemCount: 1,
        errorCode: "ERR_NOT_CBOR",
        message: "contradictory")
    ]
  }
}

private struct MalformedWholeDocumentProvider: CBORLDWholeDocumentTransformComputing {
  func batchedWholeDocumentTransform(
    _ requests: [CBORLDWholeDocumentTransformRequest]
  ) async throws -> [CBORLDWholeDocumentTransformResult] {
    let bytes = Data(computeHex: "d9cb1d8200a0")
    return [
      .init(
        operation: .encode,
        cborldBytes: bytes,
        outputByteCount: bytes.count + 1,
        transportDigest: CBORLD.transportDigest(of: bytes),
        inspection: try CBORLD.inspect(bytes))
    ]
  }
}

private struct StubCDDLOracle: CBORLDCDDLCPUOracle {
  func validateCDDL(
    _ request: CBORLDCDDLValidationRequest
  ) async throws -> CBORLDCDDLValidationResult {
    .init(
      schemaByteCount: request.schemaByteCount,
      documentByteCount: request.document.count,
      schemaIsValid: true,
      documentIsValid: true,
      astNodeCount: 2,
      maximumValidationDepth: 1,
      diagnostics: [])
  }
}

private struct MalformedCDDLProvider: CBORLDCDDLValidationComputing {
  func batchedCDDLValidation(
    _ requests: [CBORLDCDDLValidationRequest]
  ) async throws -> [CBORLDCDDLValidationResult] {
    [
      .init(
        schemaByteCount: requests[0].schemaByteCount,
        documentByteCount: requests[0].document.count,
        schemaIsValid: false,
        documentIsValid: true,
        astNodeCount: 0,
        maximumValidationDepth: 0,
        diagnostics: [])
    ]
  }
}
