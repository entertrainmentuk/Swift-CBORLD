import Foundation

struct TermInfo {
  var term: String
  var key: CBORValue
  var plural: Bool
  var definition: TermDefinition
}

/// A typed-value codec bound to one type by the active processing model.
enum ValueCodec: Sendable {
  case url
  case xsdDate
  case xsdDateTime
  case multibase
  case custom(any CBORLDTypedValueCodec)
}

/// Immutable, validated state shared by every conversion that uses one
/// registry entry: tables, their reverse maps, and resolved codec bindings.
struct SemanticCodecPreparation: Sendable {
  let typeTable: CBORLDTypeTable
  let reverseTypeTable: [String: [UInt64: JSONValue]]
  let legacy: Bool
  let tableTypesEncodedAsBytes: Set<String>
  let semanticCompression: Bool
  let codecs: [String: ValueCodec]
  let registryEntryID: UInt64?
  let provisional: Bool
  /// `false` when the payload is exactly the plain CBOR of the document.
  let performsConversion: Bool

  init(entry: ResolvedRegistryEntry, codecs userCodecs: [any CBORLDTypedValueCodec]) throws {
    self.typeTable = entry.typeTable
    self.legacy = entry.isLegacySingleton
    self.tableTypesEncodedAsBytes =
      entry.isLegacySingleton
      ? CBORLDConstants.legacyTableTypesEncodedAsBytes
      : CBORLDConstants.tableTypesEncodedAsBytes
    var reverse: [String: [UInt64: JSONValue]] = [:]
    for (type, table) in entry.typeTable {
      reverse[type] = try CBORLDConstants.reversed(table)
    }
    self.reverseTypeTable = reverse
    self.semanticCompression = entry.processingModel.semanticCompression
    self.registryEntryID = entry.registryEntryID
    self.provisional = entry.provisional
    self.performsConversion = entry.performsConversion

    let model = entry.processingModel
    try model.validate()
    var suppliedCodecs: [CBORLDCodecIdentifier: any CBORLDTypedValueCodec] = [:]
    for codec in userCodecs {
      guard !codec.identifier.isBuiltIn else {
        throw CBORLDError(
          code: .invalidProcessingModel,
          message: "A user codec cannot replace the built-in \"\(codec.identifier)\" codec.")
      }
      guard !codec.identifier.rawValue.isEmpty else {
        throw CBORLDError(
          code: .invalidProcessingModel,
          message: "A user codec must have a non-empty identifier.")
      }
      guard suppliedCodecs.updateValue(codec, forKey: codec.identifier) == nil else {
        throw CBORLDError(
          code: .invalidProcessingModel,
          message: "More than one user codec has the identifier \"\(codec.identifier)\".")
      }
    }
    var resolved: [String: ValueCodec] = [:]
    for (type, identifier) in model.codecs {
      switch identifier {
      case .url: resolved[type] = .url
      case .xsdDate: resolved[type] = .xsdDate
      case .xsdDateTime: resolved[type] = .xsdDateTime
      case .multibase: resolved[type] = .multibase
      default:
        guard let codec = suppliedCodecs[identifier] else {
          throw CBORLDError(
            code: .unknownCodec,
            message:
              "The processing model binds \"\(type)\" to codec \"\(identifier)\", which is neither built in nor supplied."
          )
        }
        resolved[type] = .custom(codec)
      }
    }
    self.codecs = resolved
  }
}

final class SemanticCodec {
  let typeTable: CBORLDTypeTable
  let reverseTypeTable: [String: [UInt64: JSONValue]]
  let contextLoader: ContextLoader
  let legacy: Bool
  let tableTypesEncodedAsBytes: Set<String>
  let semanticCompression: Bool
  let codecs: [String: ValueCodec]
  let registryEntryID: UInt64?
  let limits: CBORLDEncodingLimits
  /// The CBOR depth of the payload root inside its envelope.
  let payloadDepth: Int

  init(
    preparation: SemanticCodecPreparation,
    resolver: CBORLDContextDocumentLoader?,
    contextPolicy: CBORLDContextLoadingPolicy = .init(),
    limits: CBORLDEncodingLimits = .unbounded,
    payloadDepth: Int = 0
  ) {
    self.typeTable = preparation.typeTable
    self.reverseTypeTable = preparation.reverseTypeTable
    self.legacy = preparation.legacy
    self.tableTypesEncodedAsBytes = preparation.tableTypesEncodedAsBytes
    self.semanticCompression = preparation.semanticCompression
    self.codecs = preparation.codecs
    self.registryEntryID = preparation.registryEntryID
    self.limits = limits
    self.payloadDepth = payloadDepth
    self.contextLoader = ContextLoader(
      resolver: resolver,
      policy: contextPolicy,
      generatesTermIdentifiers: preparation.semanticCompression)
  }

