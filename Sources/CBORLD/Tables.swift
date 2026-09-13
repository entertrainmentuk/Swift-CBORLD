import Foundation

enum CBORLDConstants {
  static let keywords: [String: UInt64] = [
    "@context": 0,
    "@type": 2,
    "@id": 4,
    "@value": 6,
    "@direction": 8,
    "@graph": 10,
    "@included": 12,
    "@index": 14,
    "@json": 16,
    "@language": 18,
    "@list": 20,
    "@nest": 22,
    "@reverse": 24,
    "@base": 26,
    "@container": 28,
    "@default": 30,
    "@embed": 32,
    "@explicit": 34,
    "@none": 36,
    "@omitDefault": 38,
    "@prefix": 40,
    "@preserve": 42,
    "@protected": 44,
    "@requireAll": 46,
    "@set": 48,
    "@version": 50,
    "@vocab": 52,
    "@propagate": 54,
  ]

  static let firstCustomTermID: UInt64 = 100
  static let maximumSafeInteger: UInt64 = 9_007_199_254_740_991

  static let legacyStrings: [String: UInt64] = [
    "https://www.w3.org/ns/activitystreams": 16,
    "https://www.w3.org/2018/credentials/v1": 17,
    "https://www.w3.org/ns/did/v1": 18,
    "https://w3id.org/security/suites/ed25519-2018/v1": 19,
    "https://w3id.org/security/suites/ed25519-2020/v1": 20,
    "https://w3id.org/cit/v1": 21,
    "https://w3id.org/age/v1": 22,
    "https://w3id.org/security/suites/x25519-2020/v1": 23,
    "https://w3id.org/veres-one/v1": 24,
    "https://w3id.org/webkms/v1": 25,
    "https://w3id.org/zcap/v1": 26,
    "https://w3id.org/security/suites/hmac-2019/v1": 27,
    "https://w3id.org/security/suites/aes-2019/v1": 28,
    "https://w3id.org/vaccination/v1": 29,
    "https://w3id.org/vc-revocation-list-2020/v1": 30,
    "https://w3id.org/dcc/v1": 31,
    "https://w3id.org/vc/status-list/v1": 32,
    "https://www.w3.org/ns/credentials/v2": 33,
    "https://w3id.org/security/data-integrity/v1": 48,
    "https://w3id.org/security/multikey/v1": 49,
    "https://purl.imsglobal.org/spec/ob/v3p0/context.json": 50,
    "https://w3id.org/security/data-integrity/v2": 51,
  ]

  static let urlSchemes: [String: UInt64] = [
    "http://": 1,
    "https://": 2,
    "urn:uuid:": 3,
    "data:": 4,
    "did:v1:nym:": 1024,
    "did:key:": 1025,
  ]

  static let legacyTypeTable: CBORLDTypeTable = {
    let strings = Dictionary(
      uniqueKeysWithValues:
        legacyStrings.map { (JSONValue.string($0.key), $0.value) })
    let cryptosuites: CBORLDValueTable = [
      "ecdsa-rdfc-2019": 1,
      "ecdsa-sd-2023": 2,
      "eddsa-rdfc-2022": 3,
      "ecdsa-xi-2023": 4,
    ]
    return [
      "context": strings,
      "url": strings,
      "none": strings,
      "https://w3id.org/security#cryptosuiteString": cryptosuites,
    ]
  }()

  static let legacyTableTypesEncodedAsBytes: Set<String> = [
    "none",
    "http://www.w3.org/2001/XMLSchema#date",
    "http://www.w3.org/2001/XMLSchema#dateTime",
  ]

  static let tableTypesEncodedAsBytes =
    legacyTableTypesEncodedAsBytes.union(["url"])

  static func normalized(_ table: CBORLDTypeTable?) -> CBORLDTypeTable {
    var result = table ?? [:]
    result["context", default: [:]] = result["context", default: [:]]
    result["url", default: [:]] = result["url", default: [:]]
    result["none", default: [:]] = result["none", default: [:]]
    return result
  }

