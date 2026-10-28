import Foundation
import XCTest

@testable import CBORLD

/// `CBORLDValueEncoder` replaces the `JSONEncoder` → text → `JSONValue` round
/// trip. The expected bytes below were produced by that round trip at
/// af20539, so typed encoding keeps its exact wire output.
final class ValueCoderTests: XCTestCase {
  private static let baselineModelPayload =
    "b3626964382964666c6167f5646b696e646462657461646c696e6b781968747470733a2f2f6578616d706c652e636f6d2f"
    + "613f623d636474616773826178617965726174696ffb3fb999999999999a65736d616c6c18c866616d6f756e74f94a40"
    + "66636f756e7473a2616101616202666e6573746564a2646e616d65616e67776569676874738301f94100226673696e676c"
    + "65fb3fb999999999999a6763726561746564fb40c81cd6c8b43958677061796c6f616468414145432b673d3d68666c6f61"
    + "744d6178fb47efffffe54daff869626967446f75626c651b00200000000000026a626967446563696d616cfb43e56a9531"
    + "9d63e16a68756765446f75626c65fb4415af1d78b58c406c6e656761746976655a65726f006f6672616374696f6e446563"
    + "696d616cfb3fd3333333333333"

  func testTypedEncodingMatchesTheJSONTextRoundTripBytes() async throws {
    let entryZero = try await CBORLD.encode(
      BaselineModel.sample, options: .init(registryEntryID: 0))
    XCTAssertEqual(entryZero.hexString, "d9cb1d8200" + Self.baselineModelPayload)
    let entryOne = try await CBORLD.encode(BaselineModel.sample, options: .init(registryEntryID: 1))
    XCTAssertEqual(entryOne.hexString, "d9cb1d8201" + Self.baselineModelPayload)

    let value = try CBORLDValueEncoder().encode(BaselineModel.sample)
    XCTAssertEqual(
      try CBORLD.structuralFingerprint(of: value).hex,
      "8b26120e7f9a04942b29c96837e81f702f000f22ec9052e59c44c4af8b784931")
    XCTAssertEqual(value, try JSONValue(data: JSONEncoder().encode(BaselineModel.sample)))

    // The encoder and decoder defaults are inverse.
    let restored = try CBORLDValueDecoder().decode(BaselineModel.self, from: value)
    XCTAssertEqual(restored.id, -42)
    XCTAssertEqual(restored.payload, Data([0, 1, 2, 250]))
    XCTAssertEqual(restored.link, URL(string: "https://example.com/a?b=c"))
    XCTAssertEqual(restored.bigDouble, 9_007_199_254_740_994)
    XCTAssertEqual(restored.created, BaselineModel.sample.created)

    let reusable = try await CBORLDEncoder(dictionary: .init(code: 0)).encode(BaselineModel.sample)
    XCTAssertEqual(reusable, entryZero)
    let prepared = try await CBORLDPreparedEncoder(dictionary: .init(code: 0))
      .encode(BaselineModel.sample)
    XCTAssertEqual(prepared, entryZero)
  }

  func testDictionaryFingerprintsMatchTheirBaselineValues() throws {
    let dictionary = CBORLDDocumentDictionary(
      code: 42,
      profileName: "example",
      profileVersion: "1",
      contexts: ["urn:z": 32_769, "urn:a": 32_768],
      typedValues: ["urn:type": ["active": 32_770]],
      uris: ["https://example.com": 32_771],
      untypedValues: ["constant": 32_772])
    XCTAssertEqual(
      try dictionary.fingerprint().hex,
      "84b0980e6289f4f2b26115f8417ddbf3a3c1330013705c0d2f2d8cfabf443a6b")
    XCTAssertEqual(
      try CBORLDDocumentDictionary.unregistered.fingerprint().hex,
      "e9933a7583df5bfe6ab6d4e6658e5d7f190fe6c74e9412af6b7e4d3b03566ada")
  }

