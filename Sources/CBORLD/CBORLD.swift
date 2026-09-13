import Foundation

struct ParsedCBORLD: Sendable {
  var format: CBORLDFormat
  var registryEntryID: UInt64?
  var payloadIsCompressed: Bool
  var payload: CBORValue
}

/// Stateless CBOR-LD encoding, decoding, and envelope inspection.
public enum CBORLD {
  private static let preferredUncompressedPrefix = Data([0xd9, 0xcb, 0x1d, 0x82, 0x00])

  /// Synchronously encodes a JSON-shaped value using CBOR-LD 1.0 registry
  /// entry zero. This path performs no semantic compression and therefore has
  /// no document-loader or suspension requirement.
  public static func encodeUncompressed(
    _ document: JSONValue,
    serializationMode: CBORLDSerializationMode = .compatibility
  ) throws -> Data {
    try CBOREncoder.encodeUncompressedCBORLD1(document, mode: serializationMode)
  }

  /// Synchronously decodes a CBOR-LD 1.0 registry-zero document. Preferred
  /// envelopes use the direct JSON parser; non-preferred but valid CBOR
  /// encodings retain the general decoder fallback.
  public static func decodeUncompressed(
    _ data: Data,
    limits: CBORLDDecodingLimits = .init()
  ) throws -> JSONValue {
    if data.starts(with: preferredUncompressedPrefix) {
      return try data.withUnsafeBytes { bytes in
        var decoder = CBORDecoder(bytes: bytes, limits: limits)
        return try decoder.decodePreferredUncompressedCBORLD1()
      }
    }
    let parsed = try parse(data, limits: limits)
    guard parsed.format == .cborLD1,
      parsed.registryEntryID == 0,
      !parsed.payloadIsCompressed
    else {
      throw CBORLDError.invalidInput(
        "Synchronous uncompressed decoding requires CBOR-LD 1.0 registry entry zero.")
    }
    return try parsed.payload.toJSON()
  }

  /// Encodes any `Encodable` value after validating that it is JSON-shaped.
  public static func encode<T: Encodable & Sendable>(
    _ document: T,
    options: CBORLDEncodingOptions = .init()
  ) async throws -> Data {
    let json = try JSONValue(data: JSONEncoder().encode(document))
    return try await encode(json, options: options)
  }

  public static func encode(
    _ document: JSONValue,
    options: CBORLDEncodingOptions = .init()
  ) async throws -> Data {
    // Registry zero has no semantic transform or asynchronous dependency. Keep
    // this common interchange path allocation-light while applying the same
    // option validation as the general encoder.
    if options.format == .cborLD1, options.registryEntryID == 0 {
      guard options.applicationContextMap == nil else {
        throw CBORLDError.invalidInput(
          "applicationContextMap is only valid with legacy-singleton.")
      }
      guard options.compressionMode == nil else {
        throw CBORLDError.invalidInput(
          "compressionMode is only valid with legacy-singleton.")
      }
      let encoded = try encodeUncompressed(document, serializationMode: options.serializationMode)
      options.diagnostic?("CBOR-LD cbor-ld-1.0, uncompressed registry entry 0.")
      return encoded
    }

    let prepared = try await prepareEncoding(options)
    let payload: CBORValue
    if prepared.compressesPayload {
      let codec = try SemanticCodec(
        typeTable: prepared.typeTable,
        documentLoader: options.documentLoader,
        legacy: options.format == .legacySingleton)
      payload = try await codec.compress(document)
    } else {
      payload = try CBORValue.fromJSON(document)
    }

    let envelope = try makeEnvelope(
      payload: payload,
      format: options.format,
      registryEntryID: prepared.registryEntryID,
      compressionMode: prepared.compressionMode)
    options.diagnostic?("CBOR-LD \(options.format.rawValue), \(envelope.debugDescription)")
    return try CBOREncoder.encode(envelope, mode: options.serializationMode)
  }

  public static func decode(
    _ data: Data,
    options: CBORLDDecodingOptions = .init()
  ) async throws -> JSONValue {
    if data.starts(with: preferredUncompressedPrefix), options.policy == .init() {
      let output = try decodeUncompressed(data, limits: options.limits)
      options.diagnostic?("Decoded cbor-ld-1.0 uncompressed registry entry 0.")
      return output
    }
    let parsed = try parse(data, limits: options.limits, policy: options.policy)
    return try await decode(parsed, options: options)
  }

