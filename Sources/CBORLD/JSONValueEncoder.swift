import Foundation

/// A Swift `Encoder` that produces a ``JSONValue`` tree directly.
///
/// It replaces the `JSONEncoder` → JSON text → ``JSONValue`` round trip used
/// for typed encoding, removing a serialization pass, a temporary text
/// buffer, and a complete parse. With default strategies its results equal
/// `JSONEncoder`'s: dates are seconds since the reference date, `Data` is
/// base64, `URL` is its absolute string, `Decimal` is a number, and
/// `Float` values keep their shortest decimal spelling.
///
/// Unlike the text round trip, integers outside the `Int64` range are
/// rejected instead of silently losing precision.
public struct CBORLDValueEncoder: Sendable {
  public enum DateEncodingStrategy: Sendable {
    /// Use the `Date` type's own encoding: seconds since 2001-01-01.
    case deferredToDate
    case secondsSince1970
    case millisecondsSince1970
    /// An RFC 3339 string with no fractional seconds.
    case iso8601
    case custom(@Sendable (Date, any Encoder) throws -> Void)
  }

  public enum DataEncodingStrategy: Sendable {
    /// Use the `Data` type's own encoding: an array of byte values.
    case deferredToData
    case base64
    case custom(@Sendable (Data, any Encoder) throws -> Void)
  }

  public enum NonConformingFloatEncodingStrategy: Sendable {
    /// Throw for infinities and NaN, which JSON cannot represent.
    case `throw`
    case convertToString(positiveInfinity: String, negativeInfinity: String, nan: String)
  }

  public enum KeyEncodingStrategy: Sendable {
    case useDefaultKeys
    /// `myURLProperty` becomes `my_url_property`, matching `JSONEncoder`.
    /// Keys of `[String: Value]` dictionaries are not converted.
    case convertToSnakeCase
    case custom(@Sendable ([any CodingKey]) -> any CodingKey)
  }

  public var dateEncodingStrategy: DateEncodingStrategy
  public var dataEncodingStrategy: DataEncodingStrategy
  public var nonConformingFloatEncodingStrategy: NonConformingFloatEncodingStrategy
  public var keyEncodingStrategy: KeyEncodingStrategy
  public var userInfo: [CodingUserInfoKey: any Sendable]

  public init(
    dateEncodingStrategy: DateEncodingStrategy = .deferredToDate,
    dataEncodingStrategy: DataEncodingStrategy = .base64,
    nonConformingFloatEncodingStrategy: NonConformingFloatEncodingStrategy = .throw,
    keyEncodingStrategy: KeyEncodingStrategy = .useDefaultKeys,
    userInfo: [CodingUserInfoKey: any Sendable] = [:]
  ) {
    self.dateEncodingStrategy = dateEncodingStrategy
    self.dataEncodingStrategy = dataEncodingStrategy
    self.nonConformingFloatEncodingStrategy = nonConformingFloatEncodingStrategy
    self.keyEncodingStrategy = keyEncodingStrategy
    self.userInfo = userInfo
  }

  public func encode<T: Encodable>(_ value: T) throws -> JSONValue {
    let encoder = ValueEncoderImplementation(
      options: ValueEncoderOptions(self),
      codingPath: [])
    guard let node = try encoder.wrap(value, codingPath: []) else {
      throw EncodingError.invalidValue(
        value,
        .init(codingPath: [], debugDescription: "Top-level \(T.self) did not encode any values."))
    }
    return node.materialized
  }
}

private struct ValueEncoderOptions {
  let date: CBORLDValueEncoder.DateEncodingStrategy
  let data: CBORLDValueEncoder.DataEncodingStrategy
  let nonConformingFloat: CBORLDValueEncoder.NonConformingFloatEncodingStrategy
  let key: CBORLDValueEncoder.KeyEncodingStrategy
  let userInfo: [CodingUserInfoKey: Any]

