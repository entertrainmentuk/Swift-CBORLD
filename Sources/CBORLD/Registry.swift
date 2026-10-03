import Foundation

// MARK: - Codec identifiers

/// Identifies a typed-value codec bound by a processing model's `codecs` map.
///
/// The four identifiers defined by the CBOR-LD 1.0 editor's draft are
/// built in. Any other identifier must be supplied as a
/// ``CBORLDTypedValueCodec`` when a registry entry that uses it is prepared.
public struct CBORLDCodecIdentifier: RawRepresentable, Sendable, Hashable, Codable,
  ExpressibleByStringLiteral, CustomStringConvertible
{
  public let rawValue: String

  public init(rawValue: String) {
    self.rawValue = rawValue
  }

  public init(stringLiteral value: String) {
    self.rawValue = value
  }

  public var description: String { rawValue }

  /// The URL codec (scheme prefixes, UUID URNs, data URLs, and base58 DIDs).
  public static let url: Self = "url"
  /// The `xsd:date` codec.
  public static let xsdDate: Self = "xsd-date"
  /// The `xsd:dateTime` codec.
  public static let xsdDateTime: Self = "xsd-date-time"
  /// The multibase codec for `z`, `u`, and `M` prefixes.
  public static let multibase: Self = "multibase"

  /// Identifiers implemented by this package.
  public static let builtIn: Set<Self> = [.url, .xsdDate, .xsdDateTime, .multibase]

  public var isBuiltIn: Bool { Self.builtIn.contains(self) }
}

// MARK: - Processing models

/// The compression strategies a registry entry selects: whether JSON-LD terms
/// are semantically compressed, and which codecs compress typed values.
///
/// This mirrors the `processingModel` member of a CBOR-LD Registry Entry in the
/// CBOR-LD 1.0 editor's draft. Registry dictionaries (type tables) are a
/// separate part of the entry and are not part of the processing model.
public struct CBORLDProcessingModel: Sendable, Hashable, Codable {
  /// Whether terms are replaced by integer identifiers derived from the
  /// contexts a document references. When `false`, every key remains a
  /// string, but referenced contexts are still processed so that typed-value
  /// codecs and type tables can apply.
  public var semanticCompression: Bool
  /// Maps a JSON-LD type IRI, or the reserved type ``urlType``, to the codec
  /// used for values of that type. Values whose type has no codec are carried
  /// through unchanged.
  public var codecs: [String: CBORLDCodecIdentifier]

  public init(
    semanticCompression: Bool = true,
    codecs: [String: CBORLDCodecIdentifier] = [:]
  ) {
    self.semanticCompression = semanticCompression
    self.codecs = codecs
  }

  /// The reserved type matching node references and values whose term is
  /// defined with an `@type` of `@id` or `@vocab`.
  public static let urlType = "url"
  public static let xsdDateType = "http://www.w3.org/2001/XMLSchema#date"
  public static let xsdDateTimeType = "http://www.w3.org/2001/XMLSchema#dateTime"
  public static let multibaseType = "https://w3id.org/security#multibase"

  /// The default processing model: semantic compression plus every codec
  /// defined by the editor's draft, each bound to the type it compresses. A
  /// registry entry without a `processingModel` member uses this model.
  public static let `default` = Self(
    semanticCompression: true,
    codecs: [
      urlType: .url,
      xsdDateType: .xsdDate,
      xsdDateTimeType: .xsdDateTime,
      multibaseType: .multibase,
    ])

  /// No semantic compression and no codecs. Registry entry `0` uses this
  /// model, so its payload is the plain CBOR encoding of the document.
  public static let uncompressed = Self(semanticCompression: false, codecs: [:])