  func compress(_ input: JSONValue) async throws -> CBORValue {
    let initial = ActiveContext(contextLoader: contextLoader)
    switch input {
    case .array(let values):
      try CBOREncoder.checkContainer(values.count, limits: limits)
      return .array(
        try await asyncMap(values) { value in
          guard case .object(let object) = value else {
            return try CBORValue.fromJSON(value, depth: self.payloadDepth + 1, limits: self.limits)
          }
          return try await self.compressObject(
            object, activeContext: initial, depth: self.payloadDepth + 1)
        })
    case .object(let object):
      return try await compressObject(object, activeContext: initial, depth: payloadDepth)
    default:
      return try CBORValue.fromJSON(input, depth: payloadDepth, limits: limits)
    }
  }

  func decompress(_ input: CBORValue) async throws -> JSONValue {
    let initial = ActiveContext(contextLoader: contextLoader)
    switch input {
    case .array(let values):
      return .array(
        try await asyncMap(values) { value in
          guard case .map(let entries) = value else { return try value.toJSON() }
          return try await self.decompressObject(entries, activeContext: initial)
        })
    case .map(let entries):
      return try await decompressObject(entries, activeContext: initial)
    default:
      return try input.toJSON()
    }
  }

  private func compressObject(
    _ input: [String: JSONValue],
    activeContext: ActiveContext,
    depth: Int
  ) async throws -> CBORValue {
    guard depth <= limits.maximumNestingDepth else { throw CBOREncoder.nestingLimit(limits) }
    try CBOREncoder.checkContainer(input.count, limits: limits)
    var active = try await activeContext.applyingEmbeddedContexts(to: input)
    var entries: [CBORMapEntry] = []

    if let context = input["@context"] {
      let values = context.arrayValue ?? [context]
      let valueDepth = depth + (context.arrayValue == nil ? 1 : 2)
      let encoded = try values.map { try encodeContext($0, depth: valueDepth) }
      let key: CBORValue =
        semanticCompression ? .unsigned(context.arrayValue == nil ? 0 : 1) : .string("@context")
      entries.append(
        CBORMapEntry(
          key: key,
          value: context.arrayValue == nil ? encoded[0] : .array(encoded)))
    }

    active = try await active.applyingTypeScopedContexts(
      objectTypes(in: input, activeContext: active))

    for (index, term) in input.keys.sorted().enumerated() where term != "@context" {
      try CBOREncoder.checkCancellation(at: index, limits: limits)
      guard let value = input[term] else { continue }
      let values = value.arrayValue ?? [value]
      let plural = value.arrayValue != nil
      let termInfo = TermInfo(
        term: term,
        key: contextLoader.id(for: term, plural: plural),
        plural: plural,
        definition: active.definition(for: term))
      let valueContext = try await active.applyingPropertyScopedContext(for: term)
      let valueDepth = depth + (plural ? 2 : 1)
      if plural { try CBOREncoder.checkContainer(values.count, limits: limits) }
      let converted = try await asyncMap(values) { value in
        try await self.compressValue(
          value,
          termType: termInfo.definition.type,
          termInfo: termInfo,
          activeContext: valueContext,
          depth: valueDepth)
      }
      let encodedValue: CBORValue
      if !plural {
        encodedValue = converted[0]
      } else if semanticCompression {
        encodedValue = .array(converted)
      } else {
        encodedValue = try await unambiguousPluralValue(
          original: values,
          converted: converted,
          termInfo: termInfo,
          activeContext: valueContext,
          depth: valueDepth)
      }
      entries.append(CBORMapEntry(key: termInfo.key, value: encodedValue))
    }
    return .map(entries)
  }

  private func compressValue(
    _ value: JSONValue,
    termType: String?,
    termInfo: TermInfo,
    activeContext: ActiveContext,
    depth: Int,
    usesCodecs: Bool = true
  ) async throws -> CBORValue {
    guard depth <= limits.maximumNestingDepth else { throw CBOREncoder.nestingLimit(limits) }
    if value == .null { return .null }
    switch value {
    case .array(let values):
      try CBOREncoder.checkContainer(values.count, limits: limits)
      return .array(
        try await asyncMap(values) {
          try await self.compressValue(
            $0,
            termType: termType,
            termInfo: termInfo,
            activeContext: activeContext,
            depth: depth + 1,
            usesCodecs: usesCodecs)
        })
    case .object(let object):
      return try await compressObject(object, activeContext: activeContext, depth: depth)
    default:
      return try encodeScalar(
        value, termType: termType, termInfo: termInfo, usesCodecs: usesCodecs)
    }
  }