  init(_ encoder: CBORLDValueEncoder) {
    date = encoder.dateEncodingStrategy
    data = encoder.dataEncodingStrategy
    nonConformingFloat = encoder.nonConformingFloatEncodingStrategy
    key = encoder.keyEncodingStrategy
    userInfo = Dictionary(uniqueKeysWithValues: encoder.userInfo.map { ($0.key, $0.value) })
  }
}

// MARK: - Mutable tree

/// Containers are references so that nested containers handed out earlier
/// keep writing into the same tree, as `Encoder` requires.
private final class ObjectNode {
  var entries: [String: EncodedNode] = [:]
}

private final class ArrayNode {
  var elements: [EncodedNode] = []
}

private enum EncodedNode {
  case value(JSONValue)
  case object(ObjectNode)
  case array(ArrayNode)
  /// A super encoder whose result is read when the tree is materialized.
  case deferred(ValueEncoderImplementation)

  var materialized: JSONValue {
    switch self {
    case .value(let value):
      return value
    case .object(let node):
      return .object(node.entries.mapValues(\.materialized))
    case .array(let node):
      return .array(node.elements.map(\.materialized))
    case .deferred(let encoder):
      return encoder.node?.materialized ?? .object([:])
    }
  }
}

// MARK: - Encoder

private final class ValueEncoderImplementation: Encoder {
  let options: ValueEncoderOptions
  let codingPath: [any CodingKey]
  var node: EncodedNode?

  var userInfo: [CodingUserInfoKey: Any] { options.userInfo }

  init(options: ValueEncoderOptions, codingPath: [any CodingKey]) {
    self.options = options
    self.codingPath = codingPath
  }

  func container<Key: CodingKey>(keyedBy type: Key.Type) -> KeyedEncodingContainer<Key> {
    let object: ObjectNode
    switch node {
    case .object(let existing):
      object = existing
    case nil:
      object = ObjectNode()
      node = .object(object)
    default:
      preconditionFailure(
        "Attempt to push new keyed encoding container when already previously encoded at this path."
      )
    }
    return KeyedEncodingContainer(
      ValueKeyedEncodingContainer<Key>(encoder: self, object: object, codingPath: codingPath))
  }

  func unkeyedContainer() -> any UnkeyedEncodingContainer {
    let array: ArrayNode
    switch node {
    case .array(let existing):
      array = existing
    case nil:
      array = ArrayNode()
      node = .array(array)
    default:
      preconditionFailure(
        "Attempt to push new unkeyed encoding container when already previously encoded at this path."
      )
    }
    return ValueUnkeyedEncodingContainer(encoder: self, array: array, codingPath: codingPath)
  }

  func singleValueContainer() -> any SingleValueEncodingContainer {
    ValueSingleEncodingContainer(encoder: self, codingPath: codingPath)
  }

  // MARK: Boxing

  func wrap(_ value: Bool) -> EncodedNode { .value(.bool(value)) }
  func wrap(_ value: String) -> EncodedNode { .value(.string(value)) }

  func wrap<T: BinaryInteger>(_ value: T, codingPath: [any CodingKey]) throws -> EncodedNode {
    guard let integer = Int64(exactly: value) else {
      throw EncodingError.invalidValue(
        value,
        .init(
          codingPath: codingPath,
          debugDescription:
            "\(value) is outside the Int64 range that JSONValue represents exactly."))
    }
    return .value(.integer(integer))
  }

  /// Integral values that fit `Int64` become integers, as they did when JSON
  /// text was parsed back; this keeps the encoded bytes of values beyond the
  /// safe-integer range unchanged.
  func wrap(_ value: Double, codingPath: [any CodingKey]) throws -> EncodedNode {
    guard value.isFinite else { return try nonConforming(value, codingPath: codingPath) }
    if let integer = Int64(exactly: value) { return .value(.integer(integer)) }
    return .value(.number(value))
  }

  /// `JSONEncoder` writes a `Float` as its shortest decimal spelling, which
  /// then parses as the nearest `Double`. Reproduce that value exactly.
  func wrap(_ value: Float, codingPath: [any CodingKey]) throws -> EncodedNode {
    guard value.isFinite else { return try nonConforming(Double(value), codingPath: codingPath) }
    return try wrap(Double(value.description) ?? Double(value), codingPath: codingPath)
  }

