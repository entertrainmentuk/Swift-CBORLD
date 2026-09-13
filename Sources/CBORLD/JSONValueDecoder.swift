import Foundation

/// A Swift `Decoder` backed directly by ``JSONValue``. It avoids serializing a
/// restored CBOR-LD document to JSON bytes and asking `JSONDecoder` to parse it
/// again. Its scalar, `Date`, and `Data` behavior matches `JSONDecoder`'s
/// default strategies.
public struct CBORLDValueDecoder: Sendable {
  public var userInfo: [CodingUserInfoKey: any Sendable]

  public init(userInfo: [CodingUserInfoKey: any Sendable] = [:]) {
    self.userInfo = userInfo
  }

  public func decode<T: Decodable>(_ type: T.Type, from value: JSONValue) throws -> T {
    try JSONValueDecoderImplementation(
      value: value,
      codingPath: [],
      userInfo: Dictionary(uniqueKeysWithValues: userInfo.map { ($0.key, $0.value) })
    ).unbox(type, from: value)
  }
}

private final class JSONValueDecoderImplementation: Decoder {
  let value: JSONValue
  let codingPath: [any CodingKey]
  let userInfo: [CodingUserInfoKey: Any]

  init(
    value: JSONValue,
    codingPath: [any CodingKey],
    userInfo: [CodingUserInfoKey: Any]
  ) {
    self.value = value
    self.codingPath = codingPath
    self.userInfo = userInfo
  }

  func container<Key: CodingKey>(
    keyedBy type: Key.Type
  ) throws -> KeyedDecodingContainer<Key> {
    guard case .object(let object) = value else {
      throw typeMismatch([String: JSONValue].self, value)
    }
    return KeyedDecodingContainer(
      JSONValueKeyedContainer<Key>(decoder: self, object: object))
  }

  func unkeyedContainer() throws -> any UnkeyedDecodingContainer {
    guard case .array(let array) = value else {
      throw typeMismatch([JSONValue].self, value)
    }
    return JSONValueUnkeyedContainer(decoder: self, array: array)
  }

  func singleValueContainer() throws -> any SingleValueDecodingContainer {
    JSONValueSingleContainer(decoder: self, value: value)
  }

  func child(_ value: JSONValue, key: any CodingKey) -> JSONValueDecoderImplementation {
    JSONValueDecoderImplementation(
      value: value,
      codingPath: codingPath + [key],
      userInfo: userInfo)
  }

  func unbox<T: Decodable>(_ type: T.Type, from value: JSONValue) throws -> T {
    if type == JSONValue.self { return value as! T }
    if type == Date.self {
      let seconds = try number(from: value)
      return Date(timeIntervalSinceReferenceDate: seconds) as! T
    }
    if type == Data.self {
      guard case .string(let string) = value,
        let data = Data(base64Encoded: string)
      else {
        throw typeMismatch(Data.self, value, "Expected a base64-encoded string.")
      }
      return data as! T
    }
    if type == URL.self {
      guard case .string(let string) = value, let url = URL(string: string) else {
        throw typeMismatch(URL.self, value)
      }
      return url as! T
    }
    if type == Decimal.self {
      let decimal: Decimal
      switch value {
      case .integer(let integer): decimal = Decimal(integer)
      case .number(let number): decimal = Decimal(number)
      case .string(let string):
        guard let parsed = Decimal(string: string, locale: Locale(identifier: "en_US_POSIX")) else {
          throw typeMismatch(Decimal.self, value)
        }
        decimal = parsed
      default: throw typeMismatch(Decimal.self, value)
      }
      return decimal as! T
    }
    return try T(
      from: JSONValueDecoderImplementation(
        value: value,
        codingPath: codingPath,
        userInfo: userInfo))
  }

  func bool(from value: JSONValue) throws -> Bool {
    guard case .bool(let result) = value else { throw typeMismatch(Bool.self, value) }
    return result
  }