  static func decode(
    _ parsed: ParsedCBORLD,
    options: CBORLDDecodingOptions
  ) async throws -> JSONValue {
    if !parsed.payloadIsCompressed {
      return try parsed.payload.toJSON()
    }

    let typeTable = try await resolveTypeTable(
      format: parsed.format,
      registryEntryID: parsed.registryEntryID,
      typeTableLoader: options.typeTableLoader,
      applicationContextMap: options.applicationContextMap)
    let codec = try SemanticCodec(
      typeTable: typeTable,
      documentLoader: options.documentLoader,
      legacy: parsed.format == .legacySingleton)
    let output = try await codec.decompress(parsed.payload)
    options.diagnostic?("Decoded \(parsed.format.rawValue) CBOR-LD payload.")
    return output
  }

  /// Decodes CBOR-LD and initializes a concrete `Decodable` model from the
  /// restored JSON-LD document.
  public static func decode<T: Decodable & Sendable>(
    _ type: T.Type,
    from data: Data,
    options: CBORLDDecodingOptions = .init()
  ) async throws -> T {
    let json = try await decode(data, options: options)
    return try CBORLDValueDecoder().decode(type, from: json)
  }

  public static func inspect(
    _ data: Data,
    limits: CBORLDDecodingLimits = .init(),
    policy: CBORLDDecodingPolicy = .init()
  ) throws -> CBORLDInspection {
    let parsed = try parse(data, limits: limits, policy: policy)
    return inspection(of: parsed, bytes: data)
  }

  static func inspection(
    of parsed: ParsedCBORLD,
    bytes data: Data
  ) -> CBORLDInspection {
    return CBORLDInspection(
      format: parsed.format,
      registryEntryID: parsed.registryEntryID,
      payloadIsCompressed: parsed.payloadIsCompressed,
      byteCount: data.count,
      payloadDescription: parsed.payload.debugDescription,
      transportDigest: transportDigest(of: data))
  }

  /// The static table used by the legacy singleton format.
  public static var legacyTypeTable: CBORLDTypeTable {
    CBORLDConstants.legacyTypeTable
  }

  private struct PreparedEncoding {
    var registryEntryID: UInt64?
    var compressionMode: UInt8?
    var compressesPayload: Bool
    var typeTable: CBORLDTypeTable
  }

  private static func prepareEncoding(
    _ options: CBORLDEncodingOptions
  ) async throws -> PreparedEncoding {
    if options.format == .legacySingleton {
      guard options.registryEntryID == nil else {
        throw CBORLDError.invalidInput(
          "registryEntryID must not be used with legacy-singleton.")
      }
      guard options.typeTableLoader == nil else {
        throw CBORLDError.invalidInput(
          "typeTableLoader must not be used with legacy-singleton.")
      }
      let mode = options.compressionMode ?? 1
      guard mode == 0 || mode == 1 else {
        throw CBORLDError.invalidInput(
          "compressionMode must be 0 or 1 for legacy-singleton.")
      }
      return PreparedEncoding(
        registryEntryID: nil,
        compressionMode: mode,
        compressesPayload: mode == 1,
        typeTable: legacyTypeTable(
          applicationContextMap: options.applicationContextMap))
    }

    guard let id = options.registryEntryID,
      id <= CBORLDConstants.maximumSafeInteger
    else {
      throw CBORLDError.invalidInput(
        "registryEntryID must be a non-negative safe integer.")
    }
    guard options.applicationContextMap == nil else {
      throw CBORLDError.invalidInput(
        "applicationContextMap is only valid with legacy-singleton.")
    }
    guard options.compressionMode == nil else {
      throw CBORLDError.invalidInput(
        "compressionMode is only valid with legacy-singleton.")
    }

    let table = try await resolveTypeTable(
      format: options.format,
      registryEntryID: id,
      typeTableLoader: options.typeTableLoader,
      applicationContextMap: nil)
    return PreparedEncoding(
      registryEntryID: id,
      compressionMode: nil,
      compressesPayload: id != 0,
      typeTable: table)
  }