  /// Without semantic compression a plural value has no plural key marker, so
  /// the decoder first offers the whole array to the type's codec. This keeps
  /// that from succeeding: when the codec could claim the converted array, the
  /// elements are carried without codecs instead, and a value that remains
  /// ambiguous is refused rather than encoded into bytes that decode
  /// differently.
  private func unambiguousPluralValue(
    original: [JSONValue],
    converted: [CBORValue],
    termInfo: TermInfo,
    activeContext: ActiveContext,
    depth: Int
  ) async throws -> CBORValue {
    let termType = termInfo.definition.type
    let candidate = CBORValue.array(converted)
    if !claimsAsSingleValue(candidate, termType: termType, termInfo: termInfo) {
      return candidate
    }
    var fallback: [CBORValue] = []
    fallback.reserveCapacity(original.count)
    for value in original {
      fallback.append(
        try await compressValue(
          value,
          termType: termType,
          termInfo: termInfo,
          activeContext: activeContext,
          depth: depth,
          usesCodecs: false))
    }
    let fallbackValue = CBORValue.array(fallback)
    guard !claimsAsSingleValue(fallbackValue, termType: termType, termInfo: termInfo),
      zip(original, fallback).allSatisfy({
        restoresExactly($0, from: $1, termType: termType, termInfo: termInfo)
      })
    else {
      throw CBORLDError(
        code: .ambiguousValue,
        message:
          "The values of term \"\(termInfo.term)\" cannot be represented unambiguously without semantic compression."
      )
    }
    return fallbackValue
  }

  /// Whether the decoder would read `value` as one compressed scalar. A value
  /// the codec rejects with an error counts as claimed, because it would not
  /// decode element by element either.
  private func claimsAsSingleValue(
    _ value: CBORValue,
    termType: String?,
    termInfo: TermInfo
  ) -> Bool {
    do {
      return try decodeScalar(value, termType: termType, termInfo: termInfo) != nil
    } catch {
      return true
    }
  }

  /// Checks the decoder's element-wise path for a codec-free plural element.
  /// Objects always take the object path and are restored by construction.
  private func restoresExactly(
    _ original: JSONValue,
    from encoded: CBORValue,
    termType: String?,
    termInfo: TermInfo
  ) -> Bool {
    switch (original, encoded) {
    case (_, .map), (.null, .null):
      return true
    case (.array(let values), .array(let elements)):
      return values.count == elements.count
        && !claimsAsSingleValue(encoded, termType: termType, termInfo: termInfo)
        && zip(values, elements).allSatisfy {
          restoresExactly($0, from: $1, termType: termType, termInfo: termInfo)
        }
    default:
      guard
        let restored = try? decodeScalar(encoded, termType: termType, termInfo: termInfo)
          ?? encoded.toJSON()
      else { return false }
      return restored == original
    }
  }

  private func decompressObject(
    _ input: [CBORMapEntry],
    activeContext: ActiveContext
  ) async throws -> JSONValue {
    var output: [String: JSONValue] = [:]
    if semanticCompression {
      let singularContexts = input.values(forUnsignedKey: 0)
      let pluralContexts = input.values(forUnsignedKey: 1)
      guard singularContexts.count <= 1, pluralContexts.count <= 1 else {
        throw CBORLDError(
          code: .invalidEncodedContext,
          message: "The CBOR-LD input contains a duplicate encoded context key.")
      }
      let singularContext = singularContexts.first
      let pluralContext = pluralContexts.first
      if singularContext != nil, pluralContext != nil {
        throw CBORLDError(
          code: .invalidEncodedContext,
          message: "Both singular and plural context IDs were found in the CBOR-LD input.")
      }
      if let singularContext {
        output["@context"] = try decodeContext(singularContext)
      }
      if let pluralContext {
        guard case .array(let contexts) = pluralContext else {
          throw CBORLDError(
            code: .invalidEncodedContext,
            message: "Encoded plural context value must be an array.")
        }
        output["@context"] = .array(try contexts.map(decodeContext))
      }
    } else {
      let contexts = input.values(forStringKey: "@context")
      guard contexts.count <= 1 else {
        throw CBORLDError(
          code: .invalidEncodedContext,
          message: "The CBOR-LD input contains a duplicate @context key.")
      }
      if let context = contexts.first {
        if case .array(let values) = context {
          output["@context"] = .array(try values.map(decodeContext))
        } else {
          output["@context"] = try decodeContext(context)
        }
      }
    }

    var active = try await activeContext.applyingEmbeddedContexts(to: output)
    active = try await active.applyingTypeScopedContexts(
      try objectTypes(in: input, activeContext: active))

    var termEntries: [(TermInfo, CBORValue)] = []
    var seenTerms = Set<String>()
    for entry in input where !isEncodedContextKey(entry.key) {
      let resolved = try contextLoader.term(for: entry.key)
      guard seenTerms.insert(resolved.term).inserted else {
        throw CBORLDError(
          code: .invalidInput,
          message: "The CBOR-LD input contains duplicate term \"\(resolved.term)\".")
      }
      termEntries.append(
        (
          TermInfo(
            term: resolved.term,
            key: entry.key,
            plural: resolved.plural,
            definition: active.definition(for: resolved.term)), entry.value
        ))
    }
    termEntries.sort { $0.0.term < $1.0.term }

    for (termInfo, value) in termEntries {
      let values: [CBORValue]
      if termInfo.plural {
        guard case .array(let array) = value else {
          throw CBORLDError(
            code: .invalidInput,
            message: "Plural term \"\(termInfo.term)\" must contain a CBOR array.")
        }
        values = array
      } else {
        values = [value]
      }
      let valueContext = try await active.applyingPropertyScopedContext(for: termInfo.term)
      let converted = try await asyncMap(values) { value in
        try await self.decompressValue(
          value,
          termType: termInfo.definition.type,
          termInfo: termInfo,
          activeContext: valueContext)
      }
      output[termInfo.term] = termInfo.plural ? .array(converted) : converted[0]
    }
    return .object(output)
  }