  /// Validates the model's shape. Codec identifiers are resolved separately,
  /// when a model is prepared together with any user-supplied codecs.
  public func validate() throws {
    for (type, identifier) in codecs {
      // The draft binds codecs to a JSON-LD type IRI or the reserved `url`
      // type; `context` and `none` are type-table categories, not types.
      guard type == Self.urlType || type.contains(":") else {
        throw CBORLDError(
          code: .invalidProcessingModel,
          message:
            "A codec must be bound to the reserved type \"url\" or to a type IRI, not \"\(type)\"."
        )
      }
      guard !identifier.rawValue.isEmpty else {
        throw CBORLDError(
          code: .invalidProcessingModel,
          message: "The codec bound to \"\(type)\" has an empty identifier.")
      }
    }
  }

  private enum CodingKeys: String, CodingKey {
    case semanticCompression
    case codecs
  }

  /// Decodes the draft's representation. An absent `semanticCompression` is
  /// `true`; an absent `codecs` member binds no codecs.
  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    semanticCompression =
      try container.decodeIfPresent(Bool.self, forKey: .semanticCompression) ?? true
    codecs =
      try container.decodeIfPresent(
        [String: CBORLDCodecIdentifier].self, forKey: .codecs) ?? [:]
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(semanticCompression, forKey: .semanticCompression)
    try container.encode(codecs, forKey: .codecs)
  }
}

// MARK: - CBOR data items for user codecs

/// A key/value pair in a ``CBORLDDataItem`` map. Map entries keep their order;
/// the configured serialization mode sorts them when bytes are written.
public struct CBORLDMapEntry: Sendable, Hashable {
  public var key: CBORLDDataItem
  public var value: CBORLDDataItem

  public init(key: CBORLDDataItem, value: CBORLDDataItem) {
    self.key = key
    self.value = value
  }
}

/// One CBOR data item, as exchanged with a ``CBORLDTypedValueCodec``.
public indirect enum CBORLDDataItem: Sendable, Hashable {
  case unsigned(UInt64)
  /// A negative integer. The associated value must be below zero.
  case negative(Int64)
  case bytes(Data)
  case text(String)
  case array([CBORLDDataItem])
  case map([CBORLDMapEntry])
  case tagged(UInt64, CBORLDDataItem)
  /// An unassigned or reserved simple value other than `false`, `true`, and
  /// `null`.
  case simple(UInt8)
  case bool(Bool)
  case null
  /// A floating-point value, written in the shortest exact IEEE 754 width.
  case float(Double)
}

extension CBORLDDataItem {
  init(_ value: CBORValue) {
    switch value {
    case .unsigned(let value): self = .unsigned(value)
    case .negative(let value): self = .negative(value)
    case .bytes(let value): self = .bytes(value)
    case .string(let value): self = .text(value)
    case .array(let values): self = .array(values.map(CBORLDDataItem.init))
    case .map(let entries):
      self = .map(entries.map { .init(key: .init($0.key), value: .init($0.value)) })
    case .tagged(let tag, let value): self = .tagged(tag, .init(value))
    case .simple(let value): self = .simple(value)
    case .bool(let value): self = .bool(value)
    case .null: self = .null
    case .double(let value): self = .float(value)
    }
  }

  var cborValue: CBORValue {
    switch self {
    case .unsigned(let value): return .unsigned(value)
    case .negative(let value): return .negative(value)
    case .bytes(let value): return .bytes(value)
    case .text(let value): return .string(value)
    case .array(let values): return .array(values.map(\.cborValue))
    case .map(let entries):
      return .map(entries.map { CBORMapEntry(key: $0.key.cborValue, value: $0.value.cborValue) })
    case .tagged(let tag, let value): return .tagged(tag, value.cborValue)
    case .simple(let value): return .simple(value)
    case .bool(let value): return .bool(value)
    case .null: return .null
    case .float(let value): return .double(value)
    }
  }
}

// MARK: - User-supplied codecs

/// Where a typed value is being converted.
public struct CBORLDCodecContext: Sendable, Hashable {
  /// The type the codec is bound to: a JSON-LD type IRI or ``CBORLDProcessingModel/urlType``.
  public let type: String
  /// The JSON-LD term whose value is being converted.
  public let term: String
  /// The registry entry that selected the processing model, if any.
  public let registryEntryID: UInt64?