  private static func resolveTypeTable(
    format: CBORLDFormat,
    registryEntryID: UInt64?,
    typeTableLoader: CBORLDTypeTableLoader?,
    applicationContextMap: [String: UInt64]?
  ) async throws -> CBORLDTypeTable {
    if format == .legacySingleton {
      return legacyTypeTable(applicationContextMap: applicationContextMap)
    }
    guard let id = registryEntryID else {
      throw CBORLDError(code: "ERR_NOT_CBORLD", message: "Missing registry entry ID.")
    }
    if id == 0 || id == 1 { return CBORLDConstants.normalized(nil) }
    let loaded = try await typeTableLoader?(id)
    guard let loaded else {
      throw CBORLDError(
        code: "ERR_NO_TYPETABLE",
        message: "Type table not found for registryEntryID \"\(id)\".")
    }
    try validate(typeTable: loaded)
    return CBORLDConstants.normalized(loaded)
  }

  private static func validate(typeTable: CBORLDTypeTable) throws {
    let unsupported = [
      "http://www.w3.org/2001/XMLSchema#integer",
      "http://www.w3.org/2001/XMLSchema#double",
      "http://www.w3.org/2001/XMLSchema#boolean",
    ]
    if let type = unsupported.first(where: { typeTable[$0] != nil }) {
      throw CBORLDError(
        code: "ERR_UNSUPPORTED_LITERAL_TYPE",
        message: "Type table must not contain unsupported literal type \"\(type)\".")
    }
  }

  static func legacyTypeTable(
    applicationContextMap: [String: UInt64]?
  ) -> CBORLDTypeTable {
    guard let applicationContextMap else {
      return CBORLDConstants.legacyTypeTable
    }
    var result = CBORLDConstants.legacyTypeTable
    var strings = result["context"] ?? [:]
    for (context, id) in applicationContextMap {
      strings[.string(context)] = id
    }
    result["context"] = strings
    result["url"] = strings
    result["none"] = strings
    return result
  }

  static func makeEnvelope(
    payload: CBORValue,
    format: CBORLDFormat,
    registryEntryID: UInt64?,
    compressionMode: UInt8?
  ) throws -> CBORValue {
    switch format {
    case .cborLD1:
      guard let registryEntryID else {
        throw CBORLDError.invalidInput(
          "registryEntryID is required for cbor-ld-1.0.")
      }
      return .tagged(51_997, .array([.unsigned(registryEntryID), payload]))
    case .legacyRange:
      guard let registryEntryID else {
        throw CBORLDError.invalidInput(
          "registryEntryID is required for legacy-range.")
      }
      let varint = encodeVarint(registryEntryID)
      let tag = UInt64(1_536) + UInt64(varint[0])
      if varint.count == 1 { return .tagged(tag, payload) }
      return .tagged(tag, .array([.bytes(Data(varint.dropFirst())), payload]))
    case .legacySingleton:
      return .tagged(compressionMode == 1 ? 1_281 : 1_280, payload)
    }
  }

  static func parse(
    _ data: Data,
    limits: CBORLDDecodingLimits = .init(),
    policy: CBORLDDecodingPolicy = .init()
  ) throws -> ParsedCBORLD {
    var decoder = CBORDecoder(data: data, limits: limits, policy: policy)
    let root = try decoder.decodeComplete()
    guard case .tagged(let tag, let taggedValue) = root else {
      throw CBORLDError(
        code: "ERR_NOT_CBORLD",
        message: "CBOR-LD data must begin with a recognized CBOR tag.")
    }

    switch tag {
    case 51_997:
      guard case .array(let parts) = taggedValue,
        parts.count == 2,
        let id = parts[0].unsignedValue
      else {
        throw CBORLDError(
          code: "ERR_NOT_CBORLD",
          message: "CBOR-LD 1.0 must contain [registryEntryID, payload].")
      }
      return ParsedCBORLD(
        format: .cborLD1,
        registryEntryID: id,
        payloadIsCompressed: id != 0,
        payload: parts[1])

    case 1_536...1_791:
      let firstByte = UInt8(tag - 1_536)
      if firstByte < 128 {
        return ParsedCBORLD(
          format: .legacyRange,
          registryEntryID: UInt64(firstByte),
          payloadIsCompressed: firstByte != 0,
          payload: taggedValue)
      }
      guard case .array(let parts) = taggedValue,
        parts.count == 2,
        let remainder = parts[0].bytesValue
      else {
        throw CBORLDError(
          code: "ERR_NOT_CBORLD",
          message: "Malformed legacy-range registry entry varint.")
      }
      let bytes = [firstByte] + remainder
      let id = try decodeVarint(bytes)
      return ParsedCBORLD(
        format: .legacyRange,
        registryEntryID: id,
        payloadIsCompressed: id != 0,
        payload: parts[1])

    case 1_280, 1_281:
      return ParsedCBORLD(
        format: .legacySingleton,
        registryEntryID: nil,
        payloadIsCompressed: tag == 1_281,
        payload: taggedValue)
    default:
      throw CBORLDError(
        code: "ERR_NOT_CBORLD",
        message: "Unknown CBOR-LD tag \"\(tag)\".")
    }
  }
}

