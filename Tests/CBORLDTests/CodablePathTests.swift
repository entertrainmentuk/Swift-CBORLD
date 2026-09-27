import Foundation
import XCTest

@testable import CBORLD

/// Exercises every primitive path of the value encoder and decoder through
/// keyed, unkeyed, and single-value containers, comparing with JSONEncoder.
final class CodablePathTests: XCTestCase {
  func testEveryPrimitiveRoundTripsThroughEveryContainerKind() throws {
    let value = Primitives.sample
    let encoded = try CBORLDValueEncoder().encode(value)
    XCTAssertEqual(encoded, try JSONValue(data: JSONEncoder().encode(value)))
    XCTAssertEqual(try CBORLDValueDecoder().decode(Primitives.self, from: encoded), value)

    let listed = try CBORLDValueEncoder().encode(PrimitiveList(values: .sample))
    XCTAssertEqual(
      listed, try JSONValue(data: JSONEncoder().encode(PrimitiveList(values: .sample))))
    XCTAssertEqual(
      try CBORLDValueDecoder().decode(PrimitiveList.self, from: listed),
      PrimitiveList(values: .sample))

    for single in Primitives.singles {
      let json = try CBORLDValueEncoder().encode(single)
      XCTAssertEqual(json, try JSONValue(data: JSONEncoder().encode(single)))
      XCTAssertEqual(try CBORLDValueDecoder().decode(SingleValue.self, from: json), single)
    }
  }

  func testRegistryAndPolicyTypesDecodeWithDefaultsForMissingKeys() throws {
    let empty = Data("{}".utf8)
    XCTAssertEqual(try JSONDecoder().decode(CBORLDEncodingLimits.self, from: empty), .init())
    XCTAssertEqual(try JSONDecoder().decode(CBORLDDecodingLimits.self, from: empty), .init())
    XCTAssertEqual(try JSONDecoder().decode(CBORLDContextLoadingPolicy.self, from: empty), .init())
    for value in [
      CBORLDContextLoadingPolicy.strict,
      .init(
        allowedURLSchemes: ["https"], allowedHosts: ["example.com"], allowedMediaTypes: ["a/b"]),
    ] {
      XCTAssertEqual(
        try JSONDecoder().decode(
          CBORLDContextLoadingPolicy.self, from: JSONEncoder().encode(value)), value)
    }
    let limits = CBORLDEncodingLimits(maximumOutputBytes: 7, maximumNestingDepth: 3)
    XCTAssertEqual(
      try JSONDecoder().decode(CBORLDEncodingLimits.self, from: JSONEncoder().encode(limits)),
      limits)

    let loaded = CBORLDLoadedDocument(
      document: ["@context": [:]], requestedURL: "https://example.com/a",
      canonicalURL: "https://example.com/b", mediaType: "application/ld+json", byteCount: 10,
      redirectChain: ["https://example.com/a"])
    let decoded = try JSONDecoder().decode(
      CBORLDLoadedDocument.self, from: JSONEncoder().encode(loaded))
    XCTAssertEqual(decoded, loaded)
    XCTAssertTrue(decoded.byteCountIsMeasured)
    XCTAssertFalse(CBORLDLoadedDocument(document: 1, requestedURL: "urn:x").byteCountIsMeasured)
  }

  func testRegistryResolvesThroughAMetadataFallback() async throws {
    let context: JSONValue = ["@context": ["name": "ex:name"]]
    let pin = try CBORLD.contextFingerprint(of: context)
    let registry = CBORLDContextRegistry(
      expectedFingerprints: ["https://example.com/c": pin],
      contextFallback: { request in
        CBORLDLoadedDocument(
          document: context, requestedURL: request.url, mediaType: "application/ld+json",
          byteCount: 42)
      })
    let loaded = try await registry.resolve(
      .init(
        url: "https://example.com/c", maximumByteCount: 100, maximumRedirects: 1, importDepth: 0))
    XCTAssertEqual(loaded.byteCount, 42)
    XCTAssertEqual(loaded.expectedFingerprint, pin)
    let plain = try await registry.load("https://example.com/c")
    XCTAssertEqual(plain, context)
    await assertCBORLDError(.unknownContext) {
      _ = try await CBORLDContextRegistry().load("urn:missing")
    }
  }
}

// MARK: - Fixtures

private struct Primitives: Codable, Equatable {
  var bool = true
  var string = "text"
  var double = 2.5
  var float: Float = 0.25
  var int = -1
  var int8: Int8 = -8
  var int16: Int16 = -16
  var int32: Int32 = -32
  var int64: Int64 = -64
  var uint: UInt = 1
  var uint8: UInt8 = 8
  var uint16: UInt16 = 16
  var uint32: UInt32 = 32
  var uint64: UInt64 = 64
  var optional: Int? = nil
  var nested: [String: [Int]] = ["a": [1, 2]]

  static let sample = Primitives()

  static let singles: [SingleValue] = [
    .bool(false), .string("s"), .double(-1.5), .float(8.5), .int(-3), .int8(-4), .int16(-5),
    .int32(-6), .int64(-7), .uint(3), .uint8(4), .uint16(5), .uint32(6), .uint64(7), .none,
  ]
}