  func testSnakeCaseKeysMatchJSONEncoder() throws {
    let encoder = CBORLDValueEncoder(keyEncodingStrategy: .convertToSnakeCase)
    // Recorded from JSONEncoder, including its handling of leading acronyms
    // and its rule that `[String: Value]` keys are not converted.
    let expected: JSONValue = [
      "a": 5, "a_b": 6, "already_snake": 7, "dictionary": ["keepMyCase": 9],
      "h_ttp_server_error": 8, "my_url_property": 1, "simple_value": 2, "u_rl_value": 4,
      "value2_go": 3,
    ]
    XCTAssertEqual(try encoder.encode(SnakeModel()), expected)

    let roundTrip = try encoder.encode(Profile(displayName: "Ada", emailAddress: "a@example.com"))
    XCTAssertEqual(roundTrip, ["display_name": "Ada", "email_address": "a@example.com"])
    let decoder = CBORLDValueDecoder(keyDecodingStrategy: .convertFromSnakeCase)
    XCTAssertEqual(
      try decoder.decode(Profile.self, from: roundTrip),
      Profile(displayName: "Ada", emailAddress: "a@example.com"))
    XCTAssertEqual(
      try decoder.decode(Profile.self, from: ["_display_name_": "x", "email_address": "y"])
        .displayName,
      nil)
    XCTAssertEqual(
      SnakeCaseKeys.camelCase(fromSnakeCase: "__leading_and_trailing__"), "__leadingAndTrailing__")
    XCTAssertEqual(SnakeCaseKeys.camelCase(fromSnakeCase: "___"), "___")

    let custom = CBORLDValueEncoder(
      keyEncodingStrategy: .custom { path in
        ValueCodingKey(stringValue: path.last!.stringValue.uppercased())
      })
    XCTAssertEqual(
      try custom.encode(Profile(displayName: "a", emailAddress: "b")),
      ["DISPLAYNAME": "a", "EMAILADDRESS": "b"])
    let customDecoder = CBORLDValueDecoder(
      keyDecodingStrategy: .custom { path in
        ValueCodingKey(stringValue: path.last!.stringValue.lowercased())
      })
    XCTAssertEqual(
      try customDecoder.decode(Lowercase.self, from: ["VALUE": 3]), Lowercase(value: 3))
  }

  func testDateAndDataStrategiesRoundTrip() throws {
    let date = Date(timeIntervalSince1970: 1_617_999_535)
    let cases:
      [(
        CBORLDValueEncoder.DateEncodingStrategy, CBORLDValueDecoder.DateDecodingStrategy, JSONValue
      )] = [
        (.deferredToDate, .deferredToDate, .number(date.timeIntervalSinceReferenceDate)),
        (.secondsSince1970, .secondsSince1970, 1_617_999_535),
        (.millisecondsSince1970, .millisecondsSince1970, 1_617_999_535_000),
        (.iso8601, .iso8601, "2021-04-09T20:18:55Z"),
        (
          .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode("day-\(Int(date.timeIntervalSince1970) / 86_400)")
          },
          .custom { decoder in
            let text = try decoder.singleValueContainer().decode(String.self)
            return Date(timeIntervalSince1970: TimeInterval(Int(text.dropFirst(4))! * 86_400))
          },
          "day-18726"
        ),
      ]
    for (encoding, decoding, expected) in cases {
      let encoded = try CBORLDValueEncoder(dateEncodingStrategy: encoding).encode(Stamp(at: date))
      XCTAssertEqual(encoded, ["at": expected])
      let decoded = try CBORLDValueDecoder(dateDecodingStrategy: decoding).decode(
        Stamp.self, from: encoded)
      if case .custom = decoding {
        XCTAssertEqual(decoded.at.timeIntervalSince1970, 18_726 * 86_400)
      } else {
        XCTAssertEqual(decoded.at, date)
      }
    }
    XCTAssertThrowsError(
      try CBORLDValueDecoder(dateDecodingStrategy: .iso8601).decode(
        Stamp.self, from: ["at": "yesterday"]))

