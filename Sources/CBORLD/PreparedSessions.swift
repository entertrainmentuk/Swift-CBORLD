import Foundation

/// Deduplicates completed and in-flight context loads. Fingerprints configured
/// on the registry are verified before a document enters the completed cache.
/// Individual term lookups remain local to a codec operation and never cross
/// this actor boundary.
public actor CBORLDResourceCache {
  private let registry: CBORLDContextRegistry
  private var documents: [String: JSONValue]
  private var inFlight: [String: Task<JSONValue, Error>] = [:]

  public init(registry: CBORLDContextRegistry) {
    self.registry = registry
    // Registered documents also pass through the registry once so their pins
    // are verified before entering the completed cache.
    self.documents = [:]
  }

  public func load(_ url: String) async throws -> JSONValue {
    if let document = documents[url] {
      if let expected = registry.expectedFingerprints[url] {
        try CBORLD.verifyContext(document, against: expected)
      }
      return document
    }
    if let task = inFlight[url] { return try await task.value }
    let registry = self.registry
    let task = Task { try await registry.load(url) }
    inFlight[url] = task
    do {
      let document = try await task.value
      documents[url] = document
      inFlight[url] = nil
      return document
    } catch {
      inFlight[url] = nil
      throw error
    }
  }

  public func removeAll() {
    for task in inFlight.values { task.cancel() }
    inFlight.removeAll(keepingCapacity: false)
    documents = [:]
  }

  public nonisolated var documentLoader: CBORLDDocumentLoader {
    { url in try await self.load(url) }
  }
}

/// Immutable, concurrency-safe encoder setup. Dictionary validation and
/// reverse-table construction happen once; each operation receives isolated
/// mutable context state while sharing only the resource cache.
public struct CBORLDPreparedEncoder: Sendable {
  public let format: CBORLDFormat
  public let serializationMode: CBORLDSerializationMode
  public let dictionary: CBORLDDocumentDictionary
  public let provenance: CBORLDResourceProvenance
  private let preparation: SemanticCodecPreparation
  private let documentLoader: CBORLDDocumentLoader?
  private let diagnostic: (@Sendable (String) -> Void)?

  public init(
    format: CBORLDFormat = .cborLD1,
    serializationMode: CBORLDSerializationMode = .compatibility,
    dictionary: CBORLDDocumentDictionary = .unregistered,
    contextRegistry: CBORLDContextRegistry? = nil,
    documentLoader: CBORLDDocumentLoader? = nil,
    requiredDictionaryFingerprint: CBORLDDigest? = nil,
    diagnostic: (@Sendable (String) -> Void)? = nil
  ) throws {
    try dictionary.validate()
    if let requiredDictionaryFingerprint {
      try dictionary.verifyFingerprint(requiredDictionaryFingerprint)
    }
    self.format = format
    self.serializationMode = serializationMode
    self.dictionary = dictionary
    self.diagnostic = diagnostic
    let table =
      format == .legacySingleton
      ? CBORLD.legacyTypeTable(applicationContextMap: dictionary.contexts)
      : CBORLDConstants.normalized(dictionary.typeTable)
    self.preparation = try SemanticCodecPreparation(
      typeTable: table,
      legacy: format == .legacySingleton)
    if let contextRegistry {
      self.documentLoader = CBORLDResourceCache(registry: contextRegistry).documentLoader
    } else {
      self.documentLoader = documentLoader
    }
    self.provenance = CBORLDResourceProvenance(
      dictionaryFingerprint: try dictionary.fingerprint(),
      contextFingerprints: contextRegistry?.expectedFingerprints ?? [:])
  }

  public func encode(_ document: JSONValue) async throws -> Data {
    if format == .cborLD1, dictionary.code == 0 {
      let bytes = try CBORLD.encodeUncompressed(document, serializationMode: serializationMode)
      diagnostic?("CBOR-LD cbor-ld-1.0, prepared uncompressed registry entry 0.")
      return bytes
    }
    let compresses = format == .legacySingleton || dictionary.code != 0
    let payload: CBORValue
    if compresses {
      payload = try await SemanticCodec(
        preparation: preparation,
        documentLoader: documentLoader
      ).compress(document)
    } else {
      payload = try CBORValue.fromJSON(document)
    }
    let envelope = try CBORLD.makeEnvelope(
      payload: payload,
      format: format,
      registryEntryID: format == .legacySingleton ? nil : dictionary.code,
      compressionMode: format == .legacySingleton ? 1 : nil)
    let bytes = try CBOREncoder.encode(envelope, mode: serializationMode)
    diagnostic?("Encoded prepared \(format.rawValue) CBOR-LD payload.")
    return bytes
  }

  public func encode<T: Encodable & Sendable>(_ document: T) async throws -> Data {
    try await encode(JSONValue(data: JSONEncoder().encode(document)))
  }
}

/// Immutable, concurrency-safe decoder setup. Every dictionary and pin is
/// validated once, and configured decode parses each input exactly once.
public struct CBORLDPreparedDecoder: Sendable {
  public let supportedFormats: Set<CBORLDFormat>
  public let limits: CBORLDDecodingLimits
  public let policy: CBORLDDecodingPolicy
  public let provenance: [UInt64: CBORLDResourceProvenance]
  private let preparations: [UInt64: SemanticCodecPreparation]
  private let legacyPreparation: SemanticCodecPreparation
  private let documentLoader: CBORLDDocumentLoader?
  private let diagnostic: (@Sendable (String) -> Void)?