  private func isEncodedContextKey(_ key: CBORValue) -> Bool {
    if semanticCompression { return key.isUnsigned(0) || key.isUnsigned(1) }
    return key.stringValue == "@context"
  }

  private func decompressValue(
    _ value: CBORValue,
    termType: String?,
    termInfo: TermInfo,
    activeContext: ActiveContext
  ) async throws -> JSONValue {
    if case .null = value { return .null }
    if let scalar = try decodeScalar(value, termType: termType, termInfo: termInfo) {
      return scalar
    }
    switch value {
    case .array(let values):
      return .array(
        try await asyncMap(values) {
          try await self.decompressValue(
            $0,
            termType: termType,
            termInfo: termInfo,
            activeContext: activeContext)
        })
    case .map(let entries):
      return try await decompressObject(entries, activeContext: activeContext)
    default:
      return try value.toJSON()
    }
  }

  private func objectTypes(
    in input: [String: JSONValue],
    activeContext: ActiveContext
  ) -> Set<String> {
    var result = Set<String>()
    for term in activeContext.typeTerms {
      guard let value = input[term] else { continue }
      for type in value.arrayValue ?? [value] {
        if let type = type.stringValue { result.insert(type) }
      }
    }
    return result
  }

  private func objectTypes(
    in input: [CBORMapEntry],
    activeContext: ActiveContext
  ) throws -> Set<String> {
    var result = Set<String>()
    for typeTerm in activeContext.typeTerms {
      let termInfo = TermInfo(
        term: typeTerm,
        key: contextLoader.id(for: typeTerm),
        plural: false,
        definition: activeContext.definition(for: typeTerm))
      let encodedTypes: [CBORValue]
      if semanticCompression {
        guard let baseID = termInfo.key.unsignedValue,
          let value = input.firstValue(forUnsignedKey: baseID)
            ?? input.firstValue(forUnsignedKey: baseID + 1)
        else { continue }
        // Matches the reference processor, which inspects every element of an
        // array value.
        encodedTypes = value.arrayValue ?? [value]
      } else {
        guard let value = input.first(where: { $0.key.stringValue == typeTerm })?.value else {
          continue
        }
        // String keys carry no plural marker; a compressed single type such
        // as `[2, "example.com/Type"]` must not be split into elements.
        encodedTypes =
          claimsAsSingleValue(value, termType: "@vocab", termInfo: termInfo)
          ? [value] : (value.arrayValue ?? [value])
      }
      for encoded in encodedTypes {
        if let decoded = try decodeScalar(
          encoded, termType: "@vocab", termInfo: termInfo),
          let type = decoded.stringValue
        {
          result.insert(type)
        } else if let type = encoded.stringValue {
          result.insert(type)
        }
      }
    }
    return result
  }

  private func encodeContext(_ value: JSONValue, depth: Int) throws -> CBORValue {
    if case .string(let context) = value,
      let id = typeTable["context"]?[.string(context)]
    {
      return .unsigned(id)
    }
    return try CBORValue.fromJSON(value, depth: depth, limits: limits)
  }

  private func decodeContext(_ value: CBORValue) throws -> JSONValue {
    if case .unsigned(let id) = value {
      guard let context = reverseTypeTable["context"]?[id] else {
        throw CBORLDError(
          code: .undefinedCompressedContext,
          message: "Undefined compressed context \"\(id)\".")
      }
      return context
    }
    return try value.toJSON()
  }

  private func tableType(termInfo: TermInfo, termType: String?) -> String {
    if termInfo.term == "@id" || termInfo.definition.id == "@id"
      || termInfo.term == "@type" || termInfo.definition.id == "@type"
      || termType == "@id" || termType == "@vocab"
    {
      return "url"
    }
    return termType ?? "none"
  }

  private func encodeScalar(
    _ value: JSONValue,
    termType: String?,
    termInfo: TermInfo,
    usesCodecs: Bool = true
  ) throws -> CBORValue {
    let tableType = tableType(termInfo: termInfo, termType: termType)
    let codec = usesCodecs ? codecs[tableType] : nil
    if case .url = codec, value.stringValue == nil {
      throw CBORLDError(
        code: .unsupportedJSONType,
        message: "Invalid value type for URL; expected a string.")
    }

    if let subtable = typeTable[tableType] {
      if let id = subtable[value] {
        return tableTypesEncodedAsBytes.contains(tableType)
          ? .bytes(try bytes(fromUnsigned: id))
          : .unsigned(id)
      }
      if tableType != "none", let integer = value.integralValue {
        return .bytes(try bytes(fromSigned: integer))
      }
    }

    if let codec,
      let encoded = try encode(
        value, with: codec, tableType: tableType, termType: termType, termInfo: termInfo)
    {
      return encoded
    }
    return try CBORValue.fromJSON(value)
  }