  func string(from value: JSONValue) throws -> String {
    guard case .string(let result) = value else { throw typeMismatch(String.self, value) }
    return result
  }

  func number(from value: JSONValue) throws -> Double {
    switch value {
    case .integer(let result): return Double(result)
    case .number(let result): return result
    default: throw typeMismatch(Double.self, value)
    }
  }

  func integer<T: FixedWidthInteger>(_ type: T.Type, from value: JSONValue) throws -> T {
    switch value {
    case .integer(let integer):
      guard let result = T(exactly: integer) else { throw numberOutOfRange(type, value) }
      return result
    case .number(let number) where number.isFinite && number.rounded(.towardZero) == number:
      guard let result = T(exactly: number) else { throw numberOutOfRange(type, value) }
      return result
    default: throw typeMismatch(type, value)
    }
  }

  func floating<T: BinaryFloatingPoint>(_ type: T.Type, from value: JSONValue) throws -> T {
    let number = try number(from: value)
    guard number >= -Double(T.greatestFiniteMagnitude),
      number <= Double(T.greatestFiniteMagnitude)
    else {
      throw numberOutOfRange(type, value)
    }
    return T(number)
  }

  func typeMismatch(
    _ type: Any.Type,
    _ value: JSONValue,
    _ detail: String? = nil
  ) -> DecodingError {
    .typeMismatch(
      type,
      .init(
        codingPath: codingPath,
        debugDescription:
          detail ?? "Expected \(type), but found \(value.kindDescription)."))
  }

  func numberOutOfRange(_ type: Any.Type, _ value: JSONValue) -> DecodingError {
    .dataCorrupted(
      .init(
        codingPath: codingPath,
        debugDescription: "Number \(value) is outside the exact range of \(type)."))
  }
}

private struct JSONValueKeyedContainer<Key: CodingKey>: KeyedDecodingContainerProtocol {
  let decoder: JSONValueDecoderImplementation
  let object: [String: JSONValue]

  var codingPath: [any CodingKey] { decoder.codingPath }
  var allKeys: [Key] { object.keys.compactMap(Key.init(stringValue:)) }

  func contains(_ key: Key) -> Bool { object[key.stringValue] != nil }

  func decodeNil(forKey key: Key) throws -> Bool {
    guard let value = object[key.stringValue] else { throw missing(key) }
    return value == .null
  }

  func decode(_ type: Bool.Type, forKey key: Key) throws -> Bool {
    try child(for: key).bool(from: required(key))
  }
  func decode(_ type: String.Type, forKey key: Key) throws -> String {
    try child(for: key).string(from: required(key))
  }
  func decode(_ type: Double.Type, forKey key: Key) throws -> Double {
    try child(for: key).number(from: required(key))
  }
  func decode(_ type: Float.Type, forKey key: Key) throws -> Float {
    try child(for: key).floating(type, from: required(key))
  }
  func decode(_ type: Int.Type, forKey key: Key) throws -> Int {
    try child(for: key).integer(type, from: required(key))
  }
  func decode(_ type: Int8.Type, forKey key: Key) throws -> Int8 {
    try child(for: key).integer(type, from: required(key))
  }
  func decode(_ type: Int16.Type, forKey key: Key) throws -> Int16 {
    try child(for: key).integer(type, from: required(key))
  }
  func decode(_ type: Int32.Type, forKey key: Key) throws -> Int32 {
    try child(for: key).integer(type, from: required(key))
  }
  func decode(_ type: Int64.Type, forKey key: Key) throws -> Int64 {
    try child(for: key).integer(type, from: required(key))
  }
  func decode(_ type: UInt.Type, forKey key: Key) throws -> UInt {
    try child(for: key).integer(type, from: required(key))
  }
  func decode(_ type: UInt8.Type, forKey key: Key) throws -> UInt8 {
    try child(for: key).integer(type, from: required(key))
  }
  func decode(_ type: UInt16.Type, forKey key: Key) throws -> UInt16 {
    try child(for: key).integer(type, from: required(key))
  }
  func decode(_ type: UInt32.Type, forKey key: Key) throws -> UInt32 {
    try child(for: key).integer(type, from: required(key))
  }
  func decode(_ type: UInt64.Type, forKey key: Key) throws -> UInt64 {
    try child(for: key).integer(type, from: required(key))
  }
  func decode<T: Decodable>(_ type: T.Type, forKey key: Key) throws -> T {
    let value = try required(key)
    return try child(for: key).unbox(type, from: value)
  }

