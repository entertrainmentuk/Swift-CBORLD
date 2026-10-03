import Foundation
import XCTest

@testable import CBORLD

final class AdvancedAPITests: XCTestCase {
  func testStrictPolicyReportsStableCodesAndOffsets() throws {
    let nonPreferredInteger = Data(testHex: "d9cb1d821800a0")
    XCTAssertEqual(try CBORLD.inspect(nonPreferredInteger).registryEntryID, 0)
    XCTAssertThrowsError(
      try CBORLD.inspect(
        nonPreferredInteger,
        limits: .strict,
        policy: .strict)
    ) { error in
      let error = error as? CBORLDError
      XCTAssertEqual(error?.code, "ERR_NON_PREFERRED_INTEGER")
      XCTAssertEqual(error?.diagnostic?.byteOffset, 4)
      XCTAssertEqual(error?.diagnostic?.majorType, 0)
    }

    let nonPreferredLength = Data(testHex: "d9cb1d980200a0")
    XCTAssertThrowsError(
      try CBORLD.inspect(
        nonPreferredLength,
        policy: .init(rejectNonPreferredLengthWidths: true))
    ) { error in
      XCTAssertEqual((error as? CBORLDError)?.code, "ERR_NON_PREFERRED_LENGTH")
      XCTAssertEqual((error as? CBORLDError)?.diagnostic?.byteOffset, 3)
    }

    let wideFloat = Data(testHex: "d9cb1d8200fb3ff0000000000000")
    XCTAssertThrowsError(
      try CBORLD.inspect(
        wideFloat,
        policy: .init(rejectNonPreferredFloatingPoint: true))
    ) { error in
      XCTAssertEqual((error as? CBORLDError)?.code, "ERR_NON_PREFERRED_FLOAT")
      XCTAssertEqual((error as? CBORLDError)?.diagnostic?.byteOffset, 5)
    }
  }

  func testStrictDeterministicPolicyRejectsMapOrderAndDuplicateLocation() throws {
    let wrongOrder = Data(testHex: "d9cb1d8200a262616100616200")
    XCTAssertNoThrow(try CBORLD.inspect(wrongOrder))
    XCTAssertThrowsError(
      try CBORLD.inspect(
        wrongOrder,
        policy: .init(requiredSerializationMode: .lengthFirstDeterministic))
    ) { error in
      XCTAssertEqual((error as? CBORLDError)?.code, "ERR_NON_PREFERRED_CBOR")
      XCTAssertNotNil((error as? CBORLDError)?.diagnostic?.byteOffset)
    }

    let duplicate = Data(testHex: "d9cb1d8200a2616101616102")
    XCTAssertThrowsError(
      try CBORLD.inspect(
        duplicate,
        limits: .init(rejectDuplicateMapKeys: true))
    ) { error in
      let error = error as? CBORLDError
      XCTAssertEqual(error?.code, "ERR_NOT_CBORLD")
      XCTAssertEqual(error?.diagnostic?.byteOffset, 9)
      XCTAssertEqual(error?.diagnostic?.relatedByteOffset, 6)
    }
  }

  func testLosslessValidationPreservesIndefiniteBytesNodesAndReservedSimpleValues() async throws {
    let indefinite = Data(testHex: "d9cb1d82009f01ff")
    let document = try CBORLD.validateLossless(indefinite)
    XCTAssertEqual(document.originalBytes, indefinite)
    XCTAssertEqual(try document.bytes(for: document.nodes[0]), indefinite)
    XCTAssertTrue(document.nodes.contains(where: { $0.isIndefiniteLength }))
    let decoded = try await CBORLD.decode(document, options: .init())
    XCTAssertEqual(decoded, [1])
    XCTAssertThrowsError(
      try CBORLD.validateLossless(
        indefinite,
        limits: .strict,
        policy: .strict))

    let simple = Data(testHex: "d9cb1d8200e0")
    let simplePolicy = CBORLDDecodingPolicy(
      allowsReservedSimpleValuesInLosslessMode: true)
    let preserved = try CBORLD.validateLossless(simple, policy: simplePolicy)
    XCTAssertEqual(preserved.originalBytes, simple)
    XCTAssertTrue(preserved.nodes.contains(where: { $0.majorType == 7 }))
    await assertThrowsErrorAsync {
      _ = try await CBORLD.decode(
        preserved,
        options: .init(policy: simplePolicy))
    }
  }

  func testLosslessNodeReportingIsBoundedWithoutStoppingValidation() throws {
    let bytes = Data(testHex: "d9cb1d8200850001020304")
    let document = try CBORLD.validateLossless(
      bytes,
      limits: .init(maximumDiagnosticNodes: 2))
    XCTAssertEqual(document.nodes.count, 2)
    XCTAssertTrue(document.nodesWereTruncated)
    XCTAssertEqual(document.inspection.byteCount, bytes.count)
  }

  func testDirectValueDecoderHandlesNestedModelsAndFoundationDefaults() throws {
    struct Model: Codable, Equatable {
      var name: String
      var count: UInt16
      var flags: [Bool]
      var created: Date
      var payload: Data
      var website: URL
      var optional: String?
    }
    let created = Date(timeIntervalSinceReferenceDate: 123.5)
    let payload = Data([0, 1, 2, 255])
    let value: JSONValue = [
      "name": "direct",
      "count": 42,
      "flags": [true, false],
      "created": 123.5,
      "payload": .string(payload.base64EncodedString()),
      "website": "https://example.com/path",
      "optional": nil,
    ]
    let decoded = try CBORLDValueDecoder().decode(Model.self, from: value)
    XCTAssertEqual(
      decoded,
      Model(
        name: "direct",
        count: 42,
        flags: [true, false],
        created: created,
        payload: payload,
        website: URL(string: "https://example.com/path")!,
        optional: nil))
  }

