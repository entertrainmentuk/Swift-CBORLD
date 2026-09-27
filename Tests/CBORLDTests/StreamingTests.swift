import Foundation
import XCTest

@testable import CBORLD

/// Single-document streaming: chunked validation and decoding must agree with
/// the whole-buffer parser, and streaming encoding must emit identical bytes.
final class StreamingTests: XCTestCase {
  // MARK: Encoding

  func testStreamingEncodeEmitsIdenticalBytesInBoundedChunks() async throws {
    var generator = JSONGenerator(seed: PropertyTesting.seed)
    var documents: [JSONValue] = [
      [:], "text", .string(String(repeating: "L", count: 10_000)),
      ["long": .string(String(repeating: "k", count: 5_000)), "n": 1],
      [String(repeating: "x", count: 300): [1, 2, 3]],
    ]
    for _ in 0..<40 { documents.append(generator.value()) }
    for document in documents {
      for mode in [CBORLDSerializationMode.compatibility, .coreDeterministic] {
        let expected = try CBORLD.encodeUncompressed(document, serializationMode: mode)
        for chunkSize in [1, 7, 64, 4_096] {
          var sink = CBORLDDataSink()
          let result = try await CBORLD.encodeUncompressed(
            document, to: &sink, serializationMode: mode, chunkSize: chunkSize)
          XCTAssertEqual(sink.data, expected, "chunkSize \(chunkSize)")
          XCTAssertEqual(result.byteCount, expected.count)
          XCTAssertEqual(result.chunkCount, sink.chunkSizes.count)
          XCTAssertEqual(result.transportDigest, CBORLD.transportDigest(of: expected))
          XCTAssertTrue(
            sink.chunkSizes.allSatisfy { $0 > 0 && $0 <= max(chunkSize, 9) },
            "chunkSize \(chunkSize): \(sink.chunkSizes.max() ?? 0)")
        }
      }
    }
  }

  func testStreamingEncodeEnforcesLimitsAcrossTheWholeStream() async throws {
    let document: JSONValue = [
      "a": .string(String(repeating: "a", count: 3_000)),
      "b": .string(String(repeating: "b", count: 3_000)),
    ]
    let size = try CBORLD.encodeUncompressed(document).count
    var exact = CBORLDDataSink()
    _ = try await CBORLD.encodeUncompressed(
      document, to: &exact, limits: .init(maximumOutputBytes: size), chunkSize: 256)
    XCTAssertEqual(exact.data.count, size)

    var limited = CBORLDDataSink()
    await assertCBORLDError(.resourceLimit) {
      _ = try await CBORLD.encodeUncompressed(
        document, to: &limited, limits: .init(maximumOutputBytes: size - 1), chunkSize: 256)
    }
    XCTAssertLessThan(limited.data.count, size)

    var deep: JSONValue = 1
    for _ in 0..<10 { deep = [deep] }
    var sink = CBORLDDataSink()
    await assertCBORLDError(.resourceLimit) {
      _ = try await CBORLD.encodeUncompressed(
        deep, to: &sink, limits: .init(maximumNestingDepth: 8))
    }
    await assertCBORLDError(.invalidInput) {
      _ = try await CBORLD.encodeUncompressed(["a": 1], to: &sink, chunkSize: 0)
    }
  }

  // MARK: Validation and decoding