  func nestedContainer<NestedKey: CodingKey>(
    keyedBy type: NestedKey.Type,
    forKey key: Key
  ) throws -> KeyedDecodingContainer<NestedKey> {
    try child(for: key).container(keyedBy: type)
  }

  func nestedUnkeyedContainer(forKey key: Key) throws -> any UnkeyedDecodingContainer {
    try child(for: key).unkeyedContainer()
  }

  func superDecoder() throws -> any Decoder {
    let key = JSONValueCodingKey(stringValue: "super")
    return decoder.child(object["super"] ?? .object([:]), key: key)
  }

  func superDecoder(forKey key: Key) throws -> any Decoder {
    decoder.child(try required(key), key: key)
  }

  private func required(_ key: Key) throws -> JSONValue {
    guard let value = object[key.stringValue] else { throw missing(key) }
    return value
  }

  private func child(for key: Key) throws -> JSONValueDecoderImplementation {
    decoder.child(try required(key), key: key)
  }

  private func missing(_ key: Key) -> DecodingError {
    .keyNotFound(
      key,
      .init(
        codingPath: codingPath,
        debugDescription: "No value is associated with key \"\(key.stringValue)\"."))
  }
}

private struct JSONValueUnkeyedContainer: UnkeyedDecodingContainer {
  let decoder: JSONValueDecoderImplementation
  let array: [JSONValue]
  var currentIndex = 0

  var codingPath: [any CodingKey] { decoder.codingPath }
  var count: Int? { array.count }
  var isAtEnd: Bool { currentIndex >= array.count }

  mutating func decodeNil() throws -> Bool {
    let value = try current()
    if value == .null {
      currentIndex += 1
      return true
    }
    return false
  }

  mutating func decode(_ type: Bool.Type) throws -> Bool { try scalar { try $0.bool(from: $1) } }
  mutating func decode(_ type: String.Type) throws -> String {
    try scalar { try $0.string(from: $1) }
  }
  mutating func decode(_ type: Double.Type) throws -> Double {
    try scalar { try $0.number(from: $1) }
  }
  mutating func decode(_ type: Float.Type) throws -> Float {
    try scalar { try $0.floating(type, from: $1) }
  }
  mutating func decode(_ type: Int.Type) throws -> Int {
    try scalar { try $0.integer(type, from: $1) }
  }
  mutating func decode(_ type: Int8.Type) throws -> Int8 {
    try scalar { try $0.integer(type, from: $1) }
  }
  mutating func decode(_ type: Int16.Type) throws -> Int16 {
    try scalar { try $0.integer(type, from: $1) }
  }
  mutating func decode(_ type: Int32.Type) throws -> Int32 {
    try scalar { try $0.integer(type, from: $1) }
  }
  mutating func decode(_ type: Int64.Type) throws -> Int64 {
    try scalar { try $0.integer(type, from: $1) }
  }
  mutating func decode(_ type: UInt.Type) throws -> UInt {
    try scalar { try $0.integer(type, from: $1) }
  }
  mutating func decode(_ type: UInt8.Type) throws -> UInt8 {
    try scalar { try $0.integer(type, from: $1) }
  }
  mutating func decode(_ type: UInt16.Type) throws -> UInt16 {
    try scalar { try $0.integer(type, from: $1) }
  }
  mutating func decode(_ type: UInt32.Type) throws -> UInt32 {
    try scalar { try $0.integer(type, from: $1) }
  }
  mutating func decode(_ type: UInt64.Type) throws -> UInt64 {
    try scalar { try $0.integer(type, from: $1) }
  }
  mutating func decode<T: Decodable>(_ type: T.Type) throws -> T {
    try scalar { try $0.unbox(type, from: $1) }
  }

