import CBORLDCompute
import Foundation
import XCTest

@testable import CBORLD

/// Property and fuzz tests. Each failure message carries the seed and case so
/// the input can be replayed with `CBORLD_FUZZ_SEED` and reduced to a fixture.
final class PropertyTests: XCTestCase {
  private var seedLabel: String { String(PropertyTesting.seed, radix: 16) }

  // MARK: Robustness

  func testArbitraryBytesNeverCrashAndBothWholeBufferParsersAgree() async throws {
    var random = SplitMix64(seed: PropertyTesting.seed ^ 0x101)
    var generator = CBORGenerator(seed: PropertyTesting.seed ^ 0x102)
    let provider = CBORLDCPUComputeProvider()
    for iteration in 0..<PropertyTesting.iterations {
      let bytes: [UInt8]
      switch iteration % 3 {
      case 0: bytes = (0..<random.int(0...40)).map { _ in UInt8(truncatingIfNeeded: random.next()) }
      case 1: bytes = ByteMutation.mutate(generator.envelope(), random: &random)
      default: bytes = generator.envelope()
      }
      let data = Data(bytes)
      let label = "seed \(seedLabel) iteration \(iteration) \(data.hexString)"
      for (limits, policy) in [
        (CBORLDDecodingLimits(), CBORLDDecodingPolicy()),
        (.strict, .strict),
        (.init(), .init(allowsReservedSimpleValuesInLosslessMode: true)),
      ] {
        let inspected = Outcome { "\(try CBORLD.inspect(data, limits: limits, policy: policy))" }
        let lossless = Outcome {
          "\(try CBORLD.validateLossless(data, limits: limits, policy: policy).inspection)"
        }
        XCTAssertEqual(inspected.isSuccess, lossless.isSuccess, label)
      }
      _ = try? CBORLD.decodeUncompressed(data)
      _ = try? await CBORLD.decode(data)
      _ = try await provider.batchedCBORStructuralScan([data])
    }
  }

  func testEveryTruncationOfEveryFixtureFailsCleanly() async throws {
    var inputs: [Data] = []
    var generator = JSONGenerator(seed: PropertyTesting.seed ^ 0x103)
    for _ in 0..<10 {
      let document = generator.value()
      inputs.append(try CBORLD.encodeUncompressed(document))
      inputs.append(try await CBORLD.encode(document, options: .init(registryEntryID: 1)))
    }
    for input in inputs {
      for length in 0..<input.count {
        let prefix = Data(input.prefix(length))
        XCTAssertThrowsError(try CBORLD.inspect(prefix), "\(input.hexString) at \(length)")
        XCTAssertThrowsError(try CBORLD.validateLossless(prefix))
        do {
          _ = try await CBORLD.decode(prefix)
          XCTFail("Truncated input decoded: \(prefix.hexString)")
        } catch {
        }
      }
    }
  }

  // MARK: Round trips

  func testJSONRoundTripsThroughEveryModeRegistryAndFormat() async throws {
    var generator = JSONGenerator(seed: PropertyTesting.seed ^ 0x104)
    for iteration in 0..<PropertyTesting.iterations {
      let document = generator.value()
      let label = "seed \(seedLabel) iteration \(iteration) \(document.canonicalHex)"
      for mode in CBORLDSerializationMode.allCases {
        let bytes = try CBORLD.encodeUncompressed(document, serializationMode: mode)
        XCTAssertEqual(try CBORLD.decodeUncompressed(bytes), document, label)
        XCTAssertEqual(document.structuralCost.encodedByteCount, bytes.count - 5, label)
      }
      for options in [
        CBORLDEncodingOptions(registryEntryID: 1),
        CBORLDEncodingOptions(format: .legacySingleton),
        CBORLDEncodingOptions(format: .legacyRange, registryEntryID: 1),
      ] {
        let bytes = try await CBORLD.encode(document, options: options)
        let decoded = try await CBORLD.decode(bytes)
        XCTAssertEqual(decoded, document, label)
      }
      let typed = try await CBORLD.encode(
        Wrapper(value: document), options: .init(registryEntryID: 0))
      let restored = try await CBORLD.decode(Wrapper.self, from: typed)
      XCTAssertEqual(restored.value, document, label)
    }
  }