  private func nonConforming(_ value: Double, codingPath: [any CodingKey]) throws -> EncodedNode {
    guard
      case .convertToString(let positiveInfinity, let negativeInfinity, let nan) =
        options.nonConformingFloat
    else {
      throw EncodingError.invalidValue(
        value,
        .init(
          codingPath: codingPath,
          debugDescription:
            "Unable to encode \(value) directly in JSON. Use NonConformingFloatEncodingStrategy.convertToString to specify how the value should be encoded."
        ))
    }
    if value.isNaN { return .value(.string(nan)) }
    return .value(.string(value > 0 ? positiveInfinity : negativeInfinity))
  }

  /// Returns `nil` only when a value encoded nothing at all.
  func wrap<T: Encodable>(_ value: T, codingPath: [any CodingKey]) throws -> EncodedNode? {
    switch value {
    case let json as JSONValue:
      return .value(json)
    case let date as Date:
      return try wrap(date, codingPath: codingPath)
    case let data as Data:
      return try wrap(data, codingPath: codingPath)
    case let url as URL:
      return .value(.string(url.absoluteString))
    case let decimal as Decimal:
      return .value(Self.number(decimal))
    case let dictionary as any StringKeyedEncodableDictionary:
      return .object(try dictionary.encodeEntries(with: self, codingPath: codingPath))
    default:
      let encoder = ValueEncoderImplementation(options: options, codingPath: codingPath)
      try value.encode(to: encoder)
      return encoder.node
    }
  }

  /// Wraps a nested value, encoding an empty object when it encoded nothing.
  func wrapNested<T: Encodable>(_ value: T, codingPath: [any CodingKey]) throws -> EncodedNode {
    try wrap(value, codingPath: codingPath) ?? .object(ObjectNode())
  }

  private func wrap(_ date: Date, codingPath: [any CodingKey]) throws -> EncodedNode? {
    switch options.date {
    case .deferredToDate:
      let encoder = ValueEncoderImplementation(options: options, codingPath: codingPath)
      try date.encode(to: encoder)
      return encoder.node
    case .secondsSince1970:
      return try wrap(date.timeIntervalSince1970, codingPath: codingPath)
    case .millisecondsSince1970:
      return try wrap(1_000 * date.timeIntervalSince1970, codingPath: codingPath)
    case .iso8601:
      let formatter = ISO8601DateFormatter()
      formatter.formatOptions = .withInternetDateTime
      return .value(.string(formatter.string(from: date)))
    case .custom(let closure):
      let encoder = ValueEncoderImplementation(options: options, codingPath: codingPath)
      try closure(date, encoder)
      return encoder.node ?? .object(ObjectNode())
    }
  }

  private func wrap(_ data: Data, codingPath: [any CodingKey]) throws -> EncodedNode? {
    switch options.data {
    case .deferredToData:
      let encoder = ValueEncoderImplementation(options: options, codingPath: codingPath)
      try data.encode(to: encoder)
      return encoder.node
    case .base64:
      return .value(.string(data.base64EncodedString()))
    case .custom(let closure):
      let encoder = ValueEncoderImplementation(options: options, codingPath: codingPath)
      try closure(data, encoder)
      return encoder.node ?? .object(ObjectNode())
    }
  }

  /// `JSONEncoder` writes a `Decimal` as its decimal description, which then
  /// parses as an integer when it fits and as a `Double` otherwise.
  private static func number(_ decimal: Decimal) -> JSONValue {
    let description = decimal.description
    if let integer = Int64(description) { return .integer(integer) }
    return .number(Double(description) ?? NSDecimalNumber(decimal: decimal).doubleValue)
  }