  public init(type: String, term: String, registryEntryID: UInt64?) {
    self.type = type
    self.term = term
    self.registryEntryID = registryEntryID
  }
}

/// A typed-value codec defined outside the CBOR-LD specification.
///
/// A processing model binds the codec's ``identifier`` to a type. The encoder
/// passes every scalar value of that type to ``encode(_:context:)``; the
/// decoder passes every compressed value of that type to
/// ``decode(_:context:)``. Registry-dictionary lookups for the same type run
/// first, as the editor's draft requires.
///
/// The processor verifies each encoded value by decoding it again with the
/// complete decode path, so a codec whose output is not invertible, or that
/// collides with a type table, is rejected with
/// ``CBORLDErrorCode/codecNotInvertible`` instead of producing bytes that
/// decode differently.
public protocol CBORLDTypedValueCodec: Sendable {
  var identifier: CBORLDCodecIdentifier { get }

  /// Returns the compressed representation, or `nil` to carry the value
  /// through unchanged.
  func encode(_ value: JSONValue, context: CBORLDCodecContext) throws -> CBORLDDataItem?

  /// Returns the restored value, or `nil` when `item` is not an encoding this
  /// codec produced and should be restored by the default rules.
  func decode(_ item: CBORLDDataItem, context: CBORLDCodecContext) throws -> JSONValue?
}

// MARK: - Registry entries

/// Resolves a CBOR-LD registry entry identifier to its complete entry.
public typealias CBORLDRegistryEntryLoader =
  @Sendable (UInt64) async throws -> CBORLDRegistryEntry?

/// A complete CBOR-LD Registry Entry: its identifier, use case, processing
/// model, registry dictionaries, and provisional status.
///
/// Entry `0` ("Uncompressed CBOR-LD") and entry `1` ("Compressed CBOR-LD") are
/// fixed by the registry and are built in; they cannot declare tables or a
/// processing model.
public struct CBORLDRegistryEntry: Sendable, Hashable, Codable {
  public let id: UInt64
  /// The kind of CBOR-LD payload the entry is registered for.
  public let useCase: String?
  /// Provisional entries may change or be removed from the registry.
  public let provisional: Bool
  /// The declared processing model. `nil` means the member is absent and the
  /// default processing model applies.
  public let processingModel: CBORLDProcessingModel?
  /// Registry dictionaries keyed by type table type (`context`, `url`,
  /// `none`, or a JSON-LD type IRI).
  public let typeTables: CBORLDTypeTable
  /// Whether the entry requires an application-supplied type table that is
  /// not globally defined (the draft's `"callerProvidedTable"` marker).
  public let requiresCallerProvidedTypeTable: Bool

  public init(
    id: UInt64,
    useCase: String? = nil,
    provisional: Bool = false,
    processingModel: CBORLDProcessingModel? = nil,
    typeTables: CBORLDTypeTable = [:],
    requiresCallerProvidedTypeTable: Bool = false
  ) {
    self.id = id
    self.useCase = useCase
    self.provisional = provisional
    self.processingModel = processingModel
    self.typeTables = typeTables
    self.requiresCallerProvidedTypeTable = requiresCallerProvidedTypeTable
  }

  /// The model used for conversion. Entry `0` is always uncompressed.
  public var effectiveProcessingModel: CBORLDProcessingModel {
    if id == 0 { return .uncompressed }
    return processingModel ?? .default
  }

  /// Registry entry `0`: the plain CBOR encoding of the document.
  public static let uncompressed = Self(id: 0, useCase: "Uncompressed CBOR-LD")

  /// Registry entry `1`: the default processing model without tables.
  public static let compressed = Self(id: 1, useCase: "Compressed CBOR-LD")