  func testDeterministicEncodingIsIdempotentAndPassesItsStrictProfile() throws {
    var generator = JSONGenerator(seed: PropertyTesting.seed ^ 0x105)
    for iteration in 0..<PropertyTesting.iterations {
      let document = generator.value()
      let label = "seed \(seedLabel) iteration \(iteration)"
      for mode in [CBORLDSerializationMode.lengthFirstDeterministic, .coreDeterministic] {
        let bytes = try CBORLD.encodeUncompressed(document, serializationMode: mode)
        var policy = CBORLDDecodingPolicy.strict
        policy.requiredSerializationMode = mode
        XCTAssertNoThrow(try CBORLD.inspect(bytes, limits: .strict, policy: policy), label)
        let again = try CBORLD.encodeUncompressed(
          try CBORLD.decodeUncompressed(bytes), serializationMode: mode)
        XCTAssertEqual(again, bytes, label)
      }
      // Re-encoding reproduces any input the encoder itself could have produced.
      let compatible = try CBORLD.encodeUncompressed(document)
      XCTAssertEqual(
        try CBORLD.encodeUncompressed(try CBORLD.decodeUncompressed(compatible)), compatible, label)
    }
  }

  func testDecodeThenEncodeIsTheIdentityOnlyForPreferredInput() throws {
    var generator = CBORGenerator(seed: PropertyTesting.seed ^ 0x106)
    for iteration in 0..<PropertyTesting.iterations {
      let bytes = Data([0xd9, 0xcb, 0x1d, 0x82, 0x00] + generator.item(depth: 2))
      guard let decoded = try? CBORLD.decodeUncompressed(bytes) else { continue }
      let reencoded = try CBORLD.encodeUncompressed(decoded)
      if reencoded == bytes {
        XCTAssertNoThrow(
          try CBORLD.inspect(
            bytes, policy: .init(requiredSerializationMode: .lengthFirstDeterministic)),
          "seed \(seedLabel) iteration \(iteration) \(bytes.hexString)")
      }
      XCTAssertEqual(try CBORLD.decodeUncompressed(reencoded), decoded)
    }
  }

  // MARK: Numeric and text boundaries

  func testIntegerWidthBoundariesAreExactAndStrictlyPreferred() async throws {
    let cases: [(Int64, String)] = [
      (0, "00"), (23, "17"), (24, "1818"), (255, "18ff"), (256, "190100"), (65_535, "19ffff"),
      (65_536, "1a00010000"), (4_294_967_295, "1affffffff"), (4_294_967_296, "1b0000000100000000"),
      (.max, "1b7fffffffffffffff"), (-1, "20"), (-24, "37"), (-25, "3818"), (-256, "38ff"),
      (-257, "390100"), (.min, "3b7fffffffffffffff"),
    ]
    for (value, head) in cases {
      let bytes = try CBORLD.encodeUncompressed([.integer(value)])
      XCTAssertEqual(bytes.hexString, "d9cb1d820081" + head, "\(value)")
      XCTAssertEqual(try CBORLD.decodeUncompressed(bytes), [.integer(value)])
      guard head.count < 18 else { continue }
      // The same value in the next wider width is accepted but not preferred.
      let major = UInt8(head.prefix(2), radix: 16)! & 0xe0
      let argument = value >= 0 ? UInt64(value) : UInt64(bitPattern: ~value)
      let wider =
        [major | 27] + (0..<8).map { UInt8(truncatingIfNeeded: argument >> UInt64(56 - $0 * 8)) }
      let widened = Data([0xd9, 0xcb, 0x1d, 0x82, 0x00, 0x81] + wider)
      XCTAssertEqual(try CBORLD.decodeUncompressed(widened), [.integer(value)])
      assertCBORLDErrorSync(.nonPreferredInteger) {
        _ = try CBORLD.inspect(widened, policy: .strict)
      }
    }
    // One beyond Int64 cannot become a JSONValue, and the negative form is
    // rejected by the parser itself.
    XCTAssertThrowsError(
      try CBORLD.decodeUncompressed(Data(hexString: "d9cb1d8200811b8000000000000000")))
    assertCBORLDErrorSync(.notCBORLD) {
      _ = try CBORLD.decodeUncompressed(Data(hexString: "d9cb1d8200813b8000000000000000"))
    }
  }