  func convertedKey(_ key: any CodingKey, codingPath: [any CodingKey]) -> String {
    switch options.key {
    case .useDefaultKeys:
      return key.stringValue
    case .convertToSnakeCase:
      return SnakeCaseKeys.snakeCase(key.stringValue)
    case .custom(let convert):
      return convert(codingPath + [key]).stringValue
    }
  }
}

/// `[String: Value]` dictionaries keep their keys under every key strategy, as
/// with `JSONEncoder`.
private protocol StringKeyedEncodableDictionary {
  func encodeEntries(
    with encoder: ValueEncoderImplementation,
    codingPath: [any CodingKey]
  ) throws -> ObjectNode
}

extension Dictionary: StringKeyedEncodableDictionary where Key == String, Value: Encodable {
  fileprivate func encodeEntries(
    with encoder: ValueEncoderImplementation,
    codingPath: [any CodingKey]
  ) throws -> ObjectNode {
    let object = ObjectNode()
    for (key, value) in self {
      object.entries[key] = try encoder.wrapNested(
        value, codingPath: codingPath + [ValueCodingKey(stringValue: key)])
    }
    return object
  }
}

// MARK: - Containers

private struct ValueKeyedEncodingContainer<Key: CodingKey>: KeyedEncodingContainerProtocol {
  let encoder: ValueEncoderImplementation
  let object: ObjectNode
  let codingPath: [any CodingKey]

  private func name(_ key: Key) -> String {
    encoder.convertedKey(key, codingPath: codingPath)
  }

  mutating func encodeNil(forKey key: Key) throws { object.entries[name(key)] = .value(.null) }
  mutating func encode(_ value: Bool, forKey key: Key) throws {
    object.entries[name(key)] = encoder.wrap(value)
  }
  mutating func encode(_ value: String, forKey key: Key) throws {
    object.entries[name(key)] = encoder.wrap(value)
  }
  mutating func encode(_ value: Double, forKey key: Key) throws {
    object.entries[name(key)] = try encoder.wrap(value, codingPath: codingPath + [key])
  }
  mutating func encode(_ value: Float, forKey key: Key) throws {
    object.entries[name(key)] = try encoder.wrap(value, codingPath: codingPath + [key])
  }
  mutating func encode(_ value: Int, forKey key: Key) throws { try integer(value, key) }
  mutating func encode(_ value: Int8, forKey key: Key) throws { try integer(value, key) }
  mutating func encode(_ value: Int16, forKey key: Key) throws { try integer(value, key) }
  mutating func encode(_ value: Int32, forKey key: Key) throws { try integer(value, key) }
  mutating func encode(_ value: Int64, forKey key: Key) throws { try integer(value, key) }
  mutating func encode(_ value: UInt, forKey key: Key) throws { try integer(value, key) }
  mutating func encode(_ value: UInt8, forKey key: Key) throws { try integer(value, key) }
  mutating func encode(_ value: UInt16, forKey key: Key) throws { try integer(value, key) }
  mutating func encode(_ value: UInt32, forKey key: Key) throws { try integer(value, key) }
  mutating func encode(_ value: UInt64, forKey key: Key) throws { try integer(value, key) }

  mutating func encode<T: Encodable>(_ value: T, forKey key: Key) throws {
    object.entries[name(key)] = try encoder.wrapNested(value, codingPath: codingPath + [key])
  }

  private func integer<T: BinaryInteger>(_ value: T, _ key: Key) throws {
    object.entries[name(key)] = try encoder.wrap(value, codingPath: codingPath + [key])
  }

  mutating func nestedContainer<NestedKey: CodingKey>(
    keyedBy keyType: NestedKey.Type,
    forKey key: Key
  ) -> KeyedEncodingContainer<NestedKey> {
    let name = name(key)
    let nested: ObjectNode
    if case .object(let existing) = object.entries[name] {
      nested = existing
    } else {
      nested = ObjectNode()
      object.entries[name] = .object(nested)
    }
    return KeyedEncodingContainer(
      ValueKeyedEncodingContainer<NestedKey>(
        encoder: encoder, object: nested, codingPath: codingPath + [key]))
  }