  static func reversed(_ map: [String: UInt64]) -> [UInt64: String] {
    Dictionary(uniqueKeysWithValues: map.map { ($0.value, $0.key) })
  }

  static func reversed(_ map: CBORLDValueTable) throws -> [UInt64: JSONValue] {
    var result: [UInt64: JSONValue] = [:]
    for (value, id) in map {
      guard result[id] == nil else {
        throw CBORLDError(
          code: "ERR_INVALID_TYPETABLE",
          message: "Type table contains duplicate identifier \(id).")
      }
      result[id] = value
    }
    return result
  }
}

/// An immutable, semantically named CBOR-LD registry entry.
///
/// This facade is inspired by Iridium's document-dictionary boundary while
/// retaining the JavaScript processor's `context` / `url` / `none` table model.
public struct CBORLDDocumentDictionary: Sendable, Hashable, Codable {
  public let code: UInt64
  public let profileName: String?
  public let profileVersion: String?
  public let contexts: [String: UInt64]
  public let typedValues: [String: CBORLDValueTable]
  public let uris: [String: UInt64]
  public let untypedValues: CBORLDValueTable

  public init(
    code: UInt64,
    profileName: String? = nil,
    profileVersion: String? = nil,
    contexts: [String: UInt64] = [:],
    typedValues: [String: CBORLDValueTable] = [:],
    uris: [String: UInt64] = [:],
    untypedValues: CBORLDValueTable = [:]
  ) {
    self.code = code
    self.profileName = profileName
    self.profileVersion = profileVersion
    self.contexts = contexts
    self.typedValues = typedValues
    self.uris = uris
    self.untypedValues = untypedValues
  }

  public var typeTable: CBORLDTypeTable {
    var result = typedValues
    result["context"] = Dictionary(
      uniqueKeysWithValues:
        contexts.map { (.string($0.key), $0.value) })
    result["url"] = Dictionary(
      uniqueKeysWithValues:
        uris.map { (.string($0.key), $0.value) })
    result["none"] = untypedValues
    return result
  }

  /// Validates identifiers and table structure before the dictionary is used
  /// to encode or decode a document.
  public func validate() throws {
    guard code <= CBORLDConstants.maximumSafeInteger else {
      throw CBORLDError(
        code: "ERR_INVALID_DICTIONARY",
        message: "Dictionary code \(code) exceeds the CBOR-LD safe-integer limit.")
    }
    if code <= 1,
      !contexts.isEmpty || !typedValues.isEmpty || !uris.isEmpty || !untypedValues.isEmpty
    {
      throw CBORLDError(
        code: "ERR_INVALID_DICTIONARY",
        message: "Dictionary codes 0 and 1 cannot carry application tables.")
    }
    for reserved in ["context", "url", "none"] where typedValues[reserved] != nil {
      throw CBORLDError(
        code: "ERR_INVALID_DICTIONARY",
        message: "Typed values cannot replace the reserved \"\(reserved)\" table.")
    }

    try validateIdentifiers(contexts, tableName: "context")
    try validateIdentifiers(uris, tableName: "url")
    try validateIdentifiers(untypedValues, tableName: "none")
    for name in typedValues.keys.sorted() {
      if let table = typedValues[name] {
        try validateIdentifiers(table, tableName: name)
      }
    }
  }

  private func validateIdentifiers<Key: Hashable>(
    _ table: [Key: UInt64],
    tableName: String
  ) throws {
    var values = Set<UInt64>()
    for identifier in table.values {
      guard identifier <= CBORLDConstants.maximumSafeInteger else {
        throw CBORLDError(
          code: "ERR_INVALID_DICTIONARY",
          message:
            "Identifier \(identifier) in \"\(tableName)\" exceeds the safe-integer limit.")
      }
      guard values.insert(identifier).inserted else {
        throw CBORLDError(
          code: "ERR_INVALID_DICTIONARY",
          message: "Identifier \(identifier) is duplicated in \"\(tableName)\".")
      }
    }
  }

  public static let unregistered = CBORLDDocumentDictionary(code: 1)
}