  func testStreamingValidationAndDecodingAgreeOnValidDocuments() async throws {
    var random = SplitMix64(seed: PropertyTesting.seed ^ 0x51)
    var generator = JSONGenerator(seed: PropertyTesting.seed ^ 0x52)
    var inputs: [Data] = []
    for _ in 0..<60 {
      let document = generator.value()
      inputs.append(try CBORLD.encodeUncompressed(document))
      inputs.append(try await CBORLD.encode(document, options: .init(registryEntryID: 1)))
    }
    inputs.append(
      try await CBORLD.encode(["a": 1], options: .init(format: .legacySingleton)))
    inputs.append(
      try await CBORLD.encode(
        ["a": 1],
        options: .init(format: .legacyRange, registryEntryID: 300, typeTableLoader: { _ in [:] })))

    for input in inputs {
      let chunks = randomChunks(Array(input), random: &random)
      let inspection = try CBORLD.inspect(input)
      let validation = try await CBORLD.validateStream(chunks.asyncChunks)
      XCTAssertEqual(validation.format, inspection.format)
      XCTAssertEqual(validation.registryEntryID, inspection.registryEntryID)
      XCTAssertEqual(validation.payloadIsCompressed, inspection.payloadIsCompressed)
      XCTAssertEqual(validation.byteCount, input.count)
      XCTAssertEqual(validation.transportDigest, inspection.transportDigest)

      guard inspection.format == .cborLD1, inspection.registryEntryID == 0 else { continue }
      let expected = try CBORLD.decodeUncompressed(input)
      let streamed = try await CBORLD.decodeUncompressedStream(chunks.asyncChunks)
      XCTAssertEqual(streamed.document, expected)

      var events: [CBORLDJSONEvent] = []
      _ = try await CBORLD.decodeUncompressedEvents(chunks.asyncChunks) { events.append($0) }
      XCTAssertEqual(try Self.rebuild(events), expected)
    }
  }

  func testChunkedValidationMatchesTheWholeBufferParserOnArbitraryInput() async throws {
    let configurations: [(CBORLDDecodingLimits, CBORLDDecodingPolicy)] = [
      (.init(), .init()),
      (.strict, .strict),
      (.init(maximumNestingDepth: 6, maximumContainerItems: 3), .init()),
      (.init(rejectDuplicateMapKeys: true), .init(requiredSerializationMode: .coreDeterministic)),
      (.init(), .init(allowsReservedSimpleValuesInLosslessMode: true)),
      (.init(allowsIndefiniteLengthItems: false), .init(rejectNonPreferredFloatingPoint: true)),
    ]
    var random = SplitMix64(seed: PropertyTesting.seed ^ 0x53)
    var generator = CBORGenerator(seed: PropertyTesting.seed ^ 0x54)
    var disagreements: [String] = []
    for iteration in 0..<PropertyTesting.iterations {
      var bytes = generator.envelope()
      if random.chance(1, in: 3) { bytes = ByteMutation.mutate(bytes, random: &random) }
      let (limits, policy) = configurations[iteration % configurations.count]
      let whole = Outcome {
        let inspection = try CBORLD.inspect(Data(bytes), limits: limits, policy: policy)
        return "\(inspection.format.rawValue):\(inspection.registryEntryID.map(String.init) ?? "-")"
      }
      let chunks = randomChunks(bytes, random: &random)
      let streamed = await Outcome {
        let validation = try await CBORLD.validateStream(
          chunks.asyncChunks, limits: limits, policy: policy)
        return "\(validation.format.rawValue):\(validation.registryEntryID.map(String.init) ?? "-")"
      }
      if whole != streamed, !Self.isKnownOrderingDifference(whole, streamed, bytes, limits) {
        disagreements.append(
          "seed \(String(PropertyTesting.seed, radix: 16)) iteration \(iteration) "
            + "\(Data(bytes).hexString): whole \(whole), streamed \(streamed)")
      }
    }
    XCTAssertTrue(disagreements.isEmpty, disagreements.prefix(5).joined(separator: "\n"))
  }