  mutating func nestedUnkeyedContainer(forKey key: Key) -> any UnkeyedEncodingContainer {
    let name = name(key)
    let nested: ArrayNode
    if case .array(let existing) = object.entries[name] {
      nested = existing
    } else {
      nested = ArrayNode()
      object.entries[name] = .array(nested)
    }
    return ValueUnkeyedEncodingContainer(
      encoder: encoder, array: nested, codingPath: codingPath + [key])
  }

  mutating func superEncoder() -> any Encoder {
    superEncoder(named: "super", key: ValueCodingKey(stringValue: "super"))
  }

  mutating func superEncoder(forKey key: Key) -> any Encoder {
    superEncoder(named: name(key), key: key)
  }

  private func superEncoder(named name: String, key: any CodingKey) -> any Encoder {
    let child = ValueEncoderImplementation(options: encoder.options, codingPath: codingPath + [key])
    object.entries[name] = .deferred(child)
    return child
  }
}

private struct ValueUnkeyedEncodingContainer: UnkeyedEncodingContainer {
  let encoder: ValueEncoderImplementation
  let array: ArrayNode
  let codingPath: [any CodingKey]

  var count: Int { array.elements.count }

  private var nextKey: any CodingKey { ValueCodingKey(intValue: array.elements.count) }

  mutating func encodeNil() throws { array.elements.append(.value(.null)) }
  mutating func encode(_ value: Bool) throws { array.elements.append(encoder.wrap(value)) }
  mutating func encode(_ value: String) throws { array.elements.append(encoder.wrap(value)) }
  mutating func encode(_ value: Double) throws {
    array.elements.append(try encoder.wrap(value, codingPath: codingPath + [nextKey]))
  }
  mutating func encode(_ value: Float) throws {
    array.elements.append(try encoder.wrap(value, codingPath: codingPath + [nextKey]))
  }
  mutating func encode(_ value: Int) throws { try integer(value) }
  mutating func encode(_ value: Int8) throws { try integer(value) }
  mutating func encode(_ value: Int16) throws { try integer(value) }
  mutating func encode(_ value: Int32) throws { try integer(value) }
  mutating func encode(_ value: Int64) throws { try integer(value) }
  mutating func encode(_ value: UInt) throws { try integer(value) }
  mutating func encode(_ value: UInt8) throws { try integer(value) }
  mutating func encode(_ value: UInt16) throws { try integer(value) }
  mutating func encode(_ value: UInt32) throws { try integer(value) }
  mutating func encode(_ value: UInt64) throws { try integer(value) }

  mutating func encode<T: Encodable>(_ value: T) throws {
    array.elements.append(try encoder.wrapNested(value, codingPath: codingPath + [nextKey]))
  }

  private func integer<T: BinaryInteger>(_ value: T) throws {
    array.elements.append(try encoder.wrap(value, codingPath: codingPath + [nextKey]))
  }

  mutating func nestedContainer<NestedKey: CodingKey>(
    keyedBy keyType: NestedKey.Type
  ) -> KeyedEncodingContainer<NestedKey> {
    let key = nextKey
    let nested = ObjectNode()
    array.elements.append(.object(nested))
    return KeyedEncodingContainer(
      ValueKeyedEncodingContainer<NestedKey>(
        encoder: encoder, object: nested, codingPath: codingPath + [key]))
  }

  mutating func nestedUnkeyedContainer() -> any UnkeyedEncodingContainer {
    let key = nextKey
    let nested = ArrayNode()
    array.elements.append(.array(nested))
    return ValueUnkeyedEncodingContainer(
      encoder: encoder, array: nested, codingPath: codingPath + [key])
  }

  mutating func superEncoder() -> any Encoder {
    let child = ValueEncoderImplementation(
      options: encoder.options, codingPath: codingPath + [nextKey])
    array.elements.append(.deferred(child))
    return child
  }
}

private struct ValueSingleEncodingContainer: SingleValueEncodingContainer {
  let encoder: ValueEncoderImplementation
  let codingPath: [any CodingKey]

