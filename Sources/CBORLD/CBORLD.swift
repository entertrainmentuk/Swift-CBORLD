import Foundation

struct ParsedCBORLD: Sendable {
  var format: CBORLDFormat
  var registryEntryID: UInt64?
  var payloadIsCompressed: Bool
  var payload: CBORValue
}

/// Stateless CBOR-LD encoding, decoding, and envelope inspection.
public enum CBORLD {
  private static let preferredUncompressedPrefix = Data(CBOREncoder.uncompressedCBORLD1Prefix)

  /// Synchronously encodes a JSON-shaped value using CBOR-LD 1.0 registry
  /// entry zero. This path performs no semantic compression and therefore has
  /// no document-loader or suspension requirement.
  public static func encodeUncompressed(
    _ document: JSONValue,
    serializationMode: CBORLDSerializationMode = .compatibility,
    limits: CBORLDEncodingLimits = .init()
  ) throws -> Data {
    try limits.validate()
    return try CBOREncoder.encodeUncompressedCBORLD1(
      document, mode: serializationMode, limits: limits)
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

  /// Encodes any `Encodable` value. The value is converted directly to a
  /// ``JSONValue`` tree by ``CBORLDValueEncoder``; no JSON text is produced
  /// or parsed.
  public static func encode<T: Encodable & Sendable>(
    _ document: T,
    options: CBORLDEncodingOptions = .init(),
    valueEncoder: CBORLDValueEncoder = .init()
  ) async throws -> Data {
    try await encode(valueEncoder.encode(document), options: options)
  }

  public static func encode(
    _ document: JSONValue,
    options: CBORLDEncodingOptions = .init()
  ) async throws -> Data {
    try options.limits.validate()
    try options.contextPolicy.validate()
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
      guard options.callerProvidedTypeTable == nil else {
        throw CBORLDError.invalidInput(
          "Registry entry 0 is uncompressed and cannot use a caller-provided type table.")
      }
      let encoded = try CBOREncoder.encodeUncompressedCBORLD1(
        document, mode: options.serializationMode, limits: options.limits)
      options.diagnostic?("CBOR-LD cbor-ld-1.0, uncompressed registry entry 0.")
      return encoded
    }

    let entry = try await resolveEncodingEntry(options)
    let preparation = try SemanticCodecPreparation(entry: entry, codecs: options.codecs)
    let payload = try await payload(
      for: document,
      preparation: preparation,
      resolver: ContextResolverFactory.make(
        documentLoader: options.documentLoader,
        contextDocumentLoader: options.contextDocumentLoader),
      contextPolicy: options.contextPolicy,
      limits: options.limits,
      payloadDepth: payloadDepth(format: options.format, registryEntryID: entry.registryEntryID))

    let envelope = try makeEnvelope(
      payload: payload,
      format: options.format,
      registryEntryID: entry.registryEntryID,
      compressionMode: entry.isLegacySingleton ? (entry.performsConversion ? 1 : 0) : nil)
    options.diagnostic?("CBOR-LD \(options.format.rawValue), \(envelope.debugDescription)")
    return try CBOREncoder.encode(
      envelope, mode: options.serializationMode, limits: options.limits)
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
    try options.contextPolicy.validate()
    let entry = try await resolveDecodingEntry(parsed, options: options)
    guard entry.performsConversion else { return try parsed.payload.toJSON() }
    let preparation = try SemanticCodecPreparation(entry: entry, codecs: options.codecs)
    let codec = SemanticCodec(
      preparation: preparation,
      resolver: try ContextResolverFactory.make(
        documentLoader: options.documentLoader,
        contextDocumentLoader: options.contextDocumentLoader),
      contextPolicy: options.contextPolicy)
    let output = try await codec.decompress(parsed.payload)
    options.diagnostic?("Decoded \(parsed.format.rawValue) CBOR-LD payload.")
    return output
  }