  func testFloatingPointWidthsAreShortestExact() throws {
    let cases: [(Double, String)] = [
      (1.5, "f93e00"), (6.103515625e-05, "f90400"), (-0.5, "f9b800"), (65_504.5, "fa477fe080"),
      (5.960464477539063e-08, "f90001"),
      (Double(Float.leastNonzeroMagnitude), "fa00000001"),
      (0.1, "fb3fb999999999999a"), (5e-324, "fb0000000000000001"),
      (.greatestFiniteMagnitude, "fb7fefffffffffffff"), (1e300, "fb7e37e43c8800759c"),
    ]
    for (value, encoded) in cases {
      let bytes = try CBORLD.encodeUncompressed([.number(value)])
      XCTAssertEqual(bytes.hexString, "d9cb1d820081" + encoded, "\(value)")
      guard case .array(let values) = try CBORLD.decodeUncompressed(bytes),
        case .number(let decoded) = values.first
      else { return XCTFail("\(value) did not decode as a number.") }
      XCTAssertEqual(decoded.bitPattern, value.bitPattern)
    }
    // Integral values and negative zero are integers, as in JavaScript.
    XCTAssertEqual(
      try CBORLD.encodeUncompressed([.number(-0.0), 2.0]).hexString, "d9cb1d8200820002")

    // Non-finite values are valid CBOR but not JSON; wider spellings are
    // accepted unless the policy requires preferred floating point.
    for input in ["f97c00", "f9fc00", "f97e00", "fb7ff8000000000000"] {
      XCTAssertThrowsError(try CBORLD.decodeUncompressed(Data(hexString: "d9cb1d820081" + input)))
    }
    let widened = Data(hexString: "d9cb1d820081fa3fc00000")
    XCTAssertEqual(try CBORLD.decodeUncompressed(widened), [1.5])
    assertCBORLDErrorSync(.nonPreferredFloat) { _ = try CBORLD.inspect(widened, policy: .strict) }
    assertCBORLDErrorSync(.nonPreferredFloat) {
      _ = try CBORLD.inspect(Data(hexString: "d9cb1d820081f97e01"), policy: .strict)
    }
  }

  func testInvalidUTF8IsRejectedAndLocated() async throws {
    // Each sequence with the offset, within it, of the first invalid byte as
    // the compute-family reference defines it.
    let invalid: [([UInt8], Int)] = [
      ([0xc0, 0x80], 0), ([0xed, 0xa0, 0x80], 1), ([0xe2, 0x82], 0), ([0x80], 0),
      ([0xf4, 0x90, 0x80, 0x80], 1), ([0xff], 0),
    ]
    for (sequence, invalidOffset) in invalid {
      let prefix: [UInt8] = [0x61, 0x61]
      let content = prefix + sequence
      let bytes = Data([0xd9, 0xcb, 0x1d, 0x82, 0x00, 0x60 | UInt8(content.count)] + content)
      for decode in [
        { try CBORLD.decodeUncompressed(bytes) },
        { try CBORLD.parse(bytes).payload.toJSON() },
      ] {
        do {
          _ = try decode()
          XCTFail("Invalid UTF-8 \(sequence) decoded.")
        } catch let error as CBORLDError {
          XCTAssertEqual(error.code, .notCBORLD)
          // The offset lies within the string item.
          XCTAssertTrue((5...(6 + content.count)).contains(error.diagnostic?.byteOffset ?? -1))
        }
      }
      let result = CBORLDCPUComputeProvider.validateUTF8(Data(content))
      XCTAssertFalse(result.isValid)
      XCTAssertEqual(result.firstInvalidByteOffset, prefix.count + invalidOffset, "\(sequence)")
      await assertCBORLDError(.notCBORLD) {
        _ = try await CBORLD.validateStream([bytes].asyncChunks)
      }
    }
  }

