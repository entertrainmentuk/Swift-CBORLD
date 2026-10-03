import Foundation

indirect enum CBORValue: Sendable {
  case unsigned(UInt64)
  case negative(Int64)
  case bytes(Data)
  case string(String)
  case array([CBORValue])
  case map([CBORMapEntry])
  case tagged(UInt64, CBORValue)
  case simple(UInt8)
  case bool(Bool)
  case null
  case double(Double)
}

struct CBORMapEntry: Sendable {
  var key: CBORValue
  var value: CBORValue
}

/// Single-owner growable byte storage for the CBOR output paths. It avoids
/// `Data.append`'s repeated uniqueness checks, transfers its allocation to the
/// returned `Data` without copying, and never allocates beyond `limit`: growth
/// uses checked arithmetic and fails before crossing the cap.
final class CBORByteWriter {
  private var storage: UnsafeMutablePointer<UInt8>
  private(set) var count = 0
  private var capacity: Int
  /// The limit applies to every byte written, including drained bytes.
  let limit: Int
  /// Bytes already handed out by ``drain()``.
  private(set) var drainedCount = 0
  private var ownsStorage = true

  init(capacity: Int = 128, limit: Int = .max) {
    self.limit = Swift.max(0, limit)
    self.capacity = Swift.max(0, Swift.min(capacity, self.limit))
    self.storage = .allocate(capacity: self.capacity)
  }

  deinit {
    if ownsStorage { storage.deallocate() }
  }

  /// Bytes that may still be written before `limit` is reached.
  var remaining: Int { limit - drainedCount - count }

  /// The current allocation size, which never exceeds `limit`.
  var allocatedCapacity: Int { capacity }

  @inline(__always)
  func append(_ byte: UInt8) throws {
    if count == capacity { try reserve(1) }
    storage[count] = byte
    count += 1
  }

  func append(bigEndian value: UInt16) throws {
    try reserve(2)
    storage[count] = UInt8(truncatingIfNeeded: value >> 8)
    storage[count + 1] = UInt8(truncatingIfNeeded: value)
    count += 2
  }

  func append(bigEndian value: UInt32) throws {
    try reserve(4)
    for offset in 0..<4 {
      storage[count + offset] = UInt8(truncatingIfNeeded: value >> UInt32(24 - offset * 8))
    }
    count += 4
  }

  func append(bigEndian value: UInt64) throws {
    try reserve(8)
    for offset in 0..<8 {
      storage[count + offset] = UInt8(truncatingIfNeeded: value >> UInt64(56 - offset * 8))
    }
    count += 8
  }

  func append(utf8 value: String) throws {
    let byteCount = value.utf8.count
    guard byteCount > 0 else { return }
    try reserve(byteCount)
    let copied: Void? = value.utf8.withContiguousStorageIfAvailable { buffer in
      (storage + count).initialize(from: buffer.baseAddress!, count: byteCount)
    }
    if copied == nil {
      var offset = count
      for byte in value.utf8 {
        storage[offset] = byte
        offset += 1
      }
    }
    count += byteCount
  }

  func append(_ data: Data) throws {
    let byteCount = data.count
    guard byteCount > 0 else { return }
    try reserve(byteCount)
    data.withUnsafeBytes { buffer in
      (storage + count).initialize(
        from: buffer.bindMemory(to: UInt8.self).baseAddress!, count: byteCount)
    }
    count += byteCount
  }

  /// Ensures that `additional` more bytes fit, growing geometrically but never
  /// past `limit`.
  func reserve(_ additional: Int) throws {
    let (required, overflow) = count.addingReportingOverflow(additional)
    let (total, totalOverflow) = required.addingReportingOverflow(drainedCount)
    guard !overflow, !totalOverflow, total <= limit else {
      throw CBORLDError.resourceLimit(
        "CBOR-LD output would exceed the configured maximumOutputBytes of \(limit) bytes.")
    }
    guard required > capacity else { return }
    var newCapacity = Swift.max(capacity, 64)
    while newCapacity < required {
      let (doubled, didOverflow) = newCapacity.multipliedReportingOverflow(by: 2)
      newCapacity = didOverflow ? .max : doubled
    }
    newCapacity = Swift.min(newCapacity, limit - drainedCount)
    let replacement = UnsafeMutablePointer<UInt8>.allocate(capacity: newCapacity)
    replacement.initialize(from: storage, count: count)
    storage.deallocate()
    storage = replacement
    capacity = newCapacity
  }

  /// Transfers the written bytes to `Data` without copying. The writer must
  /// not be used afterwards.
  func finish() -> Data {
    ownsStorage = false
    return Data(
      bytesNoCopy: UnsafeMutableRawPointer(storage),
      count: count,
      deallocator: .custom { pointer, _ in pointer.deallocate() })
  }

  /// Accounts for bytes emitted outside the buffer, such as a long string
  /// streamed directly to a sink, against the same limit.
  func reserveExternal(_ byteCount: Int) throws {
    let (total, overflow) = drainedCount.addingReportingOverflow(count)
    let (withExternal, externalOverflow) = total.addingReportingOverflow(byteCount)
    guard !overflow, !externalOverflow, withExternal <= limit else {
      throw CBORLDError.resourceLimit(
        "CBOR-LD output would exceed the configured maximumOutputBytes of \(limit) bytes.")
    }
    drainedCount += byteCount
  }

  /// Copies out the written bytes and empties the writer while keeping its
  /// allocation, for incremental emission.
  func drain() -> Data {
    let chunk = Data(bytes: storage, count: count)
    drainedCount += count
    count = 0
    return chunk
  }
}

extension CBORValue {
  var unsignedValue: UInt64? {
    guard case .unsigned(let value) = self else { return nil }
    return value
  }