  /// Validates identifiers, reserved entries, tables, and the model's shape.
  public func validate() throws {
    guard id <= CBORLDConstants.maximumSafeInteger else {
      throw CBORLDError(
        code: .invalidRegistryEntry,
        message: "Registry entry \(id) exceeds the CBOR-LD safe-integer limit.")
    }
    if id <= 1 {
      guard processingModel == nil,
        typeTables.values.allSatisfy(\.isEmpty),
        !requiresCallerProvidedTypeTable
      else {
        throw CBORLDError(
          code: .invalidRegistryEntry,
          message:
            "Registry entries 0 and 1 are fixed by the registry and cannot declare tables or a processing model."
        )
      }
    }
    try processingModel?.validate()
    try CBORLDTypeTables.validate(typeTables, errorCode: .invalidRegistryEntry)
  }

  private enum CodingKeys: String, CodingKey {
    case id
    case useCase
    case provisional
    case processingModel
    case typeTables
    // Aliases used by the json-ld/cborld-registry repository's table files.
    case domain
    case compressionTable
  }

  private enum TableCodingKeys: String, CodingKey {
    case type
    case table
  }

  private static let callerProvidedTableMarker = "callerProvidedTable"

  /// Decodes the draft's member names. The registry repository's `domain`
  /// and `compressionTable` spellings are accepted as aliases, so a table
  /// file converted from YAML to JSON decodes directly. Table identifiers are
  /// the keys of each `table` object, as in the registry files.
  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    id = try container.decode(UInt64.self, forKey: .id)
    useCase =
      try container.decodeIfPresent(String.self, forKey: .useCase)
      ?? container.decodeIfPresent(String.self, forKey: .domain)
    provisional = try container.decodeIfPresent(Bool.self, forKey: .provisional) ?? false
    processingModel = try container.decodeIfPresent(
      CBORLDProcessingModel.self, forKey: .processingModel)

    let tablesKey: CodingKeys? =
      container.contains(.typeTables)
      ? .typeTables : (container.contains(.compressionTable) ? .compressionTable : nil)
    var tables: CBORLDTypeTable = [:]
    var callerProvided = false
    if let tablesKey, try !container.decodeNil(forKey: tablesKey) {
      var elements = try container.nestedUnkeyedContainer(forKey: tablesKey)
      while !elements.isAtEnd {
        if let marker = try? elements.decode(String.self) {
          guard marker == Self.callerProvidedTableMarker else {
            throw DecodingError.dataCorruptedError(
              in: elements,
              debugDescription: "Unknown type table marker \"\(marker)\".")
          }
          callerProvided = true
          continue
        }
        let element = try elements.nestedContainer(keyedBy: TableCodingKeys.self)
        let type = try element.decode(String.self, forKey: .type)
        let rawTable = try element.decode([String: JSONValue].self, forKey: .table)
        guard tables[type] == nil else {
          throw DecodingError.dataCorruptedError(
            forKey: .type, in: element,
            debugDescription: "Type table \"\(type)\" is declared more than once.")
        }
        var table: CBORLDValueTable = [:]
        for (rawID, value) in rawTable {
          guard let identifier = UInt64(rawID) else {
            throw DecodingError.dataCorruptedError(
              forKey: .table, in: element,
              debugDescription: "Type table identifier \"\(rawID)\" is not an unsigned integer.")
          }
          guard table.updateValue(identifier, forKey: value) == nil else {
            throw DecodingError.dataCorruptedError(
              forKey: .table, in: element,
              debugDescription: "Type table \"\(type)\" maps one value to several identifiers.")
          }
        }
        tables[type] = table
      }
    }
    typeTables = tables
    requiresCallerProvidedTypeTable = callerProvided
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(id, forKey: .id)
    try container.encodeIfPresent(useCase, forKey: .useCase)
    try container.encode(provisional, forKey: .provisional)
    try container.encodeIfPresent(processingModel, forKey: .processingModel)
    var elements = container.nestedUnkeyedContainer(forKey: .typeTables)
    for type in typeTables.keys.sorted() {
      guard let table = typeTables[type] else { continue }
      var element = elements.nestedContainer(keyedBy: TableCodingKeys.self)
      try element.encode(type, forKey: .type)
      var rawTable: [String: JSONValue] = [:]
      for (value, identifier) in table { rawTable[String(identifier)] = value }
      try element.encode(rawTable, forKey: .table)
    }
    if requiresCallerProvidedTypeTable {
      try elements.encode(Self.callerProvidedTableMarker)
    }
  }
}