    let bytes = Data([0, 255, 16])
    XCTAssertEqual(try CBORLDValueEncoder().encode(Blob(bytes: bytes)), ["bytes": "AP8Q"])
    let deferred = try CBORLDValueEncoder(dataEncodingStrategy: .deferredToData).encode(
      Blob(bytes: bytes))
    XCTAssertEqual(deferred, ["bytes": [0, 255, 16]])
    XCTAssertEqual(
      try CBORLDValueDecoder(dataDecodingStrategy: .deferredToData).decode(
        Blob.self, from: deferred
      ).bytes,
      bytes)
    let hexEncoder = CBORLDValueEncoder(
      dataEncodingStrategy: .custom { data, encoder in
        var container = encoder.singleValueContainer()
        try container.encode(data.hexString)
      })
    let hexDecoder = CBORLDValueDecoder(
      dataDecodingStrategy: .custom { decoder in
        Data(hexString: try decoder.singleValueContainer().decode(String.self))
      })
    let hexEncoded = try hexEncoder.encode(Blob(bytes: bytes))
    XCTAssertEqual(hexEncoded, ["bytes": "00ff10"])
    XCTAssertEqual(try hexDecoder.decode(Blob.self, from: hexEncoded).bytes, bytes)
    XCTAssertThrowsError(
      try CBORLDValueDecoder().decode(Blob.self, from: ["bytes": "*not base64*"]))
  }

  func testNonConformingFloatsAndIntegerRange() throws {
    XCTAssertThrowsError(try CBORLDValueEncoder().encode([Double.infinity])) { error in
      guard case EncodingError.invalidValue = error else {
        return XCTFail("Expected invalidValue, received \(error).")
      }
    }
    let strings = CBORLDValueEncoder(
      nonConformingFloatEncodingStrategy: .convertToString(
        positiveInfinity: "+inf", negativeInfinity: "-inf", nan: "nan"))
    let encoded = try strings.encode([Double.infinity, -Double.infinity, Double.nan, 1.5])
    XCTAssertEqual(encoded, ["+inf", "-inf", "nan", 1.5])
    XCTAssertEqual(try strings.encode([Float.infinity]), ["+inf"])

    let decoder = CBORLDValueDecoder(
      nonConformingFloatDecodingStrategy: .convertFromString(
        positiveInfinity: "+inf", negativeInfinity: "-inf", nan: "nan"))
    let decoded = try decoder.decode([Double].self, from: encoded)
    XCTAssertEqual(decoded[0], .infinity)
    XCTAssertEqual(decoded[1], -.infinity)
    XCTAssertTrue(decoded[2].isNaN)
    XCTAssertEqual(try decoder.decode([Float].self, from: ["+inf"]), [.infinity])
    XCTAssertThrowsError(try CBORLDValueDecoder().decode([Double].self, from: ["+inf"]))

    // JSONValue integers are Int64; wider values are refused, not rounded.
    XCTAssertThrowsError(try CBORLDValueEncoder().encode([UInt64.max]))
    XCTAssertEqual(try CBORLDValueEncoder().encode([UInt64(Int64.max)]), [.integer(.max)])
    XCTAssertEqual(try CBORLDValueEncoder().encode([Int64.min]), [.integer(.min)])
    XCTAssertEqual(try CBORLDValueEncoder().encode(Float(0.1)), .number(0.1))
    XCTAssertEqual(try CBORLDValueEncoder().encode(Decimal(string: "12.50")!), .number(12.5))
  }

  func testContainersSuperEncodersAndUserInfo() throws {
    let key = CodingUserInfoKey(rawValue: "suffix")!
    let encoder = CBORLDValueEncoder(userInfo: [key: "!"])
    let value = try encoder.encode(Derived(base: 1, extra: "x", items: [1, 2], pairs: [[3, 4]]))
    XCTAssertEqual(
      value,
      [
        "super": ["base": 1], "extra": "x!", "nested": ["items": [1, 2], "pairs": [[3, 4]]],
        "list": [["kind": "first"], [5], ["base": 9]],
        "nothing": .null,
      ])
    let decoded = try CBORLDValueDecoder(userInfo: [key: "!"]).decode(Derived.self, from: value)
    XCTAssertEqual(decoded, Derived(base: 1, extra: "x", items: [1, 2], pairs: [[3, 4]]))

    // A value that encodes nothing is an empty object when nested and an
    // error at the top level, as with JSONEncoder.
    XCTAssertEqual(try CBORLDValueEncoder().encode([Silent()]), [[:]])
    XCTAssertThrowsError(try CBORLDValueEncoder().encode(Silent()))
    XCTAssertEqual(try CBORLDValueEncoder().encode(Optional<Int>.none), .null)
    XCTAssertEqual(try CBORLDValueEncoder().encode(Maybe(value: nil)), [:])
    let passthrough: JSONValue = ["kept": [1, "two", .null]]
    XCTAssertEqual(
      try CBORLDValueEncoder().encode(["wrapped": passthrough]), ["wrapped": passthrough])
  }

  func testDecoderNumericNarrowingAndOverflow() throws {
    let decoder = CBORLDValueDecoder()
    XCTAssertEqual(try decoder.decode(Int8.self, from: 127), 127)
    XCTAssertEqual(try decoder.decode(Int.self, from: 3.0), 3)
    XCTAssertEqual(try decoder.decode(Float.self, from: 2), 2)
    for (type, value): (any Decodable.Type, JSONValue) in [
      (Int8.self, 300), (UInt.self, -1), (UInt8.self, 256.0), (Float.self, 1e300),
    ] {
      XCTAssertThrowsError(try decode(type, value, decoder)) { error in
        guard case DecodingError.dataCorrupted = error else {
          return XCTFail("\(type) from \(value): expected dataCorrupted, received \(error)")
        }
      }
    }
    for (type, value): (any Decodable.Type, JSONValue) in [
      (Int.self, 1.5), (Int.self, "1"), (Bool.self, 1), (String.self, 2), (Double.self, true),
    ] {
      XCTAssertThrowsError(try decode(type, value, decoder)) { error in
        guard case DecodingError.typeMismatch = error else {
          return XCTFail("\(type) from \(value): expected typeMismatch, received \(error)")
        }
      }
    }
    XCTAssertEqual(try decoder.decode(Decimal.self, from: "12.5"), Decimal(string: "12.5"))
    XCTAssertEqual(try decoder.decode(Decimal.self, from: 7), 7)
    XCTAssertThrowsError(try decoder.decode(Decimal.self, from: "x"))
    XCTAssertThrowsError(try decoder.decode(URL.self, from: 1))
    XCTAssertEqual(try decoder.decode(JSONValue.self, from: [1]), [1])
  }

  func testDecoderMissingNullAndMalformedContainers() throws {
    let decoder = CBORLDValueDecoder()
    XCTAssertNil(try decoder.decode(Maybe.self, from: [:]).value)
    XCTAssertNil(try decoder.decode(Maybe.self, from: ["value": .null]).value)
    XCTAssertEqual(try decoder.decode(Maybe.self, from: ["value": 4]).value, 4)
    XCTAssertThrowsError(try decoder.decode(Required.self, from: [:])) { error in
      guard case DecodingError.keyNotFound = error else {
        return XCTFail("Expected keyNotFound, received \(error).")
      }
    }
    // As with JSONDecoder, null where a value is required is valueNotFound.
    XCTAssertThrowsError(try decoder.decode(Required.self, from: ["value": .null])) { error in
      guard case DecodingError.valueNotFound = error else {
        return XCTFail("Expected valueNotFound, received \(error).")
      }
    }
    XCTAssertThrowsError(try decoder.decode(Required.self, from: .null)) { error in
      guard case DecodingError.valueNotFound = error else {
        return XCTFail("Expected valueNotFound, received \(error).")
      }
    }
    XCTAssertThrowsError(try decoder.decode(Required.self, from: [1]))
    XCTAssertThrowsError(try decoder.decode([Int].self, from: ["a": 1]))
    XCTAssertThrowsError(try decoder.decode(Pair.self, from: [1])) { error in
      guard case DecodingError.valueNotFound = error else {
        return XCTFail("Expected valueNotFound, received \(error).")
      }
    }
    let inspected = try decoder.decode(KeyInspector.self, from: ["b": 1, "a": .null])
    XCTAssertEqual(inspected.keys, ["a", "b"])
    XCTAssertTrue(inspected.aIsNull)
    XCTAssertEqual(try decoder.decode([Int?].self, from: [1, .null, 3]), [1, nil, 3])
  }

  private func decode(
    _ type: any Decodable.Type,
    _ value: JSONValue,
    _ decoder: CBORLDValueDecoder
  ) throws {
    _ = try decoder.decode(type, from: value)
  }
}