  private func encode(
    _ value: JSONValue,
    with codec: ValueCodec,
    tableType: String,
    termType: String?,
    termInfo: TermInfo
  ) throws -> CBORValue? {
    switch codec {
    case .url:
      guard let string = value.stringValue else { return nil }
      return try encodeURL(string)
    case .multibase:
      return try encodeMultibase(value)
    case .xsdDate:
      return DateCodec.encodeDate(value)
    case .xsdDateTime:
      return DateCodec.encodeDateTime(value)
    case .custom(let codec):
      let context = CBORLDCodecContext(
        type: tableType, term: termInfo.term, registryEntryID: registryEntryID)
      guard let item = try codec.encode(value, context: context) else { return nil }
      let encoded = item.cborValue
      // Verify through the complete decode path, including type-table
      // lookups, so a codec cannot emit bytes that decode differently.
      let restored = try? decodeScalar(encoded, termType: termType, termInfo: termInfo)
      guard let restored, restored == value else {
        throw CBORLDError(
          code: .codecNotInvertible,
          message:
            "Codec \"\(codec.identifier)\" encoded a value of term \"\(termInfo.term)\" that does not decode to the original value."
        )
      }
      return encoded
    }
  }

  private func decodeScalar(
    _ value: CBORValue,
    termType: String?,
    termInfo: TermInfo
  ) throws -> JSONValue? {
    let tableType = tableType(termInfo: termInfo, termType: termType)
    if let subtable = reverseTypeTable[tableType] {
      let useBytes = tableTypesEncodedAsBytes.contains(tableType)
      var useTable = false
      var id: UInt64?
      if let bytes = value.bytesValue, useBytes {
        useTable = true
        id = try unsigned(from: bytes)
      } else if !useBytes, case .unsigned(let value) = value {
        useTable = true
        id = value
      } else if !useBytes, case .negative = value {
        useTable = true
      }

      if useTable {
        let decoded = id.flatMap { subtable[$0] }
        let legacyTermCollision =
          legacy && tableType == "url"
          && id.map(contextLoader.hasTerm(id:)) == true
        guard let decoded else {
          if !legacyTermCollision {
            throw CBORLDError(
              code: .unknownCompressedValue,
              message: "Compressed value \"\(id.map(String.init) ?? "negative")\" not found.")
          }
          return try decodeURL(value).map(JSONValue.string)
        }
        return decoded
      }
      if let bytes = value.bytesValue, tableType != "none" {
        return .integer(try signed(from: bytes))
      }
    }

    if let codec = codecs[tableType],
      let decoded = try decode(value, with: codec, tableType: tableType, termInfo: termInfo)
    {
      return decoded
    }

    switch value {
    case .array, .map: return nil
    default: return try value.toJSON()
    }
  }

  private func decode(
    _ value: CBORValue,
    with codec: ValueCodec,
    tableType: String,
    termInfo: TermInfo
  ) throws -> JSONValue? {
    switch codec {
    case .url:
      return try decodeURL(value).map(JSONValue.string)
    case .multibase:
      return try decodeMultibase(value).map(JSONValue.string)
    case .xsdDate:
      return DateCodec.decodeDate(value).map(JSONValue.string)
    case .xsdDateTime:
      return DateCodec.decodeDateTime(value).map(JSONValue.string)
    case .custom(let codec):
      return try codec.decode(
        CBORLDDataItem(value),
        context: CBORLDCodecContext(
          type: tableType, term: termInfo.term, registryEntryID: registryEntryID))
    }
  }

  private func encodeURL(_ value: String) throws -> CBORValue? {
    let termID = contextLoader.id(for: value)
    if case .unsigned = termID { return termID }

    if value.hasPrefix("https://") {
      return .array([.unsigned(2), .string(String(value.dropFirst(8)))])
    }
    if value.hasPrefix("http://") {
      return .array([.unsigned(1), .string(String(value.dropFirst(7)))])
    }
    if value.hasPrefix("urn:uuid:") {
      let suffix = String(value.dropFirst(9))
      if suffix.lowercased() == suffix {
        guard let bytes = UUIDCodec.bytes(from: suffix) else {
          throw CBORLDError.invalidInput("Invalid UUID URN \"\(value)\".")
        }
        return .array([.unsigned(3), .bytes(bytes)])
      }
      return .array([.unsigned(3), .string(suffix)])
    }
    if value.hasPrefix("data:") { return try encodeDataURL(value) }
    if value.hasPrefix("did:v1:nym:") {
      return try encodeBase58DID(value, prefix: "did:v1:nym:", code: 1024)
    }
    if value.hasPrefix("did:key:") {
      return try encodeBase58DID(value, prefix: "did:key:", code: 1025)
    }
    return nil
  }