/// Encodes every primitive through an unkeyed container.
private struct PrimitiveList: Codable, Equatable {
  var values: Primitives

  init(values: Primitives) {
    self.values = values
  }

  init(from decoder: Decoder) throws {
    var container = try decoder.unkeyedContainer()
    var values = Primitives()
    values.bool = try container.decode(Bool.self)
    values.string = try container.decode(String.self)
    values.double = try container.decode(Double.self)
    values.float = try container.decode(Float.self)
    values.int = try container.decode(Int.self)
    values.int8 = try container.decode(Int8.self)
    values.int16 = try container.decode(Int16.self)
    values.int32 = try container.decode(Int32.self)
    values.int64 = try container.decode(Int64.self)
    values.uint = try container.decode(UInt.self)
    values.uint8 = try container.decode(UInt8.self)
    values.uint16 = try container.decode(UInt16.self)
    values.uint32 = try container.decode(UInt32.self)
    values.uint64 = try container.decode(UInt64.self)
    values.optional = try container.decodeNil() ? nil : try container.decode(Int.self)
    values.nested = try container.decode([String: [Int]].self)
    XCTAssertEqual(container.count, 16)
    XCTAssertTrue(container.isAtEnd)
    self.values = values
  }

  func encode(to encoder: Encoder) throws {
    var container = encoder.unkeyedContainer()
    try container.encode(values.bool)
    try container.encode(values.string)
    try container.encode(values.double)
    try container.encode(values.float)
    try container.encode(values.int)
    try container.encode(values.int8)
    try container.encode(values.int16)
    try container.encode(values.int32)
    try container.encode(values.int64)
    try container.encode(values.uint)
    try container.encode(values.uint8)
    try container.encode(values.uint16)
    try container.encode(values.uint32)
    try container.encode(values.uint64)
    if let optional = values.optional {
      try container.encode(optional)
    } else {
      try container.encodeNil()
    }
    try container.encode(values.nested)
    XCTAssertEqual(container.count, 16)
  }
}

/// Encodes one primitive through a single-value container.
private enum SingleValue: Codable, Equatable {
  case bool(Bool)
  case string(String)
  case double(Double)
  case float(Float)
  case int(Int)
  case int8(Int8)
  case int16(Int16)
  case int32(Int32)
  case int64(Int64)
  case uint(UInt)
  case uint8(UInt8)
  case uint16(UInt16)
  case uint32(UInt32)
  case uint64(UInt64)
  case none

  func encode(to encoder: Encoder) throws {
    var container = encoder.singleValueContainer()
    switch self {
    case .bool(let value): try container.encode(value)
    case .string(let value): try container.encode(value)
    case .double(let value): try container.encode(value)
    case .float(let value): try container.encode(value)
    case .int(let value): try container.encode(value)
    case .int8(let value): try container.encode(value)
    case .int16(let value): try container.encode(value)
    case .int32(let value): try container.encode(value)
    case .int64(let value): try container.encode(value)
    case .uint(let value): try container.encode(value)
    case .uint8(let value): try container.encode(value)
    case .uint16(let value): try container.encode(value)
    case .uint32(let value): try container.encode(value)
    case .uint64(let value): try container.encode(value)
    case .none: try container.encodeNil()
    }
  }

  /// Decodes by trying the narrowest matching representation, so every
  /// single-value decode method runs.
  init(from decoder: Decoder) throws {
    let container = try decoder.singleValueContainer()
    if container.decodeNil() {
      self = .none
    } else if let value = try? container.decode(Bool.self) {
      self = .bool(value)
    } else if let value = try? container.decode(String.self) {
      self = .string(value)
    } else if let value = try? container.decode(Int.self), value < 0 {
      self = Self.signed(value, container: container)
    } else if let value = try? container.decode(UInt64.self) {
      self = Self.unsigned(value, container: container)
    } else if let value = try? container.decode(Float.self), Double(value) == 8.5 {
      self = .float(value)
    } else {
      self = .double(try container.decode(Double.self))
    }
  }

  private static func signed(_ value: Int, container: any SingleValueDecodingContainer) -> Self {
    switch value {
    case -3: return .int(value)
    case -4: return .int8((try? container.decode(Int8.self)) ?? 0)
    case -5: return .int16((try? container.decode(Int16.self)) ?? 0)
    case -6: return .int32((try? container.decode(Int32.self)) ?? 0)
    default: return .int64((try? container.decode(Int64.self)) ?? 0)
    }
  }

  private static func unsigned(_ value: UInt64, container: any SingleValueDecodingContainer) -> Self
  {
    switch value {
    case 3: return .uint((try? container.decode(UInt.self)) ?? 0)
    case 4: return .uint8((try? container.decode(UInt8.self)) ?? 0)
    case 5: return .uint16((try? container.decode(UInt16.self)) ?? 0)
    case 6: return .uint32((try? container.decode(UInt32.self)) ?? 0)
    default: return .uint64(value)
    }
  }
}
