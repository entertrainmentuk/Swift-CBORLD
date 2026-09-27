import Foundation

/// One source-preserving CBOR item discovered during lossless validation.
/// Byte ranges are half-open offsets into ``CBORLDValidatedDocument/originalBytes``.
public struct CBORLDRawNode: Sendable, Hashable, Codable {
  public let byteOffset: Int
  public let endOffset: Int
  public let containerPath: [String]
  public let jsonPath: String?
  public let majorType: UInt8
  public let additionalInformation: UInt8
  public let isIndefiniteLength: Bool
  public let preferredSerializationViolations: [String]

  public var byteCount: Int { endOffset - byteOffset }
}

/// Immutable provenance for resources that gave compressed values meaning.
public struct CBORLDResourceProvenance: Sendable, Hashable, Codable {
  public let dictionaryFingerprint: CBORLDDigest?
  public let contextFingerprints: [String: CBORLDDigest]

  public init(
    dictionaryFingerprint: CBORLDDigest? = nil,
    contextFingerprints: [String: CBORLDDigest] = [:]
  ) {
    self.dictionaryFingerprint = dictionaryFingerprint
    self.contextFingerprints = contextFingerprints
  }
}

/// A validated CBOR-LD envelope that keeps its exact original byte spelling.
/// It preserves non-preferred widths, map order, tags, simple values, and
/// definite versus indefinite containers. Semantic decode reuses the parsed
/// value retained here; it does not parse the transport a second time.
public struct CBORLDValidatedDocument: Sendable {
  public let originalBytes: Data
  public let inspection: CBORLDInspection
  public let nodes: [CBORLDRawNode]
  public let nodesWereTruncated: Bool
  public let validationPolicy: CBORLDDecodingPolicy
  public let provenance: CBORLDResourceProvenance
  let parsed: ParsedCBORLD

  /// Returns the exact bytes occupied by a node, after checking that it belongs
  /// to this document's source range.
  public func bytes(for node: CBORLDRawNode) throws -> Data {
    guard node.byteOffset >= 0, node.endOffset >= node.byteOffset,
      node.endOffset <= originalBytes.count
    else {
      throw CBORLDError.invalidInput("Raw CBOR node range is outside the validated document.")
    }
    return originalBytes.subdata(in: node.byteOffset..<node.endOffset)
  }
}

extension CBORLD {
  /// Validates one complete envelope and retains exact transport bytes plus a
  /// bounded source map. Contexts and type tables are deliberately not loaded.
  public static func validateLossless(
    _ data: Data,
    limits: CBORLDDecodingLimits = .init(),
    policy: CBORLDDecodingPolicy = .init(),
    provenance: CBORLDResourceProvenance = .init()
  ) throws -> CBORLDValidatedDocument {
    var scanner = CBORLDRawScanner(data: data, limits: limits)
    let raw = try scanner.scan()
    let parsed: ParsedCBORLD
    do {
      parsed = try parse(data, limits: limits, policy: policy)
    } catch let error as CBORLDError {
      guard let diagnostic = error.diagnostic,
        let node = raw.nodes.last(where: {
          $0.byteOffset <= diagnostic.byteOffset && diagnostic.byteOffset < $0.endOffset
        })
      else { throw error }
      throw CBORLDError(
        code: error.code,
        message: error.message,
        diagnostic: .init(
          byteOffset: diagnostic.byteOffset,
          endOffset: diagnostic.endOffset,
          containerPath: node.containerPath,
          jsonPath: node.jsonPath,
          majorType: diagnostic.majorType ?? node.majorType,
          additionalInformation:
            diagnostic.additionalInformation ?? node.additionalInformation,
          violation: diagnostic.violation,
          relatedByteOffset: diagnostic.relatedByteOffset))
    }
    return CBORLDValidatedDocument(
      originalBytes: data,
      inspection: inspection(of: parsed, bytes: data),
      nodes: raw.nodes,
      nodesWereTruncated: raw.wasTruncated,
      validationPolicy: policy,
      provenance: provenance,
      parsed: parsed)
  }