/// A reusable encoder configured around an immutable document dictionary.
public struct CBORLDEncoder: Sendable {
  public let format: CBORLDFormat
  public let serializationMode: CBORLDSerializationMode
  public let dictionary: CBORLDDocumentDictionary
  public let documentLoader: CBORLDDocumentLoader?
  public let diagnostic: (@Sendable (String) -> Void)?

  public init(
    format: CBORLDFormat = .cborLD1,
    serializationMode: CBORLDSerializationMode = .compatibility,
    dictionary: CBORLDDocumentDictionary = .unregistered,
    documentLoader: CBORLDDocumentLoader? = nil,
    diagnostic: (@Sendable (String) -> Void)? = nil
  ) {
    self.format = format
    self.serializationMode = serializationMode
    self.dictionary = dictionary
    self.documentLoader = documentLoader
    self.diagnostic = diagnostic
  }

  public func encode(_ document: JSONValue) async throws -> Data {
    try dictionary.validate()
    if format == .legacySingleton {
      return try await CBORLD.encode(
        document,
        options: .init(
          format: .legacySingleton,
          serializationMode: serializationMode,
          registryEntryID: nil,
          documentLoader: documentLoader,
          applicationContextMap: dictionary.contexts,
          diagnostic: diagnostic))
    }
    let dictionary = self.dictionary
    return try await CBORLD.encode(
      document,
      options: .init(
        format: format,
        serializationMode: serializationMode,
        registryEntryID: dictionary.code,
        documentLoader: documentLoader,
        typeTableLoader: { id in
          id == dictionary.code ? dictionary.typeTable : nil
        },
        diagnostic: diagnostic))
  }

  /// Encodes any `Encodable` value after checking that its encoded form is a
  /// valid JSON value.
  public func encode<T: Encodable & Sendable>(_ document: T) async throws -> Data {
    let json = try JSONValue(data: JSONEncoder().encode(document))
    return try await encode(json)
  }
}

/// A reusable, multi-format decoder with an explicit dictionary registry.
public struct CBORLDDecoder: Sendable {
  public let supportedFormats: Set<CBORLDFormat>
  public let dictionaries: [UInt64: CBORLDDocumentDictionary]
  /// Expected fingerprints keyed by registry entry ID. When a fingerprint is
  /// present, decoding stops before semantic expansion unless the configured
  /// dictionary matches it.
  public let requiredDictionaryFingerprints: [UInt64: CBORLDDigest]
  public let legacyApplicationContextMap: [String: UInt64]?
  public let documentLoader: CBORLDDocumentLoader?
  public let limits: CBORLDDecodingLimits
  public let policy: CBORLDDecodingPolicy
  public let diagnostic: (@Sendable (String) -> Void)?
  let configurationError: CBORLDError?

  public init(
    supportedFormats: Set<CBORLDFormat> = Set(CBORLDFormat.allCases),
    dictionaries: [CBORLDDocumentDictionary] = [.unregistered],
    requiredDictionaryFingerprints: [UInt64: CBORLDDigest] = [:],
    legacyApplicationContextMap: [String: UInt64]? = nil,
    documentLoader: CBORLDDocumentLoader? = nil,
    limits: CBORLDDecodingLimits = .init(),
    policy: CBORLDDecodingPolicy = .init(),
    diagnostic: (@Sendable (String) -> Void)? = nil
  ) {
    self.supportedFormats = supportedFormats
    var dictionaryMap: [UInt64: CBORLDDocumentDictionary] = [:]
    var duplicateCode: UInt64?
    for dictionary in dictionaries {
      if dictionaryMap[dictionary.code] != nil {
        duplicateCode = duplicateCode ?? dictionary.code
      } else {
        dictionaryMap[dictionary.code] = dictionary
      }
    }
    self.dictionaries = dictionaryMap
    self.requiredDictionaryFingerprints = requiredDictionaryFingerprints
    self.legacyApplicationContextMap = legacyApplicationContextMap
    self.documentLoader = documentLoader
    self.limits = limits
    self.policy = policy
    self.diagnostic = diagnostic
    if let duplicateCode {
      self.configurationError = CBORLDError(
        code: "ERR_INVALID_DICTIONARY",
        message: "Decoder received more than one dictionary with code \(duplicateCode).")
    } else if let invalidPin = requiredDictionaryFingerprints.first(where: {
      $0.key > CBORLDConstants.maximumSafeInteger
        || $0.value.domain != .documentDictionary
        || $0.value.version != 1
    }) {
      self.configurationError = CBORLDError(
        code: "ERR_INVALID_DIGEST",
        message:
          "Dictionary fingerprint for registry entry \(invalidPin.key) must be a version 1 document-dictionary digest."
      )
    } else {
      self.configurationError = nil
    }
  }