  mutating func nestedContainer<NestedKey: CodingKey>(
    keyedBy type: NestedKey.Type
  ) throws -> KeyedDecodingContainer<NestedKey> {
    let child = try consumeChild()
    return try child.container(keyedBy: type)
  }

  mutating func nestedUnkeyedContainer() throws -> any UnkeyedDecodingContainer {
    try consumeChild().unkeyedContainer()
  }

  mutating func superDecoder() throws -> any Decoder { try consumeChild() }

  private mutating func scalar<T>(
    _ body: (JSONValueDecoderImplementation, JSONValue) throws -> T
  ) throws -> T {
    let value = try current()
    let child = decoder.child(value, key: JSONValueCodingKey(index: currentIndex))
    let result = try body(child, value)
    currentIndex += 1
    return result
  }

  private mutating func consumeChild() throws -> JSONValueDecoderImplementation {
    let value = try current()
    let child = decoder.child(value, key: JSONValueCodingKey(index: currentIndex))
    currentIndex += 1
    return child
  }

  private func current() throws -> JSONValue {
    guard !isAtEnd else {
      throw DecodingError.valueNotFound(
        JSONValue.self,
        .init(codingPath: codingPath, debugDescription: "Unkeyed container is at end."))
    }
    return array[currentIndex]
  }
}

private struct JSONValueSingleContainer: SingleValueDecodingContainer {
  let decoder: JSONValueDecoderImplementation
  let value: JSONValue
  var codingPath: [any CodingKey] { decoder.codingPath }

  func decodeNil() -> Bool { value == .null }
  func decode(_ type: Bool.Type) throws -> Bool { try decoder.bool(from: value) }
  func decode(_ type: String.Type) throws -> String { try decoder.string(from: value) }
  func decode(_ type: Double.Type) throws -> Double { try decoder.number(from: value) }
  func decode(_ type: Float.Type) throws -> Float { try decoder.floating(type, from: value) }
  func decode(_ type: Int.Type) throws -> Int { try decoder.integer(type, from: value) }
  func decode(_ type: Int8.Type) throws -> Int8 { try decoder.integer(type, from: value) }
  func decode(_ type: Int16.Type) throws -> Int16 { try decoder.integer(type, from: value) }
  func decode(_ type: Int32.Type) throws -> Int32 { try decoder.integer(type, from: value) }
  func decode(_ type: Int64.Type) throws -> Int64 { try decoder.integer(type, from: value) }
  func decode(_ type: UInt.Type) throws -> UInt { try decoder.integer(type, from: value) }
  func decode(_ type: UInt8.Type) throws -> UInt8 { try decoder.integer(type, from: value) }
  func decode(_ type: UInt16.Type) throws -> UInt16 { try decoder.integer(type, from: value) }
  func decode(_ type: UInt32.Type) throws -> UInt32 { try decoder.integer(type, from: value) }
  func decode(_ type: UInt64.Type) throws -> UInt64 { try decoder.integer(type, from: value) }
  func decode<T: Decodable>(_ type: T.Type) throws -> T { try decoder.unbox(type, from: value) }
}

private struct JSONValueCodingKey: CodingKey {
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

  init(index: Int) { self.init(intValue: index) }
}

extension JSONValue {
  fileprivate var kindDescription: String {
    switch self {
    case .null: return "null"
    case .bool: return "a boolean"
    case .integer: return "an integer"
    case .number: return "a number"
    case .string: return "a string"
    case .array: return "an array"
    case .object: return "an object"
    }
  }
}