  /// Semantically decodes an already validated document without parsing the
  /// CBOR transport again. The options must carry the policy used at validation
  /// so a caller cannot accidentally claim a stricter check than was applied.
  public static func decode(
    _ document: CBORLDValidatedDocument,
    options: CBORLDDecodingOptions = .init()
  ) async throws -> JSONValue {
    guard options.policy == document.validationPolicy else {
      throw CBORLDError(
        code: .policyMismatch,
        message: "Decode policy differs from the document's validation policy.")
    }
    return try await decode(document.parsed, options: options)
  }
}

private struct CBORLDRawScanResult {
  var nodes: [CBORLDRawNode]
  var wasTruncated: Bool
}

/// A source-map pass used only by the explicit lossless API. Ordinary and
/// configured semantic decoding do not pay for node construction.
private struct CBORLDRawScanner {
  private struct ValueSummary {
    var string: String?
  }

  let data: Data
  let limits: CBORLDDecodingLimits
  var offset = 0
  var nodes: [CBORLDRawNode] = []
  var wasTruncated = false

  mutating func scan() throws -> CBORLDRawScanResult {
    guard limits.maximumDiagnosticNodes >= 0,
      limits.cancellationCheckStride > 0
    else {
      throw CBORLDError(
        code: .resourceLimit,
        message:
          "maximumDiagnosticNodes must not be negative and cancellationCheckStride must be positive."
      )
    }
    _ = try scanValue(depth: 0, path: ["$"], jsonPath: "$")
    guard offset == data.count else {
      throw malformed("Unexpected trailing bytes after the CBOR value.", at: offset)
    }
    nodes.sort { $0.byteOffset < $1.byteOffset }
    return CBORLDRawScanResult(nodes: nodes, wasTruncated: wasTruncated)
  }

  private mutating func scanValue(
    depth: Int,
    path: [String],
    jsonPath: String?
  ) throws -> ValueSummary {
    guard depth <= limits.maximumNestingDepth else {
      throw CBORLDError(
        code: .resourceLimit,
        message: "CBOR nesting exceeds the configured depth of \(limits.maximumNestingDepth).",
        diagnostic: .init(byteOffset: offset, containerPath: path, jsonPath: jsonPath))
    }
    let start = offset
    let initial = try readByte(path: path, jsonPath: jsonPath)
    let major = initial >> 5
    let info = initial & 0x1f
    var violations: [String] = []
    var string: String?
    switch major {
    case 0, 1, 6:
      let argument = try readArgument(info, path: path, jsonPath: jsonPath)
      if !isPreferred(argument: argument, info: info) {
        violations.append("non-preferred-integer")
      }
      if major == 6 {
        _ = try scanValue(
          depth: depth + 1,
          path: path + ["taggedValue"],
          jsonPath: jsonPath)
      }
    case 2, 3:
      if info == 31 {
        try scanIndefiniteString(
          major: major,
          depth: depth,
          path: path,
          jsonPath: jsonPath)
      } else {
        let count = try readArgument(info, path: path, jsonPath: jsonPath)
        if !isPreferred(argument: count, info: info) {
          violations.append("non-preferred-length")
        }
        let bytes = try readData(
          count: try integerCount(count), path: path, jsonPath: jsonPath)
        if major == 3 {
          guard let decoded = String(data: bytes, encoding: .utf8) else {
            throw malformed("CBOR text string is not valid UTF-8.", at: start, path: path)
          }
          string = decoded
        }
      }
    case 4:
      if info == 31 {
        var index = 0
        while try !isAtBreak(path: path) {
          try checkCancellation(at: index)
          try checkContainerCount(index + 1, at: start, path: path)
          _ = try scanValue(
            depth: depth + 1,
            path: path + ["[\(index)]"],
            jsonPath: jsonPath.map { "\($0)[\(index)]" })
          index += 1
        }
        offset += 1
      } else {
        let count = try readArgument(info, path: path, jsonPath: jsonPath)
        if !isPreferred(argument: count, info: info) {
          violations.append("non-preferred-length")
        }
        let itemCount = try integerCount(count)
        try checkContainerCount(itemCount, at: start, path: path)
        for index in 0..<itemCount {
          try checkCancellation(at: index)
          _ = try scanValue(
            depth: depth + 1,
            path: path + ["[\(index)]"],
            jsonPath: jsonPath.map { "\($0)[\(index)]" })
        }
      }
    case 5:
      try scanMap(
        info: info,
        depth: depth,
        start: start,
        path: path,
        jsonPath: jsonPath,
        violations: &violations)
    case 7:
      try scanSimple(info: info, start: start, path: path, violations: &violations)
    default:
      throw malformed("Unknown CBOR major type \(major).", at: start, path: path)
    }
    appendNode(
      .init(
        byteOffset: start,
        endOffset: offset,
        containerPath: path,
        jsonPath: jsonPath,
        majorType: major,
        additionalInformation: info,
        isIndefiniteLength: info == 31,
        preferredSerializationViolations: violations))
    return ValueSummary(string: string)
  }