  func testDuplicateKeysAreFoundThroughEquivalentEncodings() throws {
    let cases: [(String, Int)] = [
      // {"a": 1, "a": 2} with the second key in a one-byte length field.
      ("a2616101" + "78016102", 9),
      // {1: 1, 1: 2} with the second key widened.
      ("a20101" + "180102", 8),
      // {-1: 0, -1: 0} with the second key widened to four bytes.
      ("a22000" + "3a0000000000", 8),
    ]
    for (payload, offset) in cases {
      let bytes = Data(hexString: "d9cb1d8200" + payload)
      do {
        _ = try CBORLD.inspect(bytes, limits: .init(rejectDuplicateMapKeys: true))
        XCTFail("Duplicate key accepted: \(payload)")
      } catch let error as CBORLDError {
        XCTAssertEqual(error.diagnostic?.violation, "duplicate-map-key")
        XCTAssertEqual(error.diagnostic?.byteOffset, offset, payload)
        XCTAssertEqual(error.diagnostic?.relatedByteOffset, 6, payload)
      }
      XCTAssertNoThrow(try CBORLD.inspect(bytes), "Duplicates are opt-in rejections.")
    }
  }

  // MARK: Semantic compression

  func testRandomContextsRoundTripWithAndWithoutTermCompression() async throws {
    var random = SplitMix64(seed: PropertyTesting.seed ^ 0x107)
    for iteration in 0..<max(20, PropertyTesting.iterations / 5) {
      let scenario = SemanticScenario(random: &random)
      let label = "seed \(seedLabel) iteration \(iteration) \(scenario.document.canonicalHex)"
      for model in [
        nil,
        CBORLDProcessingModel(
          semanticCompression: false, codecs: CBORLDProcessingModel.default.codecs),
      ] {
        let entry = CBORLDRegistryEntry(
          id: 200, processingModel: model,
          typeTables: ["context": [.string(SemanticScenario.contextURL): 7]])
        let loader = fixedLoader([SemanticScenario.contextURL: scenario.context])
        do {
          let bytes = try await CBORLD.encode(
            scenario.document,
            options: .init(
              registryEntryID: 200, documentLoader: loader, registryEntryLoader: { _ in entry }))
          let decoded = try await CBORLD.decode(
            bytes, options: .init(documentLoader: loader, registryEntryLoader: { _ in entry }))
          XCTAssertEqual(decoded, scenario.document, "\(label) model \(String(describing: model))")
        } catch let error as CBORLDError where error.code == .ambiguousValue {
          // Only possible without term compression, and only for values a
          // codec could read as one compressed value.
          XCTAssertNotNil(model, label)
        }
      }
    }
  }