  var integerValue: Int64? {
    switch self {
    case .unsigned(let value) where value <= UInt64(Int64.max):
      return Int64(value)
    case .negative(let value):
      return value
    default:
      return nil
    }
  }

  var arrayValue: [CBORValue]? {
    guard case .array(let value) = self else { return nil }
    return value
  }

  var mapValue: [CBORMapEntry]? {
    guard case .map(let value) = self else { return nil }
    return value
  }

  var stringValue: String? {
    guard case .string(let value) = self else { return nil }
    return value
  }

  var bytesValue: Data? {
    guard case .bytes(let value) = self else { return nil }
    return value
  }

  /// Converts a JSON value without semantic compression. Depth is counted
  /// like the CBOR decoder counts it, from `depth` for `value` itself.
  static func fromJSON(
    _ value: JSONValue,
    depth: Int = 0,
    limits: CBORLDEncodingLimits = .unbounded
  ) throws -> CBORValue {
    guard depth <= limits.maximumNestingDepth else {
      throw CBOREncoder.nestingLimit(limits)
    }
    switch value {
    case .null: return .null
    case .bool(let value): return .bool(value)
    case .integer(let value):
      if value >= 0 { return .unsigned(UInt64(value)) }
      return .negative(value)
    case .number(let value):
      guard value.isFinite else {
        throw CBORLDError.invalidInput("JSON numbers must be finite.")
      }
      if value.rounded(.towardZero) == value {
        if value >= 0, value <= Double(CBORLDConstants.maximumSafeInteger) {
          return .unsigned(UInt64(value))
        }
        if value >= -Double(CBORLDConstants.maximumSafeInteger), value < 0 {
          return .negative(Int64(value))
        }
      }
      return .double(value)
    case .string(let value): return .string(value)
    case .array(let values):
      try CBOREncoder.checkContainer(values.count, limits: limits)
      var output: [CBORValue] = []
      output.reserveCapacity(values.count)
      for (index, element) in values.enumerated() {
        try CBOREncoder.checkCancellation(at: index, limits: limits)
        output.append(try fromJSON(element, depth: depth + 1, limits: limits))
      }
      return .array(output)
    case .object(let values):
      try CBOREncoder.checkContainer(values.count, limits: limits)
      var entries: [CBORMapEntry] = []
      entries.reserveCapacity(values.count)
      for (index, key) in values.keys.sorted().enumerated() {
        try CBOREncoder.checkCancellation(at: index, limits: limits)
        guard let element = values[key] else {
          throw CBORLDError.invalidInput("JSON object changed while it was being encoded.")
        }
        entries.append(
          CBORMapEntry(
            key: .string(key),
            value: try fromJSON(element, depth: depth + 1, limits: limits)))
      }
      return .map(entries)
    }
  }

  func toJSON() throws -> JSONValue {
    switch self {
    case .unsigned(let value):
      guard value <= UInt64(Int64.max) else {
        throw CBORLDError.invalidInput(
          "CBOR integer \(value) cannot be represented by JSONValue.")
      }
      return .integer(Int64(value))
    case .negative(let value): return .integer(value)
    case .string(let value): return .string(value)
    case .array(let values): return .array(try values.map { try $0.toJSON() })
    case .map(let entries):
      var object: [String: JSONValue] = [:]
      for entry in entries {
        guard case .string(let key) = entry.key else {
          throw CBORLDError.invalidInput(
            "A JSON object cannot contain a non-string CBOR map key.")
        }
        guard object[key] == nil else {
          throw CBORLDError.invalidInput(
            "A JSON object cannot contain duplicate key \"\(key)\".")
        }
        object[key] = try entry.value.toJSON()
      }
      return .object(object)
    case .bool(let value): return .bool(value)
    case .null: return .null
    case .double(let value):
      guard value.isFinite else {
        throw CBORLDError.invalidInput(
          "CBOR floating-point values must be finite to represent JSON.")
      }
      return .number(value)
    case .bytes:
      throw CBORLDError.invalidInput(
        "A CBOR byte string is not a native JSON value.")
    case .tagged:
      throw CBORLDError.invalidInput(
        "A nested CBOR tag is not a native JSON value.")
    case .simple(let value):
      throw CBORLDError.invalidInput(
        "CBOR simple value \(value) is not a native JSON value.")
    }
  }
}

enum CBOREncoder {
  /// The CBOR-LD 1.0 registry-entry-zero prefix: tag 51997, a two-element
  /// array, and registry entry `0`.
  static let uncompressedCBORLD1Prefix: [UInt8] = [0xd9, 0xcb, 0x1d, 0x82, 0x00]

  static func encode(
    _ value: CBORValue,
    mode: CBORLDSerializationMode = .compatibility,
    limits: CBORLDEncodingLimits = .unbounded
  ) throws -> Data {
    let writer = CBORByteWriter(limit: limits.maximumOutputBytes)
    try append(value, depth: 0, mode: mode, limits: limits, to: writer)
    return writer.finish()
  }

  /// Encodes the hot uncompressed CBOR-LD 1.0 path without first allocating a
  /// second recursive `CBORValue` tree. The emitted bytes are identical to the
  /// general encoder and retain all finite-number validation.
  static func encodeUncompressedCBORLD1(
    _ value: JSONValue,
    mode: CBORLDSerializationMode,
    limits: CBORLDEncodingLimits = .unbounded
  ) throws -> Data {
    let writer = CBORByteWriter(limit: limits.maximumOutputBytes)
    for byte in uncompressedCBORLD1Prefix { try writer.append(byte) }
    // The payload sits at depth 2: tag (0), envelope array (1), payload (2).
    try appendJSON(value, depth: 2, mode: mode, limits: limits, to: writer)
    return writer.finish()
  }