  private func store(_ node: EncodedNode) {
    precondition(
      encoder.node == nil,
      "Attempt to encode value through single value container when previously value already encoded."
    )
    encoder.node = node
  }

  mutating func encodeNil() throws { store(.value(.null)) }
  mutating func encode(_ value: Bool) throws { store(encoder.wrap(value)) }
  mutating func encode(_ value: String) throws { store(encoder.wrap(value)) }
  mutating func encode(_ value: Double) throws {
    store(try encoder.wrap(value, codingPath: codingPath))
  }
  mutating func encode(_ value: Float) throws {
    store(try encoder.wrap(value, codingPath: codingPath))
  }
  mutating func encode(_ value: Int) throws { try integer(value) }
  mutating func encode(_ value: Int8) throws { try integer(value) }
  mutating func encode(_ value: Int16) throws { try integer(value) }
  mutating func encode(_ value: Int32) throws { try integer(value) }
  mutating func encode(_ value: Int64) throws { try integer(value) }
  mutating func encode(_ value: UInt) throws { try integer(value) }
  mutating func encode(_ value: UInt8) throws { try integer(value) }
  mutating func encode(_ value: UInt16) throws { try integer(value) }
  mutating func encode(_ value: UInt32) throws { try integer(value) }
  mutating func encode(_ value: UInt64) throws { try integer(value) }

  mutating func encode<T: Encodable>(_ value: T) throws {
    store(try encoder.wrapNested(value, codingPath: codingPath))
  }

  private func integer<T: BinaryInteger>(_ value: T) throws {
    store(try encoder.wrap(value, codingPath: codingPath))
  }
}

// MARK: - Keys

struct ValueCodingKey: CodingKey {
  let stringValue: String
  let intValue: Int?

  init(stringValue: String) {
    self.stringValue = stringValue
    self.intValue = nil
  }

  init(intValue: Int) {
    self.stringValue = "Index \(intValue)"
    self.intValue = intValue
  }
}

/// Snake-case key conversion with the same word boundaries as Foundation's
/// JSON coders: a new word starts at each lowercase-to-uppercase transition,
/// and a run of capitals followed by a lowercase letter ends one capital
/// early (`myURLProperty` → `my_url_property`).
enum SnakeCaseKeys {
  static func snakeCase(_ key: String) -> String {
    let scalars = Array(key.unicodeScalars)
    guard scalars.count > 1 else { return key.lowercased() }
    let uppercase = CharacterSet.uppercaseLetters
    let lowercase = CharacterSet.lowercaseLetters
    var words: [Range<Int>] = []
    var wordStart = 0
    var searchStart = 1
    while let upper = (searchStart..<scalars.count).first(where: {
      uppercase.contains(scalars[$0])
    }) {
      words.append(wordStart..<upper)
      guard
        let lower = (upper..<scalars.count).first(where: { lowercase.contains(scalars[$0]) })
      else {
        wordStart = upper
        searchStart = scalars.count
        break
      }
      if lower == upper + 1 {
        wordStart = upper
      } else {
        words.append(upper..<(lower - 1))
        wordStart = lower - 1
      }
      searchStart = lower + 1
    }
    words.append(wordStart..<scalars.count)
    return words.map { range in
      var word = String.UnicodeScalarView()
      word.append(contentsOf: scalars[range])
      return String(word).lowercased()
    }.joined(separator: "_")
  }

  static func camelCase(fromSnakeCase key: String) -> String {
    guard let first = key.firstIndex(where: { $0 != "_" }) else { return key }
    var last = key.index(before: key.endIndex)
    while last > first, key[last] == "_" { key.formIndex(before: &last) }
    let body = key[first...last]
    let components = body.split(separator: "_")
    let joined: String
    if components.count == 1 {
      joined = String(body)
    } else {
      joined =
        components[0].lowercased()
        + components.dropFirst().map { $0.capitalized }.joined()
    }
    return String(key[..<first]) + joined + String(key[key.index(after: last)...])
  }
}