extension CBORLDDocumentDictionary {
  /// The complete registry entry this dictionary configures.
  public var registryEntry: CBORLDRegistryEntry {
    CBORLDRegistryEntry(
      id: code,
      useCase: profileName,
      provisional: provisional,
      processingModel: processingModel,
      typeTables: code <= 1 ? [:] : typeTable)
  }
}

// MARK: - Resolution

/// Type-table checks shared by dictionaries, registry entries, and loaders.
enum CBORLDTypeTables {
  static let unsupportedLiteralTypes = [
    "http://www.w3.org/2001/XMLSchema#integer",
    "http://www.w3.org/2001/XMLSchema#double",
    "http://www.w3.org/2001/XMLSchema#boolean",
  ]

  static func validate(_ table: CBORLDTypeTable, errorCode: CBORLDErrorCode) throws {
    if let type = unsupportedLiteralTypes.first(where: { table[$0] != nil }) {
      throw CBORLDError(
        code: .unsupportedLiteralType,
        message: "Type table must not contain unsupported literal type \"\(type)\".")
    }
    for type in table.keys.sorted() {
      guard let values = table[type] else { continue }
      var identifiers = Set<UInt64>()
      for identifier in values.values {
        guard identifier <= CBORLDConstants.maximumSafeInteger else {
          throw CBORLDError(
            code: errorCode,
            message: "Identifier \(identifier) in \"\(type)\" exceeds the safe-integer limit.")
        }
        guard identifiers.insert(identifier).inserted else {
          throw CBORLDError(
            code: .invalidTypeTable,
            message: "Type table \"\(type)\" contains duplicate identifier \(identifier).")
        }
      }
    }
  }

  /// Adds an application-supplied table to a registry entry's own tables.
  /// A caller-provided table may add types but may not replace a type the
  /// registry already defines, because that would silently change the
  /// meaning of registered identifiers.
  static func merging(
    _ registered: CBORLDTypeTable,
    callerProvided: CBORLDTypeTable
  ) throws -> CBORLDTypeTable {
    var result = registered
    for (type, table) in callerProvided where !table.isEmpty {
      if let existing = registered[type], !existing.isEmpty {
        throw CBORLDError(
          code: .invalidTypeTable,
          message: "A caller-provided table cannot replace the registered \"\(type)\" table.")
      }
      result[type] = table
    }
    return result
  }
}

/// A registry entry resolved for one format and ready to prepare a codec.
struct ResolvedRegistryEntry: Sendable {
  var format: CBORLDFormat
  var registryEntryID: UInt64?
  var processingModel: CBORLDProcessingModel
  /// Normalized so that `context`, `url`, and `none` are always present.
  var typeTable: CBORLDTypeTable
  var provisional: Bool

  var isLegacySingleton: Bool { format == .legacySingleton }

  /// Whether the payload differs from the plain CBOR encoding of the document.
  var performsConversion: Bool {
    processingModel.semanticCompression || !processingModel.codecs.isEmpty
      || typeTable.values.contains { !$0.isEmpty }
  }

  static func uncompressed(format: CBORLDFormat, registryEntryID: UInt64?) -> Self {
    .init(
      format: format,
      registryEntryID: registryEntryID,
      processingModel: .uncompressed,
      typeTable: CBORLDConstants.normalized(nil),
      provisional: false)
  }

  static func legacySingleton(applicationContextMap: [String: UInt64]?) -> Self {
    .init(
      format: .legacySingleton,
      registryEntryID: nil,
      processingModel: .default,
      typeTable: CBORLD.legacyTypeTable(applicationContextMap: applicationContextMap),
      provisional: false)
  }