  /// Appends one JSON value as preferred-width, definite-length CBOR.
  static func appendJSON(
    _ value: JSONValue,
    depth: Int,
    mode: CBORLDSerializationMode,
    limits: CBORLDEncodingLimits,
    to writer: CBORByteWriter
  ) throws {
    guard depth <= limits.maximumNestingDepth else { throw nestingLimit(limits) }
    switch value {
    case .null:
      try writer.append(0xf6)
    case .bool(let value):
      try writer.append(value ? 0xf5 : 0xf4)
    case .integer(let value):
      if value >= 0 {
        try appendHeader(major: 0, argument: UInt64(value), to: writer)
      } else {
        try appendHeader(major: 1, argument: UInt64(bitPattern: ~value), to: writer)
      }
    case .number(let value):
      guard value.isFinite else {
        throw CBORLDError.invalidInput("JSON numbers must be finite.")
      }
      if value.rounded(.towardZero) == value {
        if value >= 0, value <= Double(CBORLDConstants.maximumSafeInteger) {
          try appendHeader(major: 0, argument: UInt64(value), to: writer)
          return
        }
        if value >= -Double(CBORLDConstants.maximumSafeInteger), value < 0 {
          let integer = Int64(value)
          try appendHeader(major: 1, argument: UInt64(bitPattern: ~integer), to: writer)
          return
        }
      }
      try appendPreferredDouble(value, to: writer)
    case .string(let value):
      try appendString(value, to: writer)
    case .array(let values):
      try checkContainer(values.count, limits: limits)
      try appendHeader(major: 4, argument: UInt64(values.count), to: writer)
      for (index, value) in values.enumerated() {
        try checkCancellation(at: index, limits: limits)
        try appendJSON(value, depth: depth + 1, mode: mode, limits: limits, to: writer)
      }
    case .object(let values):
      try checkContainer(values.count, limits: limits)
      try appendHeader(major: 5, argument: UInt64(values.count), to: writer)
      for (index, key) in sortedKeys(values, mode: mode).enumerated() {
        try checkCancellation(at: index, limits: limits)
        try appendString(key, to: writer)
        guard let value = values[key] else {
          throw CBORLDError.invalidInput("JSON object changed while it was being encoded.")
        }
        try appendJSON(value, depth: depth + 1, mode: mode, limits: limits, to: writer)
      }
    }
  }

  /// Object keys in the order every serialization mode emits them.
  ///
  /// JSON keys are text strings, whose encoded head grows with their length.
  /// Ordering encoded keys bytewise (RFC 8949 section 4.2.1) therefore sorts
  /// by length and then by UTF-8 bytes, exactly as length-first ordering
  /// (section 4.2.3) does, so the two profiles agree for JSON objects. They
  /// differ only for maps with keys of several major types.
  static func sortedKeys(
    _ values: [String: JSONValue],
    mode: CBORLDSerializationMode
  ) -> [String] {
    var keys = Array(values.keys)
    keys.sort { lhs, rhs in
      let lhsCount = lhs.utf8.count
      let rhsCount = rhs.utf8.count
      if lhsCount != rhsCount { return lhsCount < rhsCount }
      return lhs.utf8.lexicographicallyPrecedes(rhs.utf8)
    }
    return keys
  }

  static func appendHeader(
    major: UInt8,
    argument: UInt64,
    to writer: CBORByteWriter
  ) throws {
    let prefix = major << 5
    switch argument {
    case 0...23:
      try writer.append(prefix | UInt8(argument))
    case 24...UInt64(UInt8.max):
      try writer.reserve(2)
      try writer.append(prefix | 24)
      try writer.append(UInt8(argument))
    case 256...UInt64(UInt16.max):
      try writer.reserve(3)
      try writer.append(prefix | 25)
      try writer.append(bigEndian: UInt16(argument))
    case 65_536...UInt64(UInt32.max):
      try writer.reserve(5)
      try writer.append(prefix | 26)
      try writer.append(bigEndian: UInt32(argument))
    default:
      try writer.reserve(9)
      try writer.append(prefix | 27)
      try writer.append(bigEndian: argument)
    }
  }

  static func appendPreferredDouble(_ value: Double, to writer: CBORByteWriter) throws {
    if value.isNaN {
      try writer.append(0xf9)
      try writer.append(bigEndian: UInt16(0x7e00))
      return
    }
    let half = Float16(value)
    if Double(half).bitPattern == value.bitPattern {
      try writer.append(0xf9)
      try writer.append(bigEndian: half.bitPattern)
      return
    }
    let single = Float(value)
    if Double(single).bitPattern == value.bitPattern {
      try writer.append(0xfa)
      try writer.append(bigEndian: single.bitPattern)
      return
    }
    try writer.append(0xfb)
    try writer.append(bigEndian: value.bitPattern)
  }

  static func appendString(_ value: String, to writer: CBORByteWriter) throws {
    try appendHeader(major: 3, argument: UInt64(value.utf8.count), to: writer)
    try writer.append(utf8: value)
  }