  private func decodeURL(_ value: CBORValue) throws -> String? {
    if case .string(let value) = value { return value }
    if case .unsigned = value {
      return try contextLoader.term(for: value).term
    }
    guard case .array(let parts) = value,
      let code = parts.first?.unsignedValue,
      let scheme = CBORLDConstants.urlSchemes.first(where: { $0.value == code })?.key
    else { return nil }

    switch scheme {
    case "http://", "https://":
      guard parts.count == 2, let suffix = parts[1].stringValue else {
        throw unknownCompressedURL(value)
      }
      return scheme + suffix
    case "urn:uuid:":
      guard parts.count == 2 else { throw unknownCompressedURL(value) }
      if let suffix = parts[1].stringValue { return scheme + suffix }
      guard let bytes = parts[1].bytesValue,
        let uuid = UUIDCodec.string(from: bytes)
      else { throw unknownCompressedURL(value) }
      return scheme + uuid
    case "data:":
      if parts.count == 2, let suffix = parts[1].stringValue {
        return scheme + suffix
      }
      if parts.count == 3,
        let mediaType = parts[1].stringValue,
        let bytes = parts[2].bytesValue
      {
        return "data:\(mediaType);base64,\(bytes.base64EncodedString())"
      }
      throw unknownCompressedURL(value)
    case "did:v1:nym:", "did:key:":
      guard (2...3).contains(parts.count) else { throw unknownCompressedURL(value) }
      var result = scheme + (try decodeBase58Component(parts[1]))
      if parts.count == 3 { result += "#" + (try decodeBase58Component(parts[2])) }
      return result
    default:
      throw unknownCompressedURL(value)
    }
  }

  private func encodeBase58DID(
    _ value: String,
    prefix: String,
    code: UInt64
  ) throws -> CBORValue {
    let suffix = String(value.dropFirst(prefix.count))
    let components = suffix.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)
    var result: [CBORValue] = [.unsigned(code)]
    for component in components {
      let component = String(component)
      if component.hasPrefix("z") {
        guard let bytes = Base58.decode(String(component.dropFirst())) else {
          throw CBORLDError.invalidInput("Invalid base58btc value \"\(component)\".")
        }
        result.append(.bytes(bytes))
      } else {
        result.append(.string(component))
      }
    }
    return .array(result)
  }

  private func decodeBase58Component(_ value: CBORValue) throws -> String {
    if let string = value.stringValue { return string }
    if let bytes = value.bytesValue { return "z" + Base58.encode(bytes) }
    throw unknownCompressedURL(value)
  }

  private func encodeDataURL(_ value: String) throws -> CBORValue {
    let remainder = String(value.dropFirst(5))
    if let marker = remainder.range(of: ";base64,"), marker.upperBound <= remainder.endIndex {
      let mediaType = String(remainder[..<marker.lowerBound])
      let encoded = String(remainder[marker.upperBound...])
      if let data = Data(base64Encoded: encoded), data.base64EncodedString() == encoded {
        return .array([.unsigned(4), .string(mediaType), .bytes(data)])
      }
    }
    return .array([.unsigned(4), .string(remainder)])
  }

  private func encodeMultibase(_ value: JSONValue) throws -> CBORValue? {
    guard let value = value.stringValue, let prefix = value.first else { return nil }
    let suffix = String(value.dropFirst())
    let data: Data?
    switch prefix {
    case "z": data = Base58.decode(suffix)
    case "u": data = Data(base64URLEncoded: suffix)
    case "M": data = Data(base64Encoded: suffix)
    default: return nil
    }
    guard let data else {
      throw CBORLDError.invalidInput("Invalid \(prefix)-multibase value.")
    }
    return .bytes(Data([prefix.asciiValue!]) + data)
  }

  private func decodeMultibase(_ value: CBORValue) throws -> String? {
    guard let data = value.bytesValue, let prefix = data.first else { return nil }
    let suffix = data.dropFirst()
    switch prefix {
    case Character("z").asciiValue: return "z" + Base58.encode(Data(suffix))
    case Character("u").asciiValue: return "u" + Data(suffix).base64URLEncodedString()
    case Character("M").asciiValue: return "M" + Data(suffix).base64EncodedString()
    default: return nil
    }
  }

  private func unknownCompressedURL(_ value: CBORValue) -> CBORLDError {
    .init(
      code: .unknownCompressedValue,
      message: "Unknown or malformed compressed URL \"\(value)\".")
  }
}

extension JSONValue {
  fileprivate var integralValue: Int64? {
    switch self {
    case .integer(let value): return value
    case .number(let value)
    where value.isFinite
      && value.rounded(.towardZero) == value
      && value >= Double(Int64.min) && value <= Double(Int64.max):
      return Int64(value)
    default: return nil
    }
  }
}