  private mutating func scanMap(
    info: UInt8,
    depth: Int,
    start: Int,
    path: [String],
    jsonPath: String?,
    violations: inout [String]
  ) throws {
    let count: Int?
    if info == 31 {
      count = nil
    } else {
      let argument = try readArgument(info, path: path, jsonPath: jsonPath)
      if !isPreferred(argument: argument, info: info) {
        violations.append("non-preferred-length")
      }
      count = try integerCount(argument)
      try checkContainerCount(count!, at: start, path: path)
    }
    var entry = 0
    while true {
      if let count {
        if entry >= count { break }
      } else if try isAtBreak(path: path) {
        break
      }
      try checkCancellation(at: entry)
      if count == nil { try checkContainerCount(entry + 1, at: start, path: path) }
      let key = try scanValue(
        depth: depth + 1,
        path: path + ["key[\(entry)]"],
        jsonPath: nil)
      let valueJSONPath = key.string.flatMap { key in
        jsonPath.map { "\($0)[\(String(reflecting: key))]" }
      }
      _ = try scanValue(
        depth: depth + 1,
        path: path + ["value[\(entry)]"],
        jsonPath: valueJSONPath)
      entry += 1
    }
    if count == nil { offset += 1 }
  }

  private mutating func scanIndefiniteString(
    major: UInt8,
    depth: Int,
    path: [String],
    jsonPath: String?
  ) throws {
    var chunk = 0
    while try !isAtBreak(path: path) {
      try checkCancellation(at: chunk)
      let chunkStart = offset
      let initial = try readByte(path: path, jsonPath: jsonPath)
      guard initial >> 5 == major, initial & 0x1f != 31 else {
        throw malformed("Invalid chunk in indefinite-length string.", at: chunkStart, path: path)
      }
      let info = initial & 0x1f
      let count = try readArgument(info, path: path, jsonPath: jsonPath)
      let bytes = try readData(
        count: try integerCount(count), path: path, jsonPath: jsonPath)
      if major == 3, String(data: bytes, encoding: .utf8) == nil {
        throw malformed("CBOR text string is not valid UTF-8.", at: chunkStart, path: path)
      }
      appendNode(
        .init(
          byteOffset: chunkStart,
          endOffset: offset,
          containerPath: path + ["chunk[\(chunk)]"],
          jsonPath: jsonPath,
          majorType: major,
          additionalInformation: info,
          isIndefiniteLength: false,
          preferredSerializationViolations:
            isPreferred(argument: count, info: info) ? [] : ["non-preferred-length"]))
      chunk += 1
    }
    offset += 1
  }

  private mutating func scanSimple(
    info: UInt8,
    start: Int,
    path: [String],
    violations: inout [String]
  ) throws {
    switch info {
    case 0...23:
      break
    case 24:
      let value = try readByte(path: path, jsonPath: nil)
      if value < 32 { violations.append("non-preferred-simple") }
    case 25:
      let bits = try readUnsigned(byteCount: 2, path: path)
      let value = Double(Float16(bitPattern: UInt16(bits)))
      if value.isNaN, bits != 0x7e00 { violations.append("non-preferred-float") }
    case 26:
      let bits = try readUnsigned(byteCount: 4, path: path)
      let value = Double(Float(bitPattern: UInt32(bits)))
      if value.isNaN || Double(Float16(value)).bitPattern == value.bitPattern {
        violations.append("non-preferred-float")
      }
    case 27:
      let bits = try readUnsigned(byteCount: 8, path: path)
      let value = Double(bitPattern: bits)
      if value.isNaN || Double(Float(value)).bitPattern == value.bitPattern {
        violations.append("non-preferred-float")
      }
    case 31:
      throw malformed("Unexpected CBOR break marker.", at: start, path: path)
    default:
      throw malformed("Invalid CBOR simple value.", at: start, path: path)
    }
  }