  private static func append(
    _ value: CBORValue,
    depth: Int,
    mode: CBORLDSerializationMode,
    limits: CBORLDEncodingLimits,
    to writer: CBORByteWriter
  ) throws {
    guard depth <= limits.maximumNestingDepth else { throw nestingLimit(limits) }
    switch value {
    case .unsigned(let value):
      try appendHeader(major: 0, argument: value, to: writer)
    case .negative(let value):
      guard value < 0 else {
        throw CBORLDError.invalidInput("A negative CBOR integer must be below zero.")
      }
      try appendHeader(major: 1, argument: UInt64(bitPattern: ~value), to: writer)
    case .bytes(let value):
      try appendHeader(major: 2, argument: UInt64(value.count), to: writer)
      try writer.append(value)
    case .string(let value):
      try appendString(value, to: writer)
    case .array(let values):
      try checkContainer(values.count, limits: limits)
      try appendHeader(major: 4, argument: UInt64(values.count), to: writer)
      for (index, value) in values.enumerated() {
        try checkCancellation(at: index, limits: limits)
        try append(value, depth: depth + 1, mode: mode, limits: limits, to: writer)
      }
    case .map(let entries):
      try checkContainer(entries.count, limits: limits)
      try appendHeader(major: 5, argument: UInt64(entries.count), to: writer)
      try appendSortedEntries(entries, depth: depth, mode: mode, limits: limits, to: writer)
    case .tagged(let tag, let value):
      try appendHeader(major: 6, argument: tag, to: writer)
      try append(value, depth: depth + 1, mode: mode, limits: limits, to: writer)
    case .simple(let value):
      if value < 24 {
        try writer.append(0xe0 | value)
      } else {
        try writer.append(0xf8)
        try writer.append(value)
      }
    case .bool(let value):
      try writer.append(value ? 0xf5 : 0xf4)
    case .null:
      try writer.append(0xf6)
    case .double(let value):
      try appendPreferredDouble(value, to: writer)
    }
  }

  /// Every supported mode orders map keys by their encoded bytes. Only the
  /// keys are encoded ahead of time; values stream straight into the output,
  /// so a map never holds a second copy of its values.
  private static func appendSortedEntries(
    _ entries: [CBORMapEntry],
    depth: Int,
    mode: CBORLDSerializationMode,
    limits: CBORLDEncodingLimits,
    to writer: CBORByteWriter
  ) throws {
    var keys: [Data] = []
    keys.reserveCapacity(entries.count)
    var pendingKeyBytes = 0
    for (index, entry) in entries.enumerated() {
      try checkCancellation(at: index, limits: limits)
      // Keys will be written to the output, so together they must fit the
      // bytes that remain before the output limit.
      let keyWriter = CBORByteWriter(capacity: 16, limit: writer.remaining - pendingKeyBytes)
      try append(entry.key, depth: depth + 1, mode: mode, limits: limits, to: keyWriter)
      pendingKeyBytes += keyWriter.count
      keys.append(keyWriter.finish())
    }
    var order = Array(entries.indices)
    let lengthFirst = mode.usesLengthFirstMapOrdering
    order.sort { lhs, rhs in
      let left = keys[lhs]
      let right = keys[rhs]
      if lengthFirst, left.count != right.count { return left.count < right.count }
      if left == right { return lhs < rhs }
      return left.lexicographicallyPrecedes(right)
    }
    for (position, index) in order.enumerated() {
      try checkCancellation(at: position, limits: limits)
      try writer.append(keys[index])
      try append(entries[index].value, depth: depth + 1, mode: mode, limits: limits, to: writer)
    }
  }

  static func encodedStringByteCount(_ value: String) -> Int {
    let count = value.utf8.count
    return headerByteCount(UInt64(count)) + count
  }

  /// The size of a preferred-width CBOR head carrying `argument`.
  static func headerByteCount(_ argument: UInt64) -> Int {
    switch argument {
    case 0...23: return 1
    case 24...UInt64(UInt8.max): return 2
    case 256...UInt64(UInt16.max): return 3
    case 65_536...UInt64(UInt32.max): return 5
    default: return 9
    }
  }

  static func checkContainer(_ count: Int, limits: CBORLDEncodingLimits) throws {
    guard count <= limits.maximumContainerItems else {
      throw CBORLDError.resourceLimit(
        "CBOR container contains more than \(limits.maximumContainerItems) items.")
    }
  }

  static func checkCancellation(at itemIndex: Int, limits: CBORLDEncodingLimits) throws {
    if itemIndex.isMultiple(of: limits.cancellationCheckStride), Task<Never, Never>.isCancelled {
      throw CancellationError()
    }
  }

  static func nestingLimit(_ limits: CBORLDEncodingLimits) -> CBORLDError {
    .resourceLimit(
      "CBOR nesting exceeds the configured depth of \(limits.maximumNestingDepth).")
  }
}