// MARK: - Fixtures

struct BaselineModel: Codable, Sendable {
  struct Nested: Codable, Sendable {
    var name: String
    var weights: [Double]
  }

  enum Kind: String, Codable, Sendable { case alpha, beta }

  var id: Int
  var small: UInt8
  var flag: Bool
  var ratio: Double
  var single: Float
  var created: Date
  var payload: Data
  var link: URL
  var amount: Decimal
  var optional: String?
  var kind: Kind
  var nested: Nested
  var tags: [String]
  var counts: [String: Int]
  var bigDouble: Double
  var hugeDouble: Double
  var negativeZero: Double
  var floatMax: Float
  var bigDecimal: Decimal
  var fractionDecimal: Decimal

  static let sample = BaselineModel(
    id: -42, small: 200, flag: true, ratio: 0.1, single: 0.1,
    created: Date(timeIntervalSinceReferenceDate: 12345.678),
    payload: Data([0, 1, 2, 250]),
    link: URL(string: "https://example.com/a?b=c")!,
    amount: Decimal(string: "12.50")!,
    optional: nil, kind: .beta,
    nested: Nested(name: "n", weights: [1, 2.5, -3]),
    tags: ["x", "y"], counts: ["b": 2, "a": 1],
    bigDouble: 9_007_199_254_740_994, hugeDouble: 1e20, negativeZero: -0.0,
    floatMax: .greatestFiniteMagnitude,
    bigDecimal: Decimal(string: "12345678901234567890")!,
    fractionDecimal: Decimal(string: "0.3")!)
}