  func testDictionaryValidationAndFingerprintsAreOrderIndependent() throws {
    var random = SplitMix64(seed: PropertyTesting.seed ^ 0x108)
    for iteration in 0..<PropertyTesting.iterations {
      var contexts: [(String, UInt64)] = []
      var identifiers = Set<UInt64>()
      var hasDuplicate = false
      for index in 0..<random.int(0...6) {
        let identifier = UInt64(random.int(0...8))
        hasDuplicate = hasDuplicate || !identifiers.insert(identifier).inserted
        contexts.append(("urn:context:\(index)", identifier))
      }
      let forward = CBORLDDocumentDictionary(
        code: 42, contexts: Dictionary(uniqueKeysWithValues: contexts))
      let reversed = CBORLDDocumentDictionary(
        code: 42, contexts: Dictionary(uniqueKeysWithValues: contexts.reversed()))
      let label = "seed \(seedLabel) iteration \(iteration)"
      if hasDuplicate {
        XCTAssertThrowsError(try forward.validate(), label)
      } else {
        XCTAssertEqual(try forward.fingerprint(), try reversed.fingerprint(), label)
      }
    }
  }
}

// MARK: - Fixtures

private struct Wrapper: Codable, Sendable {
  var value: JSONValue
}

/// A random context whose terms carry typed and untyped definitions, and a
/// document that uses them with values valid for each type.
private struct SemanticScenario {
  static let contextURL = "urn:property:context"

  let context: JSONValue
  let document: JSONValue

  init(random: inout SplitMix64) {
    let types: [String?] = [
      nil, "@id", "@vocab", CBORLDProcessingModel.xsdDateTimeType,
      CBORLDProcessingModel.xsdDateType, CBORLDProcessingModel.multibaseType,
    ]
    var definitions: [String: JSONValue] = [
      "Thing": "https://example.com/vocab#Thing", "type": "@type", "id": "@id",
    ]
    if random.chance(1, in: 3) { definitions["@protected"] = true }
    var document: [String: JSONValue] = ["@context": .string(Self.contextURL)]
    var firstType: String?
    for index in 0..<random.int(1...6) {
      let term = "term\(index)"
      let type = random.element(types)
      if index == 0 { firstType = type }
      if let type {
        definitions[term] = [
          "@id": .string("https://example.com/vocab#\(term)"), "@type": .string(type),
        ]
      } else {
        definitions[term] = .string("https://example.com/vocab#\(term)")
      }
      let values = (0..<random.int(1...3)).map { _ in Self.value(for: type, random: &random) }
      document[term] = random.chance(1, in: 2) && values.count == 1 ? values[0] : .array(values)
    }
    if random.chance(1, in: 2) { document["type"] = "Thing" }
    if random.chance(1, in: 2) {
      document["id"] = .string("urn:uuid:\(UUID().uuidString.lowercased())")
    }
    if random.chance(1, in: 3) {
      document["nested"] = ["term0": Self.value(for: firstType, random: &random)]
    }
    context = ["@context": .object(definitions)]
    self.document = .object(document)
  }

  private static func value(for type: String?, random: inout SplitMix64) -> JSONValue {
    switch type {
    case "@id"?, "@vocab"?:
      return .string(
        random.element([
          "https://example.com/a", "http://example.com/b",
          "urn:uuid:" + UUID().uuidString.lowercased(),
          "did:key:z6MkhaXgBZDvotDkL5257faiztiGiC2QtKLGpbnnEGta2doK", "Thing", "urn:other", "term0",
          "data:text/plain;base64,SGVsbG8=", "relative/path",
        ]))
    case CBORLDProcessingModel.xsdDateTimeType?:
      return .string(
        random.element([
          "2021-04-09T20:38:55Z", "2021-04-09T20:38:55.123Z", "1969-12-31T23:59:59Z",
          "not a date", "2021-04-09T20:38:55+01:00",
        ]))
    case CBORLDProcessingModel.xsdDateType?:
      return .string(random.element(["2021-04-09", "1900-01-01", "2021-4-9", "someday"]))
    case CBORLDProcessingModel.multibaseType?:
      return .string(random.element(["zLdp", "uAQID", "MAQID", "z", "xnot-multibase"]))
    default:
      var generator = JSONGenerator(seed: random.next())
      generator.maximumDepth = 2
      return generator.value()
    }
  }
}