  func testPreparedSessionCachesPinnedContextsAndRoundTripsConcurrently() async throws {
    actor Counter {
      var value = 0
      func increment() { value += 1 }
    }
    let counter = Counter()
    let contextURL = "https://example.com/prepared-context"
    let context: JSONValue = [
      "@context": [
        "name": "https://example.com/name"
      ]
    ]
    let registry = CBORLDContextRegistry(
      expectedFingerprints: [contextURL: try CBORLD.contextFingerprint(of: context)],
      fallback: { _ in
        await counter.increment()
        try await Task.sleep(for: .milliseconds(5))
        return context
      })
    let dictionary = CBORLDDocumentDictionary(
      code: 42,
      contexts: [contextURL: 32_768])
    let encoder = try CBORLDPreparedEncoder(
      dictionary: dictionary,
      contextRegistry: registry)
    let decoder = try CBORLDPreparedDecoder(
      dictionaries: [dictionary],
      contextRegistry: registry)
    let documents: [JSONValue] = (0..<8).map { index in
      ["@context": .string(contextURL), "name": .string("record-\(index)")]
    }
    let encoded = try await encoder.encodeBatch(
      documents,
      policy: .init(
        maximumConcurrentTasks: 4,
        minimumParallelDocumentCount: 1,
        minimumParallelBytes: 0))
    let bytes = try encoded.map { outcome in
      try XCTUnwrap(outcome.value)
    }
    let decoded = try await decoder.decodeBatch(
      bytes,
      policy: .init(
        maximumConcurrentTasks: 4,
        minimumParallelDocumentCount: 1,
        minimumParallelBytes: 0,
        recordsTiming: true))
    XCTAssertEqual(decoded.compactMap(\.value), documents)
    XCTAssertTrue(decoded.allSatisfy { $0.observation?.durationNanoseconds != nil })
    let loadCount = await counter.value
    // The encoder and decoder each own one cache; all concurrent operations
    // within each session collapse to a single fallback load.
    XCTAssertEqual(loadCount, 2)
  }

  func testBatchPreservesOrderAndContainsPerDocumentFailures() async throws {
    let decoder = try CBORLDPreparedDecoder(dictionaries: [])
    let valid: [Data] = try (0..<5).map { index in
      try CBORLD.encodeUncompressed(.integer(Int64(index)))
    }
    var inputs = valid
    inputs.insert(Data([0xff]), at: 2)
    let outcomes = try await decoder.decodeBatch(
      inputs,
      policy: .init(
        maximumConcurrentTasks: 3,
        minimumParallelDocumentCount: 1,
        minimumParallelBytes: 0))
    XCTAssertEqual(outcomes.count, 6)
    XCTAssertEqual(outcomes[0].value, 0)
    XCTAssertEqual(outcomes[1].value, 1)
    XCTAssertEqual(outcomes[2].failure?.code, "ERR_NOT_CBORLD")
    XCTAssertEqual(outcomes[3].value, 2)
    XCTAssertEqual(outcomes[5].value, 4)

    await assertThrowsErrorAsync {
      _ = try await decoder.decodeBatch(
        valid,
        policy: .init(maximumDocumentCount: 2))
    }
  }

  func testAsyncBatchSourceUsesSameOrderedPerDocumentContract() async throws {
    let decoder = try CBORLDPreparedDecoder(dictionaries: [])
    let bytes = try (0..<6).map { try CBORLD.encodeUncompressed(.integer(Int64($0))) }
    let source = AsyncStream<Data> { continuation in
      for value in bytes { continuation.yield(value) }
      continuation.finish()
    }
    let outcomes = try await decoder.decodeBatch(
      source,
      policy: .init(
        maximumConcurrentTasks: 2,
        minimumParallelDocumentCount: 1,
        minimumParallelBytes: 0))
    XCTAssertEqual(outcomes.compactMap(\.value), [0, 1, 2, 3, 4, 5])
  }

  func testLargeDocumentDecodeObservesStructuredCancellation() async throws {
    let decoder = try CBORLDPreparedDecoder(dictionaries: [])
    let document = JSONValue.array((0..<4_096).map { .integer(Int64($0)) })
    let bytes = try CBORLD.encodeUncompressed(document)
    // Decoding starts only once the task is cancelled; otherwise a fast
    // decode could finish on another core before `cancel()` runs.
    let task = Task {
      while !Task.isCancelled { await Task.yield() }
      return try await decoder.decode(bytes)
    }
    task.cancel()
    do {
      _ = try await task.value
      XCTFail("Expected the large decode to observe cancellation")
    } catch is CancellationError {
      // Expected: the parser checks at deterministic container strides.
    }
  }
}

private func assertThrowsErrorAsync(
  _ expression: @escaping () async throws -> Void,
  file: StaticString = #filePath,
  line: UInt = #line
) async {
  do {
    try await expression()
    XCTFail("Expected expression to throw", file: file, line: line)
  } catch {}
}

extension Data {
  fileprivate init(testHex value: String) {
    self.init()
    var index = value.startIndex
    while index < value.endIndex {
      let next = value.index(index, offsetBy: 2)
      append(UInt8(value[index..<next], radix: 16)!)
      index = next
    }
  }
}