  /// Decodes CBOR-LD and initializes a concrete `Decodable` model from the
  /// restored JSON-LD document.
  public static func decode<T: Decodable & Sendable>(
    _ type: T.Type,
    from data: Data,
    options: CBORLDDecodingOptions = .init(),
    valueDecoder: CBORLDValueDecoder = .init()
  ) async throws -> T {
    let json = try await decode(data, options: options)
    return try valueDecoder.decode(type, from: json)
  }

  public static func inspect(
    _ data: Data,
    limits: CBORLDDecodingLimits = .init(),
    policy: CBORLDDecodingPolicy = .init()
  ) throws -> CBORLDInspection {
    let parsed = try parse(data, limits: limits, policy: policy)
    return inspection(of: parsed, bytes: data)
  }

  /// Inspects an envelope with a complete parser configuration, such as
  /// ``CBORLDDecodingConfiguration/untrustedCompatible``.
  public static func inspect(
    _ data: Data,
    configuration: CBORLDDecodingConfiguration
  ) throws -> CBORLDInspection {
    try inspect(data, limits: configuration.limits, policy: configuration.policy)
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

  /// Produces the envelope payload for one document and prepared entry.
  static func payload(
    for document: JSONValue,
    preparation: SemanticCodecPreparation,
    resolver: CBORLDContextDocumentLoader?,
    contextPolicy: CBORLDContextLoadingPolicy,
    limits: CBORLDEncodingLimits,
    payloadDepth: Int
  ) async throws -> CBORValue {
    guard preparation.performsConversion else {
      return try CBORValue.fromJSON(document, depth: payloadDepth, limits: limits)
    }
    return try await SemanticCodec(
      preparation: preparation,
      resolver: resolver,
      contextPolicy: contextPolicy,
      limits: limits,
      payloadDepth: payloadDepth
    ).compress(document)
  }

  /// The CBOR nesting depth of the payload root inside its envelope, counted
  /// like the decoder counts it.
  static func payloadDepth(format: CBORLDFormat, registryEntryID: UInt64?) -> Int {
    switch format {
    case .cborLD1: return 2
    case .legacyRange: return (registryEntryID ?? 0) < 128 ? 1 : 2
    case .legacySingleton: return 1
    }
  }

  private static func resolveEncodingEntry(
    _ options: CBORLDEncodingOptions
  ) async throws -> ResolvedRegistryEntry {
    if options.format == .legacySingleton {
      guard options.registryEntryID == nil else {
        throw CBORLDError.invalidInput(
          "registryEntryID must not be used with legacy-singleton.")
      }
      guard options.typeTableLoader == nil, options.registryEntryLoader == nil else {
        throw CBORLDError.invalidInput(
          "typeTableLoader must not be used with legacy-singleton.")
      }
      guard options.callerProvidedTypeTable == nil else {
        throw CBORLDError.invalidInput(
          "callerProvidedTypeTable must not be used with legacy-singleton.")
      }
      let mode = options.compressionMode ?? 1
      guard mode == 0 || mode == 1 else {
        throw CBORLDError.invalidInput(
          "compressionMode must be 0 or 1 for legacy-singleton.")
      }
      return mode == 1
        ? .legacySingleton(applicationContextMap: options.applicationContextMap)
        : .uncompressed(format: .legacySingleton, registryEntryID: nil)
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
    return try await ResolvedRegistryEntry.resolve(
      format: options.format,
      registryEntryID: id,
      registryEntryLoader: options.registryEntryLoader,
      typeTableLoader: options.typeTableLoader,
      callerProvidedTypeTable: options.callerProvidedTypeTable,
      allowsProvisionalEntries: options.allowsProvisionalRegistryEntries,
      forEncoding: true)
  }

  private static func resolveDecodingEntry(
    _ parsed: ParsedCBORLD,
    options: CBORLDDecodingOptions
  ) async throws -> ResolvedRegistryEntry {
    if parsed.format == .legacySingleton {
      return parsed.payloadIsCompressed
        ? .legacySingleton(applicationContextMap: options.applicationContextMap)
        : .uncompressed(format: .legacySingleton, registryEntryID: nil)
    }
    guard let id = parsed.registryEntryID else {
      throw CBORLDError(code: .notCBORLD, message: "Missing registry entry ID.")
    }
    return try await ResolvedRegistryEntry.resolve(
      format: parsed.format,
      registryEntryID: id,
      registryEntryLoader: options.registryEntryLoader,
      typeTableLoader: options.typeTableLoader,
      callerProvidedTypeTable: options.callerProvidedTypeTable,
      allowsProvisionalEntries: options.allowsProvisionalRegistryEntries,
      forEncoding: false)
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
    return try envelope(of: root)
  }

  /// Interprets a completely parsed root item as a CBOR-LD envelope.
  static func envelope(of root: CBORValue) throws -> ParsedCBORLD {
    guard case .tagged(let tag, let taggedValue) = root else {
      throw CBORLDError(
        code: .notCBORLD,
        message: "CBOR-LD data must begin with a recognized CBOR tag.",
        specificationCode: .nonCBORLDTag)
    }

    switch tag {
    case 51_997:
      guard case .array(let parts) = taggedValue,
        parts.count == 2,
        let id = parts[0].unsignedValue
      else {
        throw CBORLDError(
          code: .notCBORLD,
          message: "CBOR-LD 1.0 must contain [registryEntryID, payload].",
          specificationCode: .invalidPayloadStructure)
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
          code: .notCBORLD,
          message: "Malformed legacy-range registry entry varint.",
          specificationCode: .invalidPayloadStructure)
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
        code: .notCBORLD,
        message: "Unknown CBOR-LD tag \"\(tag)\".",
        specificationCode: .nonCBORLDTag)
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
  /// Codecs for identifiers the dictionary's processing model uses beyond
  /// the built-in codecs.
  public let codecs: [any CBORLDTypedValueCodec]
  public let limits: CBORLDEncodingLimits
  public let contextPolicy: CBORLDContextLoadingPolicy
  public let contextDocumentLoader: CBORLDContextDocumentLoader?
  private let validation = VerificationMemo<UInt64>()

  public init(
    format: CBORLDFormat = .cborLD1,
    serializationMode: CBORLDSerializationMode = .compatibility,
    dictionary: CBORLDDocumentDictionary = .unregistered,
    documentLoader: CBORLDDocumentLoader? = nil,
    diagnostic: (@Sendable (String) -> Void)? = nil,
    codecs: [any CBORLDTypedValueCodec] = [],
    limits: CBORLDEncodingLimits = .init(),
    contextPolicy: CBORLDContextLoadingPolicy = .init(),
    contextDocumentLoader: CBORLDContextDocumentLoader? = nil
  ) {
    self.format = format
    self.serializationMode = serializationMode
    self.dictionary = dictionary
    self.documentLoader = documentLoader
    self.diagnostic = diagnostic
    self.codecs = codecs
    self.limits = limits
    self.contextPolicy = contextPolicy
    self.contextDocumentLoader = contextDocumentLoader
  }

  public func encode(_ document: JSONValue) async throws -> Data {
    let dictionary = self.dictionary
    try validation.require(dictionary.code) { try dictionary.validate() }
    if format == .legacySingleton {
      guard dictionary.processingModel == nil else {
        throw CBORLDError.invalidInput(
          "legacy-singleton always uses the default processing model.")
      }
      return try await CBORLD.encode(
        document,
        options: .init(
          format: .legacySingleton,
          serializationMode: serializationMode,
          registryEntryID: nil,
          documentLoader: documentLoader,
          applicationContextMap: dictionary.contexts,
          diagnostic: diagnostic,
          codecs: codecs,
          limits: limits,
          contextPolicy: contextPolicy,
          contextDocumentLoader: contextDocumentLoader))
    }
    let entry = dictionary.registryEntry
    return try await CBORLD.encode(
      document,
      options: .init(
        format: format,
        serializationMode: serializationMode,
        registryEntryID: dictionary.code,
        documentLoader: documentLoader,
        diagnostic: diagnostic,
        registryEntryLoader: { id in id == entry.id ? entry : nil },
        codecs: codecs,
        limits: limits,
        contextPolicy: contextPolicy,
        contextDocumentLoader: contextDocumentLoader))
  }

  /// Encodes any `Encodable` value through ``CBORLDValueEncoder``.
  public func encode<T: Encodable & Sendable>(
    _ document: T,
    valueEncoder: CBORLDValueEncoder = .init()
  ) async throws -> Data {
    try await encode(valueEncoder.encode(document))
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
  /// Codecs for identifiers that dictionary processing models use beyond the
  /// built-in codecs.
  public let codecs: [any CBORLDTypedValueCodec]
  /// Whether documents may select provisional dictionaries.
  public let allowsProvisionalRegistryEntries: Bool
  public let contextPolicy: CBORLDContextLoadingPolicy
  public let contextDocumentLoader: CBORLDContextDocumentLoader?
  let configurationError: CBORLDError?
  /// Dictionary validation and pin verification depend only on immutable
  /// configuration, so each registry entry is checked once, on first use.
  private let entryVerification = VerificationMemo<UInt64>()

  public init(
    supportedFormats: Set<CBORLDFormat> = Set(CBORLDFormat.allCases),
    dictionaries: [CBORLDDocumentDictionary] = [.unregistered],
    requiredDictionaryFingerprints: [UInt64: CBORLDDigest] = [:],
    legacyApplicationContextMap: [String: UInt64]? = nil,
    documentLoader: CBORLDDocumentLoader? = nil,
    limits: CBORLDDecodingLimits = .init(),
    policy: CBORLDDecodingPolicy = .init(),
    diagnostic: (@Sendable (String) -> Void)? = nil,
    codecs: [any CBORLDTypedValueCodec] = [],
    allowsProvisionalRegistryEntries: Bool = true,
    contextPolicy: CBORLDContextLoadingPolicy = .init(),
    contextDocumentLoader: CBORLDContextDocumentLoader? = nil
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
    self.codecs = codecs
    self.allowsProvisionalRegistryEntries = allowsProvisionalRegistryEntries
    self.contextPolicy = contextPolicy
    self.contextDocumentLoader = contextDocumentLoader
    if let duplicateCode {
      self.configurationError = CBORLDError(
        code: .invalidDictionary,
        message: "Decoder received more than one dictionary with code \(duplicateCode).")
    } else if let invalidPin = requiredDictionaryFingerprints.first(where: {
      $0.key > CBORLDConstants.maximumSafeInteger
        || $0.value.domain != .documentDictionary
        || $0.value.version != 1
    }) {
      self.configurationError = CBORLDError(
        code: .invalidDigest,
        message:
          "Dictionary fingerprint for registry entry \(invalidPin.key) must be a version 1 document-dictionary digest."
      )
    } else {
      self.configurationError = nil
    }
  }

  /// Creates a decoder from a complete parser configuration, such as
  /// ``CBORLDDecodingConfiguration/untrustedDeterministic``.
  public init(
    configuration: CBORLDDecodingConfiguration,
    supportedFormats: Set<CBORLDFormat> = Set(CBORLDFormat.allCases),
    dictionaries: [CBORLDDocumentDictionary] = [.unregistered],
    requiredDictionaryFingerprints: [UInt64: CBORLDDigest] = [:],
    legacyApplicationContextMap: [String: UInt64]? = nil,
    documentLoader: CBORLDDocumentLoader? = nil,
    diagnostic: (@Sendable (String) -> Void)? = nil,
    codecs: [any CBORLDTypedValueCodec] = [],
    allowsProvisionalRegistryEntries: Bool = true,
    contextPolicy: CBORLDContextLoadingPolicy = .init(),
    contextDocumentLoader: CBORLDContextDocumentLoader? = nil
  ) {
    self.init(
      supportedFormats: supportedFormats,
      dictionaries: dictionaries,
      requiredDictionaryFingerprints: requiredDictionaryFingerprints,
      legacyApplicationContextMap: legacyApplicationContextMap,
      documentLoader: documentLoader,
      limits: configuration.limits,
      policy: configuration.policy,
      diagnostic: diagnostic,
      codecs: codecs,
      allowsProvisionalRegistryEntries: allowsProvisionalRegistryEntries,
      contextPolicy: contextPolicy,
      contextDocumentLoader: contextDocumentLoader)
  }

  /// The parser limits and representation policy as one value.
  public var configuration: CBORLDDecodingConfiguration {
    .init(limits: limits, policy: policy)
  }

  public func decode(_ data: Data) async throws -> JSONValue {
    if let configurationError { throw configurationError }
    let parsed = try CBORLD.parse(data, limits: limits, policy: policy)
    guard supportedFormats.contains(parsed.format) else {
      throw CBORLDError(
        code: .unsupportedFormat,
        message: "Decoder is not configured for \(parsed.format.rawValue).")
    }
    let dictionaries = self.dictionaries
    if let id = parsed.registryEntryID {
      let expected = requiredDictionaryFingerprints[id]
      try entryVerification.require(id) {
        let dictionary = dictionaries[id]
        if let dictionary {
          try dictionary.validate()
        }
        if let expected {
          guard let dictionary else {
            throw CBORLDError(
              code: .invalidDictionary,
              message:
                "No dictionary was configured for the required registry entry \(id) fingerprint."
            )
          }
          try dictionary.verifyFingerprint(expected)
        }
      }
    }
    return try await CBORLD.decode(
      parsed,
      options: .init(
        documentLoader: documentLoader,
        applicationContextMap: legacyApplicationContextMap,
        limits: limits,
        policy: policy,
        diagnostic: diagnostic,
        registryEntryLoader: { id in dictionaries[id]?.registryEntry },
        codecs: codecs,
        allowsProvisionalRegistryEntries: allowsProvisionalRegistryEntries,
        contextPolicy: contextPolicy,
        contextDocumentLoader: contextDocumentLoader))
  }

  /// Restores CBOR-LD and decodes the resulting JSON-LD document as `T`.
  public func decode<T: Decodable & Sendable>(
    _ type: T.Type,
    from data: Data,
    valueDecoder: CBORLDValueDecoder = .init()
  ) async throws -> T {
    let json = try await decode(data)
    return try valueDecoder.decode(type, from: json)
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
      code: .notCBORLD,
      message: "CBOR-LD encoded registry entry ID is too large.",
      specificationCode: .invalidPayloadStructure)
  }
  var value: UInt64 = 0
  var shift: UInt64 = 0
  var terminated = false
  var consumed = 0
  for byte in bytes {
    consumed += 1
    guard shift < 64 else {
      throw CBORLDError(
        code: .notCBORLD,
        message: "Registry varint overflow.",
        specificationCode: .invalidPayloadStructure)
    }
    value |= UInt64(byte & 0x7f) << shift
    if byte & 0x80 == 0 {
      terminated = true
      break
    }
    shift += 7
  }
  guard terminated else {
    throw CBORLDError(
      code: .notCBORLD,
      message: "Unterminated registry varint.",
      specificationCode: .invalidPayloadStructure)
  }
  guard consumed == bytes.count else {
    throw CBORLDError(
      code: .notCBORLD,
      message: "Registry varint contains trailing bytes.",
      specificationCode: .invalidPayloadStructure)
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