extension CBORValue {
  fileprivate func isUnsigned(_ expected: UInt64) -> Bool {
    guard case .unsigned(let value) = self else { return false }
    return value == expected
  }
}

extension Array where Element == CBORMapEntry {
  fileprivate func firstValue(forUnsignedKey key: UInt64) -> CBORValue? {
    first { $0.key.isUnsigned(key) }?.value
  }

  fileprivate func values(forUnsignedKey key: UInt64) -> [CBORValue] {
    compactMap { $0.key.isUnsigned(key) ? $0.value : nil }
  }

  fileprivate func values(forStringKey key: String) -> [CBORValue] {
    compactMap { $0.key.stringValue == key ? $0.value : nil }
  }
}

private func asyncMap<T, U>(
  _ values: [T],
  _ transform: (T) async throws -> U
) async throws -> [U] {
  var output: [U] = []
  output.reserveCapacity(values.count)
  for (index, value) in values.enumerated() {
    if index.isMultiple(of: 1_024) { try Task.checkCancellation() }
    output.append(try await transform(value))
  }
  return output
}

private func bytes(fromUnsigned value: UInt64) throws -> Data {
  guard value < CBORLDConstants.maximumSafeInteger else {
    throw CBORLDError(
      code: .compressionValueTooLarge,
      message: "Compression value \"\(value)\" too large.")
  }
  if value < 0xff { return Data([UInt8(value)]) }
  if value < 0xffff { return bigEndianData(UInt16(value)) }
  if value < 0xffff_ffff { return bigEndianData(UInt32(value)) }
  return bigEndianData(value)
}

private func bytes(fromSigned value: Int64) throws -> Data {
  guard value < Int64(CBORLDConstants.maximumSafeInteger) else {
    throw CBORLDError(
      code: .compressionValueTooLarge,
      message: "Compression value \"\(value)\" too large.")
  }
  // Preserve the JavaScript processor's width thresholds and two's-complement
  // conversion behavior for wire compatibility.
  if value < 0x7f { return Data([UInt8(truncatingIfNeeded: value)]) }
  if value < 0x7fff { return bigEndianData(Int16(value)) }
  if value < 0x7fff_ffff { return bigEndianData(Int32(value)) }
  return bigEndianData(value)
}

private func unsigned(from data: Data) throws -> UInt64 {
  switch data.count {
  case 1: return UInt64(data[data.startIndex])
  case 2: return UInt64(try integer(from: data) as UInt16)
  case 4: return UInt64(try integer(from: data) as UInt32)
  default:
    throw CBORLDError(
      code: .unrecognizedBytes,
      message: "Improperly formatted unsigned integer bytes.")
  }
}

private func signed(from data: Data) throws -> Int64 {
  switch data.count {
  case 1: return Int64(Int8(bitPattern: data[data.startIndex]))
  case 2: return Int64(try integer(from: data) as Int16)
  case 4: return Int64(try integer(from: data) as Int32)
  case 8:
    let value: Int64 = try integer(from: data)
    guard value <= Int64(CBORLDConstants.maximumSafeInteger) else {
      throw CBORLDError(
        code: .compressionValueTooLarge,
        message: "Compression value \"\(value)\" too large.")
    }
    return value
  default:
    throw CBORLDError(
      code: .unrecognizedBytes,
      message: "Improperly formatted signed integer bytes.")
  }
}

private func bigEndianData<T: FixedWidthInteger>(_ input: T) -> Data {
  var value = input.bigEndian
  return withUnsafeBytes(of: &value) { Data($0) }
}

private func integer<T: FixedWidthInteger>(from data: Data) throws -> T {
  guard data.count == MemoryLayout<T>.size else {
    throw CBORLDError.invalidInput("Integer byte width does not match its type.")
  }
  var value: T = 0
  for byte in data { value = (value << 8) | T(byte) }
  return value
}

private enum UUIDCodec {
  static func bytes(from string: String) -> Data? {
    let compact = string.replacingOccurrences(of: "-", with: "")
    guard compact.count == 32 else { return nil }
    var output = Data(capacity: 16)
    var index = compact.startIndex
    for _ in 0..<16 {
      let next = compact.index(index, offsetBy: 2)
      guard let byte = UInt8(compact[index..<next], radix: 16) else { return nil }
      output.append(byte)
      index = next
    }
    return output
  }

  static func string(from data: Data) -> String? {
    guard data.count == 16 else { return nil }
    let hex = data.map { String(format: "%02x", $0) }.joined()
    let positions = [8, 12, 16, 20]
    var result = hex
    for position in positions.reversed() {
      let index = result.index(result.startIndex, offsetBy: position)
      result.insert("-", at: index)
    }
    return result
  }
}

private enum Base58 {
  static let alphabet = Array("123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz")
  static let indexes = Dictionary(
    uniqueKeysWithValues:
      alphabet.enumerated().map { ($0.element, $0.offset) })