// The property names reproduce JSONEncoder's snake-case edge cases.
// swift-format-ignore: AlwaysUseLowerCamelCase
private struct SnakeModel: Codable {
  var myURLProperty = 1
  var simpleValue = 2
  var value2Go = 3
  var URLValue = 4
  var a = 5
  var aB = 6
  var already_snake = 7
  var HTTPServerError = 8
  var dictionary: [String: Int] = ["keepMyCase": 9]
}

private struct Profile: Codable, Equatable {
  var displayName: String?
  var emailAddress: String
}

private struct Lowercase: Codable, Equatable {
  var value: Int
}

private struct Stamp: Codable {
  var at: Date
}

private struct Blob: Codable {
  var bytes: Data
}

private struct Silent: Encodable {
  func encode(to encoder: Encoder) throws {}
}

private struct Maybe: Codable {
  var value: Int?
}

private struct Required: Codable {
  var value: Int
}

private struct Pair: Decodable {
  var first: Int
  var second: Int

  init(from decoder: Decoder) throws {
    var container = try decoder.unkeyedContainer()
    first = try container.decode(Int.self)
    second = try container.decode(Int.self)
  }
}

private struct KeyInspector: Decodable {
  var keys: [String]
  var aIsNull: Bool

  private struct AnyKey: CodingKey {
    var stringValue: String
    var intValue: Int? { nil }
    init(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { nil }
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: AnyKey.self)
    keys = container.allKeys.map(\.stringValue).sorted()
    aIsNull = try container.decodeNil(forKey: AnyKey(stringValue: "a"))
    XCTAssertTrue(container.contains(AnyKey(stringValue: "b")))
    XCTAssertThrowsError(try container.decodeNil(forKey: AnyKey(stringValue: "missing")))
  }
}