  func testChunkedRegistryZeroDecodingMatchesTheWholeBufferPath() async throws {
    var random = SplitMix64(seed: PropertyTesting.seed ^ 0x55)
    var generator = CBORGenerator(seed: PropertyTesting.seed ^ 0x56)
    var disagreements: [String] = []
    for iteration in 0..<PropertyTesting.iterations {
      var bytes: [UInt8] = [0xd9, 0xcb, 0x1d, 0x82, 0x00] + generator.item(depth: 2)
      if random.chance(1, in: 4) { bytes = ByteMutation.mutate(bytes, random: &random) }
      let whole = Outcome {
        let parsed = try CBORLD.parse(Data(bytes))
        guard parsed.format == .cborLD1, parsed.registryEntryID == 0 else {
          throw CBORLDError.invalidInput("not registry zero")
        }
        return try parsed.payload.toJSON().canonicalHex
      }
      let chunks = randomChunks(bytes, random: &random)
      let streamed = await Outcome {
        try await CBORLD.decodeUncompressedStream(chunks.asyncChunks).document.canonicalHex
      }
      if whole != streamed, !Self.isKnownOrderingDifference(whole, streamed, bytes, .init()) {
        disagreements.append(
          "iteration \(iteration) \(Data(bytes).hexString): whole \(whole), streamed \(streamed)")
      }
      // Whatever the whole-buffer path accepts, the optimized decoder accepts too.
      if case .success = whole {
        XCTAssertNoThrow(try CBORLD.decodeUncompressed(Data(bytes)))
      }
    }
    XCTAssertTrue(disagreements.isEmpty, disagreements.prefix(5).joined(separator: "\n"))
  }

  func testEveryTruncationIsRejectedByBothParsers() async throws {
    let document: JSONValue = [
      "list": [1, 2.5, "three", ["nested": true]], "none": .null, "text": "value",
    ]
    for input in [
      try CBORLD.encodeUncompressed(document),
      try await CBORLD.encode(document, options: .init(registryEntryID: 1)),
    ] {
      for length in 0..<input.count {
        let prefix = input.prefix(length)
        XCTAssertThrowsError(try CBORLD.inspect(Data(prefix)), "length \(length)")
        await assertCBORLDError(.notCBORLD) {
          _ = try await CBORLD.validateStream([Data(prefix)].asyncChunks)
        }
      }
    }
  }

  func testStreamingPolicyErrorsKeepTheirCodesAndOffsets() async throws {
    // A non-preferred integer inside an otherwise valid document.
    let widened = Data(hexString: "d9cb1d8200a1616118" + "01")
    for (limits, policy, code) in [
      (
        CBORLDDecodingLimits(), CBORLDDecodingPolicy(rejectNonPreferredIntegerWidths: true),
        CBORLDErrorCode.nonPreferredInteger
      ),
      (.init(), .strict, .nonPreferredInteger),
      (.init(), .init(requiredSerializationMode: .lengthFirstDeterministic), .nonPreferredCBOR),
    ] {
      var wholeError: CBORLDError?
      do { _ = try CBORLD.inspect(widened, limits: limits, policy: policy) } catch {
        wholeError = error as? CBORLDError
      }
      var streamError: CBORLDError?
      do {
        _ = try await CBORLD.validateStream(
          [widened.prefix(7), widened.dropFirst(7)].asyncChunks, limits: limits, policy: policy)
      } catch {
        streamError = error as? CBORLDError
      }
      XCTAssertEqual(wholeError?.code, code)
      XCTAssertEqual(streamError?.code, code)
      XCTAssertEqual(streamError?.diagnostic?.byteOffset, wholeError?.diagnostic?.byteOffset)
    }

    let duplicate = Data(hexString: "d9cb1d8200a2616101616102")
    do {
      _ = try await CBORLD.validateStream(
        [duplicate].asyncChunks, limits: .init(rejectDuplicateMapKeys: true))
      XCTFail("Expected a duplicate key.")
    } catch let error as CBORLDError {
      XCTAssertEqual(error.diagnostic?.violation, "duplicate-map-key")
      XCTAssertEqual(error.diagnostic?.byteOffset, 9)
      XCTAssertEqual(error.diagnostic?.relatedByteOffset, 6)
    }
  }