struct CBORDecoder<Bytes: RandomAccessCollection>
where Bytes.Element == UInt8, Bytes.Index == Int {
  private enum ArgumentKind: Equatable {
    case integer
    case length
  }

  private struct ShortObjectKey: Hashable {
    let byteCount: UInt8
    let packedBytes: UInt64
  }

  private let bytes: Bytes
  private let limits: CBORLDDecodingLimits
  private let policy: CBORLDDecodingPolicy
  private var index = 0
  private var usesShortObjectKeyCache: Bool
  private var shortObjectKeys: [ShortObjectKey: String] = [:]
  private var shortObjectKeyLookups = 0
  private var shortObjectKeyHits = 0

  init(
    bytes: Bytes,
    limits: CBORLDDecodingLimits = .init(),
    policy: CBORLDDecodingPolicy = .init()
  ) {
    self.bytes = bytes
    self.limits = limits
    self.policy = policy
    self.usesShortObjectKeyCache = bytes.count >= 4_096
  }

  /// Decodes the payload after the preferred `d9 cb1d 82 00` envelope prefix
  /// directly into `JSONValue`. This avoids an intermediate recursive
  /// `CBORValue` allocation for the dominant uncompressed interchange path.
  mutating func decodePreferredUncompressedCBORLD1() throws -> JSONValue {
    try validateLimits()
    // The caller has already matched the complete preferred envelope prefix.
    index = 5
    if bytes.count == 6, bytes[5] == 0xa0 {
      guard 2 <= limits.maximumNestingDepth else {
        throw resourceLimit(
          "CBOR nesting exceeds the configured depth of \(limits.maximumNestingDepth).")
      }
      return [:]
    }
    let value = try decodeJSONValue(depth: 2)
    guard index == bytes.count else {
      throw malformed("Unexpected trailing bytes after the CBOR value.")
    }
    return value
  }

  mutating func decodeComplete() throws -> CBORValue {
    try validateLimits()
    let value = try decodeValue(depth: 0)
    guard index == bytes.count else {
      throw CBORLDError(
        code: .notCBORLD,
        message: "Unexpected trailing bytes after the CBOR value.")
    }
    if let mode = policy.requiredSerializationMode {
      let expected = try CBOREncoder.encode(value, mode: mode)
      let original = Data(bytes)
      guard expected == original else {
        let offset = firstMismatch(expected, original)
        throw policyViolation(
          .nonPreferredCBOR,
          "CBOR input does not match the required \(mode.rawValue) serialization.",
          offset: offset,
          violation: "required-serialization-mode")
      }
    }
    return value
  }

  private func validateLimits() throws {
    guard limits.maximumInputBytes >= 0,
      limits.maximumNestingDepth >= 0,
      limits.maximumContainerItems >= 0,
      limits.maximumDiagnosticNodes >= 0,
      limits.cancellationCheckStride > 0
    else {
      throw resourceLimit("CBOR-LD decoding limits must not be negative.")
    }
    guard bytes.count <= limits.maximumInputBytes else {
      throw resourceLimit(
        "CBOR-LD input contains \(bytes.count) bytes; the configured limit is \(limits.maximumInputBytes)."
      )
    }
  }

  private mutating func decodeJSONValue(depth: Int) throws -> JSONValue {
    guard depth <= limits.maximumNestingDepth else {
      throw resourceLimit(
        "CBOR nesting exceeds the configured depth of \(limits.maximumNestingDepth).")
    }
    let initial = try readByte()
    let major = initial >> 5
    let info = initial & 0x1f
    switch major {
    case 0:
      let value = try readUncheckedArgument(info)
      guard value <= UInt64(Int64.max) else {
        throw CBORLDError.invalidInput(
          "CBOR integer \(value) cannot be represented by JSONValue.")
      }
      return .integer(Int64(value))
    case 1:
      let argument = try readUncheckedArgument(info)
      guard argument <= UInt64(Int64.max) else {
        throw malformed("Negative integer is outside the supported Int64 range.")
      }
      return .integer(-1 - Int64(argument))
    case 2:
      throw CBORLDError.invalidInput("A CBOR byte string is not a native JSON value.")
    case 3:
      if info == 31 {
        try requireIndefiniteLengthsAllowed()
        return .string(try readIndefiniteString())
      }
      return .string(
        try readUTF8String(count: try checkedCount(readUncheckedArgument(info))))
    case 4:
      return .array(try readJSONArray(info: info, depth: depth))
    case 5:
      return .object(try readJSONObject(info: info, depth: depth))
    case 6:
      throw CBORLDError.invalidInput("A nested CBOR tag is not a native JSON value.")
    case 7:
      return try decodeJSONSimple(info)
    default:
      throw malformed("Unknown CBOR major type \(major).")
    }
  }

  private mutating func decodeJSONSimple(_ info: UInt8) throws -> JSONValue {
    switch info {
    case 20: return .bool(false)
    case 21: return .bool(true)
    case 22: return .null
    case 25:
      return try finiteJSONNumber(Double(Float16(bitPattern: readInteger())))
    case 26:
      return try finiteJSONNumber(Double(Float(bitPattern: readInteger())))
    case 27:
      return try finiteJSONNumber(Double(bitPattern: readInteger()))
    default:
      throw malformed("Unsupported CBOR simple value \(info).")
    }
  }

  private func finiteJSONNumber(_ value: Double) throws -> JSONValue {
    guard value.isFinite else {
      throw CBORLDError.invalidInput(
        "CBOR floating-point values must be finite to represent JSON.")
    }
    return .number(value)
  }

  private mutating func readJSONArray(info: UInt8, depth: Int) throws -> [JSONValue] {
    var result: [JSONValue] = []
    if info == 31 {
      try requireIndefiniteLengthsAllowed()
      while try !isAtBreak() {
        try checkContainerCount(result.count + 1)
        try checkCancellation(at: result.count)
        result.append(try decodeJSONValue(depth: depth + 1))
      }
      index += 1
      return result
    }
    let count = try checkedCount(readUncheckedArgument(info))
    try checkContainerCount(count)
    guard count <= bytes.count - index else {
      throw malformed("CBOR array length exceeds the remaining input.")
    }
    result.reserveCapacity(count)
    for itemIndex in 0..<count {
      try checkCancellation(at: itemIndex)
      result.append(try decodeJSONValue(depth: depth + 1))
    }
    return result
  }

  private mutating func readJSONObject(
    info: UInt8,
    depth: Int
  ) throws -> [String: JSONValue] {
    var result: [String: JSONValue] = [:]
    let count: Int?
    if info == 31 {
      try requireIndefiniteLengthsAllowed()
      count = nil
    } else {
      let definiteCount = try checkedCount(readUncheckedArgument(info))
      try checkContainerCount(definiteCount)
      guard definiteCount <= (bytes.count - index) / 2 else {
        throw malformed("CBOR map length exceeds the remaining input.")
      }
      result.reserveCapacity(definiteCount)
      count = definiteCount
    }
    var consumed = 0
    while true {
      if let count {
        if consumed >= count { break }
      } else if try isAtBreak() {
        break
      }
      if count == nil { try checkContainerCount(consumed + 1) }
      try checkCancellation(at: consumed)
      let key = try readJSONObjectKey(depth: depth + 1)
      let value = try decodeJSONValue(depth: depth + 1)
      guard result.updateValue(value, forKey: key) == nil else {
        throw CBORLDError.invalidInput(
          "A JSON object cannot contain duplicate key \"\(key)\".")
      }
      consumed += 1
    }
    if count == nil { index += 1 }
    return result
  }

  private mutating func readJSONObjectKey(depth: Int) throws -> String {
    guard depth <= limits.maximumNestingDepth else {
      throw resourceLimit(
        "CBOR nesting exceeds the configured depth of \(limits.maximumNestingDepth).")
    }
    let initial = try readByte()
    guard initial >> 5 == 3 else {
      throw CBORLDError.invalidInput(
        "A JSON object cannot contain a non-string CBOR map key.")
    }
    let info = initial & 0x1f
    if info == 31 {
      try requireIndefiniteLengthsAllowed()
      return try readIndefiniteString()
    }
    return try readJSONObjectKeyString(
      count: checkedCount(readUncheckedArgument(info)))
  }

  private mutating func decodeValue(depth: Int) throws -> CBORValue {
    guard depth <= limits.maximumNestingDepth else {
      throw resourceLimit(
        "CBOR nesting exceeds the configured depth of \(limits.maximumNestingDepth).")
    }
    let initial = try readByte()
    let major = initial >> 5
    let info = initial & 0x1f

    switch major {
    case 0:
      return .unsigned(try readArgument(info, kind: .integer))
    case 1:
      let argument = try readArgument(info, kind: .integer)
      guard argument <= UInt64(Int64.max) else {
        throw malformed("Negative integer is outside the supported Int64 range.")
      }
      return .negative(-1 - Int64(argument))
    case 2:
      if info == 31 {
        try requireIndefiniteLengthsAllowed()
        return .bytes(try readIndefiniteBytes())
      }
      return .bytes(
        try readData(count: try checkedCount(readArgument(info, kind: .length))))
    case 3:
      if info == 31 {
        try requireIndefiniteLengthsAllowed()
        return .string(try readIndefiniteString())
      }
      return .string(
        try decodeUTF8(
          readData(count: try checkedCount(readArgument(info, kind: .length)))))
    case 4:
      return .array(try readArray(info: info, depth: depth))
    case 5:
      return .map(try readMap(info: info, depth: depth))
    case 6:
      return .tagged(
        try readArgument(info, kind: .integer), try decodeValue(depth: depth + 1))
    case 7:
      return try decodeSimple(info)
    default:
      throw malformed("Unknown CBOR major type \(major).")
    }
  }

  private mutating func decodeSimple(_ info: UInt8) throws -> CBORValue {
    let offset = index - 1
    switch info {
    case 0...19, 23:
      return try decodeReservedSimple(info, offset: offset)
    case 20: return .bool(false)
    case 21: return .bool(true)
    case 22: return .null
    case 25:
      let bits: UInt16 = try readInteger()
      let value = Double(Float16(bitPattern: bits))
      try validatePreferredFloat(value, info: info, bits: UInt64(bits), offset: offset)
      return .double(value)
    case 26:
      let bits: UInt32 = try readInteger()
      let value = Double(Float(bitPattern: bits))
      try validatePreferredFloat(value, info: info, bits: UInt64(bits), offset: offset)
      return .double(value)
    case 27:
      let bits: UInt64 = try readInteger()
      let value = Double(bitPattern: bits)
      try validatePreferredFloat(value, info: info, bits: bits, offset: offset)
      return .double(value)
    case 24:
      return try decodeReservedSimple(try readByte(), offset: offset)
    default:
      throw malformed("Unsupported CBOR simple value \(info).")
    }
  }

  private func decodeReservedSimple(_ value: UInt8, offset: Int) throws -> CBORValue {
    guard policy.allowsReservedSimpleValuesInLosslessMode else {
      throw policyViolation(
        .reservedSimpleValue,
        "CBOR simple value \(value) is not allowed by the decoding policy.",
        offset: offset,
        violation: "reserved-simple-value")
    }
    return .simple(value)
  }

  private func validatePreferredFloat(
    _ value: Double,
    info: UInt8,
    bits: UInt64,
    offset: Int
  ) throws {
    guard policy.rejectNonPreferredFloatingPoint else { return }
    let preferredInfo: UInt8
    if value.isNaN {
      guard info == 25, bits == 0x7e00 else {
        throw policyViolation(
          .nonPreferredFloat,
          "CBOR NaN does not use the preferred half-precision representation.",
          offset: offset,
          violation: "non-preferred-float")
      }
      return
    }
    if Double(Float16(value)).bitPattern == value.bitPattern {
      preferredInfo = 25
    } else if Double(Float(value)).bitPattern == value.bitPattern {
      preferredInfo = 26
    } else {
      preferredInfo = 27
    }
    guard info == preferredInfo else {
      throw policyViolation(
        .nonPreferredFloat,
        "CBOR floating-point value uses a wider representation than required.",
        offset: offset,
        violation: "non-preferred-float")
    }
  }

  private mutating func readArray(info: UInt8, depth: Int) throws -> [CBORValue] {
    var result: [CBORValue] = []
    if info == 31 {
      try requireIndefiniteLengthsAllowed()
      while try !isAtBreak() {
        try checkContainerCount(result.count + 1)
        try checkCancellation(at: result.count)
        result.append(try decodeValue(depth: depth + 1))
      }
      index += 1
      return result
    }
    let count = try checkedCount(readArgument(info, kind: .length))
    try checkContainerCount(count)
    guard count <= bytes.count - index else {
      throw malformed("CBOR array length exceeds the remaining input.")
    }
    result.reserveCapacity(count)
    for itemIndex in 0..<count {
      try checkCancellation(at: itemIndex)
      result.append(try decodeValue(depth: depth + 1))
    }
    return result
  }

  private mutating func readMap(info: UInt8, depth: Int) throws -> [CBORMapEntry] {
    var result: [CBORMapEntry] = []
    var keyIdentities: [Data: Int] = [:]
    if info == 31 {
      try requireIndefiniteLengthsAllowed()
      while try !isAtBreak() {
        try checkContainerCount(result.count + 1)
        try checkCancellation(at: result.count)
        let keyOffset = index
        let key = try decodeValue(depth: depth + 1)
        let value = try decodeValue(depth: depth + 1)
        try appendUniqueMapEntry(
          key: key,
          value: value,
          keyOffset: keyOffset,
          entries: &result,
          keyIdentities: &keyIdentities)
      }
      index += 1
      return result
    }
    let count = try checkedCount(readArgument(info, kind: .length))
    try checkContainerCount(count)
    guard count <= (bytes.count - index) / 2 else {
      throw malformed("CBOR map length exceeds the remaining input.")
    }
    result.reserveCapacity(count)
    for itemIndex in 0..<count {
      try checkCancellation(at: itemIndex)
      let keyOffset = index
      let key = try decodeValue(depth: depth + 1)
      let value = try decodeValue(depth: depth + 1)
      try appendUniqueMapEntry(
        key: key,
        value: value,
        keyOffset: keyOffset,
        entries: &result,
        keyIdentities: &keyIdentities)
    }
    return result
  }

  private func appendUniqueMapEntry(
    key: CBORValue,
    value: CBORValue,
    keyOffset: Int,
    entries: inout [CBORMapEntry],
    keyIdentities: inout [Data: Int]
  ) throws {
    guard limits.rejectDuplicateMapKeys else {
      entries.append(CBORMapEntry(key: key, value: value))
      return
    }
    // Preferred re-encoding gives non-preferred integer and string encodings
    // the same identity and therefore catches their duplicate data-model key.
    let identity = try CBOREncoder.encode(key, mode: .lengthFirstDeterministic)
    guard let firstOffset = keyIdentities[identity] else {
      keyIdentities[identity] = keyOffset
      entries.append(CBORMapEntry(key: key, value: value))
      return
    }
    throw policyViolation(
      .notCBORLD,
      "CBOR map contains a duplicate key.",
      offset: keyOffset,
      violation: "duplicate-map-key",
      relatedOffset: firstOffset)
  }

  private func requireIndefiniteLengthsAllowed() throws {
    guard limits.allowsIndefiniteLengthItems else {
      throw malformed("Indefinite-length CBOR items are disabled by the decoding policy.")
    }
  }

  private mutating func readIndefiniteBytes() throws -> Data {
    var result = Data()
    while try !isAtBreak() {
      let initial = try readByte()
      guard initial >> 5 == 2, initial & 0x1f != 31 else {
        throw malformed("Invalid chunk in indefinite-length byte string.")
      }
      result.append(
        try readData(
          count: try checkedCount(readArgument(initial & 0x1f, kind: .length))))
    }
    index += 1
    return result
  }

  private mutating func readIndefiniteString() throws -> String {
    var result = ""
    while try !isAtBreak() {
      let initial = try readByte()
      guard initial >> 5 == 3, initial & 0x1f != 31 else {
        throw malformed("Invalid chunk in indefinite-length text string.")
      }
      let data = try readData(
        count: try checkedCount(readArgument(initial & 0x1f, kind: .length)))
      result += try decodeUTF8(data)
    }
    index += 1
    return result
  }

  private func isAtBreak() throws -> Bool {
    guard index < bytes.count else { throw malformed("Unterminated indefinite value.") }
    return bytes[index] == 0xff
  }

  private mutating func readArgument(_ info: UInt8, kind: ArgumentKind) throws -> UInt64 {
    let offset = index - 1
    let value = try readUncheckedArgument(info)
    let rejectsNonPreferred =
      kind == .integer
      ? policy.rejectNonPreferredIntegerWidths
      : policy.rejectNonPreferredLengthWidths
    if rejectsNonPreferred, !Self.isPreferredArgument(value, info: info) {
      let code: CBORLDErrorCode = kind == .integer ? .nonPreferredInteger : .nonPreferredLength
      let name = kind == .integer ? "integer" : "length"
      throw policyViolation(
        code,
        "CBOR \(name) argument uses a wider representation than required.",
        offset: offset,
        violation: "non-preferred-\(name)")
    }
    return value
  }

  @inline(__always)
  private mutating func readUncheckedArgument(_ info: UInt8) throws -> UInt64 {
    switch info {
    case 0...23:
      return UInt64(info)
    case 24:
      return UInt64(try readByte())
    case 25:
      let integer: UInt16 = try readInteger()
      return UInt64(integer)
    case 26:
      let integer: UInt32 = try readInteger()
      return UInt64(integer)
    case 27:
      return try readInteger() as UInt64
    default:
      throw malformed("Invalid CBOR additional information \(info).")
    }
  }

  private static func isPreferredArgument(_ value: UInt64, info: UInt8) -> Bool {
    switch value {
    case 0...23: return info == UInt8(value)
    case 24...UInt64(UInt8.max): return info == 24
    case 256...UInt64(UInt16.max): return info == 25
    case 65_536...UInt64(UInt32.max): return info == 26
    default: return info == 27
    }
  }

  private mutating func readByte() throws -> UInt8 {
    guard index < bytes.count else { throw malformed("Unexpected end of CBOR data.") }
    defer { index += 1 }
    return bytes[index]
  }

  private mutating func readInteger<T: FixedWidthInteger>() throws -> T {
    let size = MemoryLayout<T>.size
    guard index <= bytes.count, size <= bytes.count - index else {
      throw malformed("Unexpected end of CBOR integer.")
    }
    var value: T = 0
    switch size {
    case 1:
      value = T(bytes[index])
    case 2:
      value = T(bytes[index]) << 8 | T(bytes[index + 1])
    case 4:
      value =
        T(bytes[index]) << 24 | T(bytes[index + 1]) << 16
        | T(bytes[index + 2]) << 8 | T(bytes[index + 3])
    case 8:
      value = T(bytes[index]) << 56
      value |= T(bytes[index + 1]) << 48
      value |= T(bytes[index + 2]) << 40
      value |= T(bytes[index + 3]) << 32
      value |= T(bytes[index + 4]) << 24
      value |= T(bytes[index + 5]) << 16
      value |= T(bytes[index + 6]) << 8
      value |= T(bytes[index + 7])
    default:
      for offset in 0..<size {
        value = (value << 8) | T(bytes[index + offset])
      }
    }
    index += size
    return value
  }

  private mutating func readData(count: Int) throws -> Data {
    guard count >= 0, index <= bytes.count, count <= bytes.count - index else {
      throw malformed("Unexpected end of CBOR byte sequence.")
    }
    defer { index += count }
    return Data(bytes[index..<(index + count)])
  }

  private mutating func readUTF8String(count: Int) throws -> String {
    guard count >= 0, index <= bytes.count, count <= bytes.count - index else {
      throw malformed("Unexpected end of CBOR text string.")
    }
    let end = index + count
    let slice = bytes[index..<end]
    let string: String?
    if #available(macOS 15.0, iOS 18.0, tvOS 18.0, watchOS 11.0, visionOS 2.0, *) {
      string = String(validating: slice, as: UTF8.self)
    } else {
      string = String(bytes: slice, encoding: .utf8)
    }
    guard let string else {
      throw malformed("CBOR text string is not valid UTF-8.")
    }
    index = end
    return string
  }

  /// Reuses validated short field names within one document. Repetitive JSON
  /// objects commonly carry the same compact keys hundreds of times; packing
  /// up to eight UTF-8 bytes gives those keys an allocation-free cache lookup.
  private mutating func readJSONObjectKeyString(count: Int) throws -> String {
    guard count >= 0, index <= bytes.count, count <= bytes.count - index else {
      throw malformed("Unexpected end of CBOR text string.")
    }
    guard usesShortObjectKeyCache, count <= MemoryLayout<UInt64>.size else {
      return try readUTF8String(count: count)
    }

    shortObjectKeyLookups += 1
    var packed: UInt64 = 0
    for offset in 0..<count {
      packed |= UInt64(bytes[index + offset]) << UInt64(offset * 8)
    }
    let identity = ShortObjectKey(byteCount: UInt8(count), packedBytes: packed)
    if let cached = shortObjectKeys[identity] {
      shortObjectKeyHits += 1
      index += count
      return cached
    }

    let decoded = try readUTF8String(count: count)
    if shortObjectKeys.count < 256 {
      shortObjectKeys[identity] = decoded
    }
    if shortObjectKeyLookups == 64, shortObjectKeyHits < 16 {
      usesShortObjectKeyCache = false
      shortObjectKeys.removeAll(keepingCapacity: false)
    }
    return decoded
  }

  private func checkedCount(_ value: UInt64) throws -> Int {
    guard value <= UInt64(Int.max) else {
      throw malformed("CBOR collection is too large for this platform.")
    }
    return Int(value)
  }

  private func checkContainerCount(_ count: Int) throws {
    guard count <= limits.maximumContainerItems else {
      throw resourceLimit(
        "CBOR container contains more than \(limits.maximumContainerItems) items.")
    }
  }

  private func checkCancellation(at itemIndex: Int) throws {
    if itemIndex.isMultiple(of: limits.cancellationCheckStride),
      Task<Never, Never>.isCancelled
    {
      throw CancellationError()
    }
  }

  private func decodeUTF8(_ data: Data) throws -> String {
    guard let string = String(data: data, encoding: .utf8) else {
      throw malformed("CBOR text string is not valid UTF-8.")
    }
    return string
  }

  private func malformed(_ message: String) -> CBORLDError {
    .init(
      code: .notCBORLD,
      message: message,
      diagnostic: .init(byteOffset: min(index, bytes.count)))
  }

  private func resourceLimit(_ message: String) -> CBORLDError {
    .init(
      code: .resourceLimit,
      message: message,
      diagnostic: .init(byteOffset: min(index, bytes.count)))
  }

  private func policyViolation(
    _ code: CBORLDErrorCode,
    _ message: String,
    offset: Int,
    violation: String,
    relatedOffset: Int? = nil
  ) -> CBORLDError {
    let initial = offset >= 0 && offset < bytes.count ? bytes[offset] : 0
    return .init(
      code: code,
      message: message,
      diagnostic: .init(
        byteOffset: max(0, offset),
        majorType: initial >> 5,
        additionalInformation: initial & 0x1f,
        violation: violation,
        relatedByteOffset: relatedOffset))
  }

  private func firstMismatch(_ lhs: Data, _ rhs: Data) -> Int {
    let shared = min(lhs.count, rhs.count)
    for offset in 0..<shared where lhs[offset] != rhs[offset] { return offset }
    return shared
  }
}

extension CBORDecoder where Bytes == Data {
  init(
    data: Data,
    limits: CBORLDDecodingLimits = .init(),
    policy: CBORLDDecodingPolicy = .init()
  ) {
    self.init(bytes: data, limits: limits, policy: policy)
  }
}