  private mutating func readArgument(
    _ info: UInt8,
    path: [String],
    jsonPath: String?
  ) throws -> UInt64 {
    switch info {
    case 0...23: return UInt64(info)
    case 24: return try readUnsigned(byteCount: 1, path: path)
    case 25: return try readUnsigned(byteCount: 2, path: path)
    case 26: return try readUnsigned(byteCount: 4, path: path)
    case 27: return try readUnsigned(byteCount: 8, path: path)
    default:
      throw malformed("Invalid CBOR additional information \(info).", at: offset - 1, path: path)
    }
  }

  private mutating func readUnsigned(byteCount: Int, path: [String]) throws -> UInt64 {
    guard offset <= data.count, byteCount <= data.count - offset else {
      throw malformed("Unexpected end of CBOR integer.", at: offset, path: path)
    }
    var value: UInt64 = 0
    for byte in data[offset..<(offset + byteCount)] { value = (value << 8) | UInt64(byte) }
    offset += byteCount
    return value
  }

  private mutating func readByte(path: [String], jsonPath: String?) throws -> UInt8 {
    guard offset < data.count else {
      throw CBORLDError(
        code: .notCBORLD,
        message: "Unexpected end of CBOR data.",
        diagnostic: .init(byteOffset: offset, containerPath: path, jsonPath: jsonPath))
    }
    defer { offset += 1 }
    return data[offset]
  }

  private mutating func readData(
    count: Int,
    path: [String],
    jsonPath: String?
  ) throws -> Data {
    guard count >= 0, offset <= data.count, count <= data.count - offset else {
      throw CBORLDError(
        code: .notCBORLD,
        message: "Unexpected end of CBOR byte sequence.",
        diagnostic: .init(byteOffset: offset, containerPath: path, jsonPath: jsonPath))
    }
    defer { offset += count }
    return data.subdata(in: offset..<(offset + count))
  }

  private func isAtBreak(path: [String]) throws -> Bool {
    guard offset < data.count else {
      throw malformed("Unterminated indefinite value.", at: offset, path: path)
    }
    return data[offset] == 0xff
  }

  private mutating func appendNode(_ node: CBORLDRawNode) {
    if nodes.count < limits.maximumDiagnosticNodes {
      nodes.append(node)
    } else {
      wasTruncated = true
    }
  }

  private func integerCount(_ value: UInt64) throws -> Int {
    guard value <= UInt64(Int.max) else {
      throw malformed("CBOR collection is too large for this platform.", at: offset)
    }
    return Int(value)
  }

  private func checkContainerCount(_ count: Int, at offset: Int, path: [String]) throws {
    guard count <= limits.maximumContainerItems else {
      throw CBORLDError(
        code: .resourceLimit,
        message: "CBOR container contains more than \(limits.maximumContainerItems) items.",
        diagnostic: .init(byteOffset: offset, containerPath: path))
    }
  }

  private func checkCancellation(at itemIndex: Int) throws {
    if itemIndex.isMultiple(of: limits.cancellationCheckStride),
      Task<Never, Never>.isCancelled
    {
      throw CancellationError()
    }
  }

  private func isPreferred(argument: UInt64, info: UInt8) -> Bool {
    switch argument {
    case 0...23: return info == UInt8(argument)
    case 24...UInt64(UInt8.max): return info == 24
    case 256...UInt64(UInt16.max): return info == 25
    case 65_536...UInt64(UInt32.max): return info == 26
    default: return info == 27
    }
  }

  private func malformed(
    _ message: String,
    at byteOffset: Int,
    path: [String] = []
  ) -> CBORLDError {
    .init(
      code: .notCBORLD,
      message: message,
      diagnostic: .init(byteOffset: byteOffset, containerPath: path))
  }
}