  func testEventsAreDeliveredInDocumentOrder() async throws {
    let input = Data(hexString: "d9cb1d8200a2616101616282f5f6")
    var events: [CBORLDJSONEvent] = []
    let validation = try await CBORLD.decodeUncompressedEvents([input].asyncChunks) {
      events.append($0)
    }
    XCTAssertEqual(
      events,
      [
        .beginObject(count: 2), .key("a"), .integer(1), .key("b"), .beginArray(count: 2),
        .bool(true), .null, .endArray, .endObject,
      ])
    // Tag, envelope array, registry entry, map, "a", 1, "b", array, true, null.
    XCTAssertEqual(validation.itemCount, 10)
    XCTAssertEqual(validation.maximumDepth, 4)

    let compressed = try await CBORLD.encode(["a": 1], options: .init(registryEntryID: 1))
    var delivered = 0
    await assertCBORLDError(.invalidInput) {
      _ = try await CBORLD.decodeUncompressedEvents([compressed].asyncChunks) { _ in delivered += 1
      }
    }
    XCTAssertEqual(delivered, 0)
    await assertCBORLDError(.invalidInput) {
      _ = try await CBORLD.decodeUncompressedEvents(
        [Data(hexString: "d9cb1d8200a1616140")].asyncChunks
      ) { _ in }
    }
  }

  func testFileSinkAndChunkedFileReadingRoundTrip() async throws {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("cborld-stream-\(UUID().uuidString).cborld")
    defer { try? FileManager.default.removeItem(at: url) }
    var generator = JSONGenerator(seed: PropertyTesting.seed ^ 0x57)
    let document: JSONValue = .array((0..<200).map { _ in generator.value() })

    let sink = try CBORLDFileSink(url: url)
    var writer = sink
    let written = try await CBORLD.encodeUncompressed(document, to: &writer, chunkSize: 1_024)
    try sink.close()

    let validation = try await CBORLD.validateStream(CBORLDFileChunks(url: url, chunkSize: 333))
    XCTAssertEqual(validation.byteCount, written.byteCount)
    XCTAssertEqual(validation.transportDigest, written.transportDigest)
    XCTAssertEqual(try CBORLD.transportDigest(ofFile: url), written.transportDigest)
    let decoded = try await CBORLD.decodeUncompressedStream(CBORLDFileChunks(url: url))
    XCTAssertEqual(decoded.document, document)
  }

  // MARK: Helpers

  /// The whole-buffer parser knows the input length, so it rejects a
  /// definite container that claims more items than bytes remain before it
  /// reads the container's contents. The streaming parser cannot know that
  /// in advance and reports the first error it reaches inside the container
  /// instead. Both reject such input; only the reported error differs.
  private static func isKnownOrderingDifference(
    _ whole: Outcome,
    _ streamed: Outcome,
    _ bytes: [UInt8],
    _ limits: CBORLDDecodingLimits
  ) -> Bool {
    guard !streamed.isSuccess, let message = whole.failureMessage,
      ProcessInfo.processInfo.environment["STRICT_STREAM_PARITY"] == nil
    else { return false }
    return message.hasSuffix("length exceeds the remaining input.")
  }

  private static func rebuild(_ events: [CBORLDJSONEvent]) throws -> JSONValue {
    var index = 0
    func value() throws -> JSONValue {
      defer { index += 1 }
      switch events[index] {
      case .null: return .null
      case .bool(let value): return .bool(value)
      case .integer(let value): return .integer(value)
      case .number(let value): return .number(value)
      case .string(let value): return .string(value)
      case .beginArray:
        index += 1
        var values: [JSONValue] = []
        while events[index] != .endArray { values.append(try value()) }
        return .array(values)
      case .beginObject:
        index += 1
        var object: [String: JSONValue] = [:]
        while case .key(let key) = events[index] {
          index += 1
          object[key] = try value()
        }
        return .object(object)
      default:
        throw CBORLDError.invalidInput("Unexpected event \(events[index]).")
      }
    }
    return try value()
  }
}