  static func decode(_ input: String) -> Data? {
    if input.isEmpty { return Data() }
    var bytes = [UInt8](repeating: 0, count: input.count)
    var length = 0
    for character in input {
      guard var carry = indexes[character] else { return nil }
      var i = 0
      for j in stride(from: bytes.count - 1, through: 0, by: -1) where carry != 0 || i < length {
        carry += 58 * Int(bytes[j])
        bytes[j] = UInt8(carry & 0xff)
        carry >>= 8
        i += 1
      }
      guard carry == 0 else { return nil }
      length = i
    }
    let zeros = input.prefix { $0 == "1" }.count
    let start = bytes.count - length
    return Data(repeating: 0, count: zeros) + Data(bytes[start...])
  }

  static func encode(_ input: Data) -> String {
    if input.isEmpty { return "" }
    var digits = [UInt8](repeating: 0, count: input.count * 138 / 100 + 1)
    var length = 0
    for byte in input {
      var carry = Int(byte)
      var i = 0
      for j in stride(from: digits.count - 1, through: 0, by: -1) where carry != 0 || i < length {
        carry += 256 * Int(digits[j])
        digits[j] = UInt8(carry % 58)
        carry /= 58
        i += 1
      }
      length = i
    }
    let zeros = input.prefix { $0 == 0 }.count
    let start = digits.count - length
    return String(repeating: "1", count: zeros)
      + digits[start...].map { String(alphabet[Int($0)]) }.joined()
  }
}

extension Data {
  fileprivate init?(base64URLEncoded value: String) {
    var base64 = value.replacingOccurrences(of: "-", with: "+")
      .replacingOccurrences(of: "_", with: "/")
    base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
    self.init(base64Encoded: base64)
  }

  fileprivate func base64URLEncodedString() -> String {
    base64EncodedString()
      .replacingOccurrences(of: "+", with: "-")
      .replacingOccurrences(of: "/", with: "_")
      .replacingOccurrences(of: "=", with: "")
  }
}

private enum DateCodec {
  static func encodeDate(_ value: JSONValue) -> CBORValue? {
    guard let value = value.stringValue, !value.contains("T"),
      let date = parseDate(value), formatDate(date) == value
    else { return nil }
    let seconds = Int64(floor(date.timeIntervalSince1970))
    return seconds >= 0 ? .unsigned(UInt64(seconds)) : .negative(seconds)
  }

  static func decodeDate(_ value: CBORValue) -> String? {
    guard let seconds = value.integerValue else { return nil }
    return formatDate(Date(timeIntervalSince1970: TimeInterval(seconds)))
  }

  static func encodeDateTime(_ value: JSONValue) -> CBORValue? {
    guard let value = value.stringValue, value.contains("T"),
      let date = parseDateTime(value)
    else { return nil }
    let seconds = Int64(floor(date.timeIntervalSince1970))
    let secondsValue: CBORValue =
      seconds >= 0
      ? .unsigned(UInt64(seconds)) : .negative(seconds)
    if !value.contains(".") {
      return formatDateTime(date, fractional: false) == value ? secondsValue : nil
    }
    let milliseconds = Int64((date.timeIntervalSince1970 * 1_000).rounded()) - seconds * 1_000
    guard milliseconds >= 0,
      formatDateTime(date, fractional: true) == value
    else { return nil }
    return .array([secondsValue, .unsigned(UInt64(milliseconds))])
  }

  static func decodeDateTime(_ value: CBORValue) -> String? {
    if let seconds = value.integerValue {
      return formatDateTime(
        Date(timeIntervalSince1970: TimeInterval(seconds)), fractional: false)
    }
    guard case .array(let parts) = value, parts.count == 2,
      let seconds = parts[0].integerValue,
      let milliseconds = parts[1].integerValue
    else { return nil }
    return formatDateTime(
      Date(
        timeIntervalSince1970:
          TimeInterval(seconds) + TimeInterval(milliseconds) / 1_000),
      fractional: true)
  }

  private static func parseDate(_ value: String) -> Date? {
    let formatter = DateFormatter()
    formatter.calendar = Calendar(identifier: .gregorian)
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
    formatter.dateFormat = "yyyy-MM-dd"
    formatter.isLenient = false
    return formatter.date(from: value)
  }

  private static func formatDate(_ value: Date) -> String {
    let formatter = DateFormatter()
    formatter.calendar = Calendar(identifier: .gregorian)
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
    formatter.dateFormat = "yyyy-MM-dd"
    return formatter.string(from: value)
  }

  private static func parseDateTime(_ value: String) -> Date? {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions =
      value.contains(".")
      ? [.withInternetDateTime, .withFractionalSeconds]
      : [.withInternetDateTime]
    return formatter.date(from: value)
  }

  private static func formatDateTime(_ value: Date, fractional: Bool) -> String {
    let formatter = ISO8601DateFormatter()
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
    formatter.formatOptions =
      fractional
      ? [.withInternetDateTime, .withFractionalSeconds]
      : [.withInternetDateTime]
    return formatter.string(from: value)
  }
}