  /// Resolves a registry entry for the 1.0 or legacy-range envelope.
  ///
  /// When encoding, a caller-provided table for an entry that does not
  /// require one is a configuration error. When decoding, the document
  /// selects the entry, so an unused caller-provided table is ignored.
  static func resolve(
    format: CBORLDFormat,
    registryEntryID id: UInt64,
    registryEntryLoader: CBORLDRegistryEntryLoader?,
    typeTableLoader: CBORLDTypeTableLoader?,
    callerProvidedTypeTable: CBORLDTypeTable?,
    allowsProvisionalEntries: Bool,
    forEncoding: Bool
  ) async throws -> Self {
    guard registryEntryLoader == nil || typeTableLoader == nil else {
      throw CBORLDError.invalidInput(
        "Configure either registryEntryLoader or typeTableLoader, not both.")
    }
    let entry: CBORLDRegistryEntry
    if id == 0 {
      entry = .uncompressed
    } else if id == 1 {
      entry = .compressed
    } else if let registryEntryLoader {
      guard let loaded = try await registryEntryLoader(id) else {
        throw noEntry(id)
      }
      guard loaded.id == id else {
        throw CBORLDError(
          code: .invalidRegistryEntry,
          message: "Registry entry loader returned entry \(loaded.id) for identifier \(id).")
      }
      entry = loaded
    } else if let typeTableLoader {
      guard let table = try await typeTableLoader(id) else { throw noEntry(id) }
      entry = CBORLDRegistryEntry(id: id, typeTables: table)
    } else if callerProvidedTypeTable != nil {
      entry = CBORLDRegistryEntry(id: id, requiresCallerProvidedTypeTable: true)
    } else {
      throw noEntry(id)
    }
    return try make(
      entry: entry,
      format: format,
      callerProvidedTypeTable: callerProvidedTypeTable,
      allowsProvisionalEntries: allowsProvisionalEntries,
      forEncoding: forEncoding)
  }

  /// Validates a known entry and combines it with any caller-provided table.
  static func make(
    entry: CBORLDRegistryEntry,
    format: CBORLDFormat,
    callerProvidedTypeTable: CBORLDTypeTable? = nil,
    allowsProvisionalEntries: Bool = true,
    forEncoding: Bool
  ) throws -> Self {
    try entry.validate()
    guard allowsProvisionalEntries || !entry.provisional else {
      throw CBORLDError(
        code: .provisionalRegistryEntry,
        message:
          "Registry entry \(entry.id) is provisional and provisional entries are disabled.")
    }
    if entry.id == 0 {
      if forEncoding, callerProvidedTypeTable != nil {
        throw CBORLDError.invalidInput(
          "Registry entry 0 is uncompressed and cannot use a caller-provided type table.")
      }
      return .uncompressed(format: format, registryEntryID: 0)
    }

    var tables = entry.typeTables
    if entry.requiresCallerProvidedTypeTable {
      guard let callerProvidedTypeTable else {
        throw CBORLDError(
          code: .noTypeTable,
          message: "Registry entry \(entry.id) requires a caller-provided type table.")
      }
      try CBORLDTypeTables.validate(callerProvidedTypeTable, errorCode: .invalidTypeTable)
      tables = try CBORLDTypeTables.merging(tables, callerProvided: callerProvidedTypeTable)
    } else if forEncoding, callerProvidedTypeTable != nil {
      throw CBORLDError.invalidInput(
        "Registry entry \(entry.id) does not accept a caller-provided type table.")
    }
    return .init(
      format: format,
      registryEntryID: entry.id,
      processingModel: entry.effectiveProcessingModel,
      typeTable: CBORLDConstants.normalized(tables),
      provisional: entry.provisional)
  }

  private static func noEntry(_ id: UInt64) -> CBORLDError {
    CBORLDError(
      code: .noTypeTable,
      message: "Type table not found for registryEntryID \"\(id)\".")
  }
}