/// Exercises keyed, nested, unkeyed, super, and user-info paths in one model.
private final class Derived: Base, Equatable {
  let extra: String
  let items: [Int]
  let pairs: [[Int]]

  init(base: Int, extra: String, items: [Int], pairs: [[Int]]) {
    self.extra = extra
    self.items = items
    self.pairs = pairs
    super.init(base: base)
  }

  private enum Keys: String, CodingKey { case extra, nested, list, nothing }
  private enum NestedKeys: String, CodingKey { case items, pairs }
  private enum KindKey: String, CodingKey { case kind }

  override func encode(to encoder: Encoder) throws {
    let suffix = encoder.userInfo[CodingUserInfoKey(rawValue: "suffix")!] as? String ?? ""
    var container = encoder.container(keyedBy: Keys.self)
    try container.encode(extra + suffix, forKey: .extra)
    var nested = container.nestedContainer(keyedBy: NestedKeys.self, forKey: .nested)
    try nested.encode(items, forKey: .items)
    var pairsContainer = nested.nestedUnkeyedContainer(forKey: .pairs)
    for pair in pairs {
      var inner = pairsContainer.nestedUnkeyedContainer()
      for value in pair { try inner.encode(value) }
    }
    var list = container.nestedUnkeyedContainer(forKey: .list)
    var first = list.nestedContainer(keyedBy: KindKey.self)
    try first.encode("first", forKey: .kind)
    var second = list.nestedUnkeyedContainer()
    try second.encode(5)
    try Base(base: 9).encode(to: list.superEncoder())
    try container.encodeNil(forKey: .nothing)
    try super.encode(to: container.superEncoder())
  }

  required init(from decoder: Decoder) throws {
    let suffix = decoder.userInfo[CodingUserInfoKey(rawValue: "suffix")!] as? String ?? ""
    let container = try decoder.container(keyedBy: Keys.self)
    extra = String(try container.decode(String.self, forKey: .extra).dropLast(suffix.count))
    let nested = try container.nestedContainer(keyedBy: NestedKeys.self, forKey: .nested)
    items = try nested.decode([Int].self, forKey: .items)
    var pairsContainer = try nested.nestedUnkeyedContainer(forKey: .pairs)
    var pairs: [[Int]] = []
    while !pairsContainer.isAtEnd {
      var inner = try pairsContainer.nestedUnkeyedContainer()
      var pair: [Int] = []
      while !inner.isAtEnd { pair.append(try inner.decode(Int.self)) }
      pairs.append(pair)
    }
    self.pairs = pairs
    var list = try container.nestedUnkeyedContainer(forKey: .list)
    XCTAssertEqual(
      try list.nestedContainer(keyedBy: KindKey.self).decode(String.self, forKey: .kind), "first")
    var second = try list.nestedUnkeyedContainer()
    XCTAssertEqual(try second.decode(Int.self), 5)
    XCTAssertEqual(try Base(from: list.superDecoder()).base, 9)
    XCTAssertTrue(try container.decodeNil(forKey: .nothing))
    try super.init(from: container.superDecoder())
  }

  static func == (lhs: Derived, rhs: Derived) -> Bool {
    lhs.base == rhs.base && lhs.extra == rhs.extra && lhs.items == rhs.items
      && lhs.pairs == rhs.pairs
  }
}

private class Base: Codable {
  let base: Int

  init(base: Int) {
    self.base = base
  }
}