  public func decode(_ data: Data) async throws -> JSONValue {
    if let configurationError { throw configurationError }
    let parsed = try CBORLD.parse(data, limits: limits, policy: policy)
    guard supportedFormats.contains(parsed.format) else {
      throw CBORLDError(
        code: "ERR_UNSUPPORTED_FORMAT",
        message: "Decoder is not configured for \(parsed.format.rawValue).")
    }
    if let id = parsed.registryEntryID {
      let dictionary = dictionaries[id]
      if let dictionary {
        try dictionary.validate()
      }
      if let expected = requiredDictionaryFingerprints[id] {
        guard let dictionary else {
          throw CBORLDError(
            code: "ERR_INVALID_DICTIONARY",
            message:
              "No dictionary was configured for the required registry entry \(id) fingerprint."
          )
        }
        try dictionary.verifyFingerprint(expected)
      }
    }
    let dictionaries = self.dictionaries
    return try await CBORLD.decode(
      parsed,
      options: .init(
        documentLoader: documentLoader,
        typeTableLoader: { id in dictionaries[id]?.typeTable },
        applicationContextMap: legacyApplicationContextMap,
        limits: limits,
        policy: policy,
        diagnostic: diagnostic))
  }

  /// Restores CBOR-LD and decodes the resulting JSON-LD document as `T`.
  public func decode<T: Decodable & Sendable>(
    _ type: T.Type,
    from data: Data
  ) async throws -> T {
    let json = try await decode(data)
    return try CBORLDValueDecoder().decode(type, from: json)
  }
}

private func encodeVarint(_ input: UInt64) -> [UInt8] {
  var value = input
  var output: [UInt8] = []
  repeat {
    var byte = UInt8(value & 0x7f)
    value >>= 7
    if value != 0 { byte |= 0x80 }
    output.append(byte)
  } while value != 0
  return output
}

private func decodeVarint<C: Collection>(_ bytes: C) throws -> UInt64
where C.Element == UInt8 {
  guard bytes.count < 24 else {
    throw CBORLDError(
      code: "ERR_NOT_CBORLD",
      message: "CBOR-LD encoded registry entry ID is too large.")
  }
  var value: UInt64 = 0
  var shift: UInt64 = 0
  var terminated = false
  var consumed = 0
  for byte in bytes {
    consumed += 1
    guard shift < 64 else {
      throw CBORLDError(code: "ERR_NOT_CBORLD", message: "Registry varint overflow.")
    }
    value |= UInt64(byte & 0x7f) << shift
    if byte & 0x80 == 0 {
      terminated = true
      break
    }
    shift += 7
  }
  guard terminated else {
    throw CBORLDError(code: "ERR_NOT_CBORLD", message: "Unterminated registry varint.")
  }
  guard consumed == bytes.count else {
    throw CBORLDError(
      code: "ERR_NOT_CBORLD",
      message: "Registry varint contains trailing bytes.")
  }
  return value
}

extension CBORValue {
  fileprivate var debugDescription: String {
    switch self {
    case .unsigned(let value): return String(value)
    case .negative(let value): return String(value)
    case .bytes(let value): return "h'\(value.map { String(format: "%02x", $0) }.joined())'"
    case .string(let value): return "\"\(value)\""
    case .array(let values): return "[\(values.map(\.debugDescription).joined(separator: ", "))]"
    case .map(let entries):
      return
        "{\(entries.map { "\($0.key.debugDescription): \($0.value.debugDescription)" }.joined(separator: ", "))}"
    case .tagged(let tag, let value): return "\(tag)(\(value.debugDescription))"
    case .simple(let value): return "simple(\(value))"
    case .bool(let value): return String(value)
    case .null: return "null"
    case .double(let value): return String(value)
    }
  }
}