  public init(
    supportedFormats: Set<CBORLDFormat> = Set(CBORLDFormat.allCases),
    dictionaries: [CBORLDDocumentDictionary] = [.unregistered],
    requiredDictionaryFingerprints: [UInt64: CBORLDDigest] = [:],
    legacyApplicationContextMap: [String: UInt64]? = nil,
    contextRegistry: CBORLDContextRegistry? = nil,
    documentLoader: CBORLDDocumentLoader? = nil,
    limits: CBORLDDecodingLimits = .init(),
    policy: CBORLDDecodingPolicy = .init(),
    diagnostic: (@Sendable (String) -> Void)? = nil
  ) throws {
    var dictionariesByCode: [UInt64: CBORLDDocumentDictionary] = [:]
    for dictionary in dictionaries {
      guard dictionariesByCode[dictionary.code] == nil else {
        throw CBORLDError(
          code: "ERR_INVALID_DICTIONARY",
          message: "Decoder received more than one dictionary with code \(dictionary.code).")
      }
      try dictionary.validate()
      dictionariesByCode[dictionary.code] = dictionary
    }
    for (code, fingerprint) in requiredDictionaryFingerprints {
      guard let dictionary = dictionariesByCode[code] else {
        throw CBORLDError(
          code: "ERR_INVALID_DICTIONARY",
          message: "No dictionary was configured for required registry entry \(code).")
      }
      try dictionary.verifyFingerprint(fingerprint)
    }

    var prepared: [UInt64: SemanticCodecPreparation] = [
      0: try SemanticCodecPreparation(typeTable: CBORLDConstants.normalized(nil), legacy: false),
      1: try SemanticCodecPreparation(typeTable: CBORLDConstants.normalized(nil), legacy: false),
    ]
    var provenance: [UInt64: CBORLDResourceProvenance] = [:]
    for (code, dictionary) in dictionariesByCode {
      prepared[code] = try SemanticCodecPreparation(
        typeTable: CBORLDConstants.normalized(dictionary.typeTable),
        legacy: false)
      provenance[code] = CBORLDResourceProvenance(
        dictionaryFingerprint: try dictionary.fingerprint(),
        contextFingerprints: contextRegistry?.expectedFingerprints ?? [:])
    }
    self.supportedFormats = supportedFormats
    self.limits = limits
    self.policy = policy
    self.preparations = prepared
    self.provenance = provenance
    self.legacyPreparation = try SemanticCodecPreparation(
      typeTable: CBORLD.legacyTypeTable(applicationContextMap: legacyApplicationContextMap),
      legacy: true)
    if let contextRegistry {
      self.documentLoader = CBORLDResourceCache(registry: contextRegistry).documentLoader
    } else {
      self.documentLoader = documentLoader
    }
    self.diagnostic = diagnostic
  }

  public func decode(_ data: Data) async throws -> JSONValue {
    let parsed = try CBORLD.parse(data, limits: limits, policy: policy)
    return try await decode(parsed)
  }

  public func decode(_ document: CBORLDValidatedDocument) async throws -> JSONValue {
    guard document.validationPolicy == policy else {
      throw CBORLDError(
        code: "ERR_POLICY_MISMATCH",
        message: "Prepared decoder policy differs from the validated document policy.")
    }
    return try await decode(document.parsed)
  }

  public func decode<T: Decodable & Sendable>(
    _ type: T.Type,
    from data: Data
  ) async throws -> T {
    try CBORLDValueDecoder().decode(type, from: await decode(data))
  }

  private func decode(_ parsed: ParsedCBORLD) async throws -> JSONValue {
    guard supportedFormats.contains(parsed.format) else {
      throw CBORLDError(
        code: "ERR_UNSUPPORTED_FORMAT",
        message: "Decoder is not configured for \(parsed.format.rawValue).")
    }
    guard parsed.payloadIsCompressed else { return try parsed.payload.toJSON() }
    let preparation: SemanticCodecPreparation
    if parsed.format == .legacySingleton {
      preparation = legacyPreparation
    } else {
      guard let id = parsed.registryEntryID, let configured = preparations[id] else {
        throw CBORLDError(
          code: "ERR_NO_TYPETABLE",
          message:
            "Type table not found for registryEntryID \"\(parsed.registryEntryID.map(String.init) ?? "nil")\"."
        )
      }
      preparation = configured
    }
    let output = try await SemanticCodec(
      preparation: preparation,
      documentLoader: documentLoader
    ).decompress(parsed.payload)
    diagnostic?("Decoded prepared \(parsed.format.rawValue) CBOR-LD payload.")
    return output
  }
}

extension CBORLDEncoder {
  /// Validates and precomputes immutable tables for repeated operations.
  public func prepare(
    contextRegistry: CBORLDContextRegistry? = nil,
    requiredDictionaryFingerprint: CBORLDDigest? = nil
  ) throws -> CBORLDPreparedEncoder {
    try CBORLDPreparedEncoder(
      format: format,
      serializationMode: serializationMode,
      dictionary: dictionary,
      contextRegistry: contextRegistry,
      documentLoader: documentLoader,
      requiredDictionaryFingerprint: requiredDictionaryFingerprint,
      diagnostic: diagnostic)
  }
}

extension CBORLDDecoder {
  /// Validates dictionaries and constructs reverse tables once for repeated or
  /// concurrent operations.
  public func prepare(
    contextRegistry: CBORLDContextRegistry? = nil
  ) throws -> CBORLDPreparedDecoder {
    if let configurationError { throw configurationError }
    return try CBORLDPreparedDecoder(
      supportedFormats: supportedFormats,
      dictionaries: Array(dictionaries.values),
      requiredDictionaryFingerprints: requiredDictionaryFingerprints,
      legacyApplicationContextMap: legacyApplicationContextMap,
      contextRegistry: contextRegistry,
      documentLoader: documentLoader,
      limits: limits,
      policy: policy,
      diagnostic: diagnostic)
  }
}
