import Foundation

/// Hash algorithms supported without third-party dependencies.
public enum CBORLDHashAlgorithm: String, Sendable, Codable, CaseIterable {
  case sha256 = "sha2-256"
  case sha384 = "sha2-384"
  case sha512 = "sha2-512"

  fileprivate var byteCount: Int {
    switch self {
    case .sha256: 32
    case .sha384: 48
    case .sha512: 64
    }
  }
}

/// Identifies the bytes and normalization policy represented by a digest.
public enum CBORLDHashDomain: String, Sendable, Codable, CaseIterable {
  /// The exact CBOR-LD transport bytes. These bytes are hashed without a
  /// domain prefix so the result is also a conventional file digest.
  case encodedBytes = "encoded-bytes"
  /// A deterministic CBOR representation of a JSON-shaped document.
  case documentStructure = "document-structure"
  /// A deterministic representation of a document dictionary and its binding.
  case documentDictionary = "document-dictionary"
  /// A deterministic representation of a JSON-LD context document.
  case contextDocument = "context-document"
}

/// A self-describing digest. Bare hexadecimal strings are intentionally not
/// used as the primary API because they lose algorithm, domain, and version.
public struct CBORLDDigest: Sendable, Hashable, Codable, CustomStringConvertible {
  public let algorithm: CBORLDHashAlgorithm
  public let domain: CBORLDHashDomain
  public let version: UInt8
  public let bytes: Data

  public init(
    algorithm: CBORLDHashAlgorithm,
    domain: CBORLDHashDomain,
    version: UInt8 = 1,
    bytes: Data
  ) throws {
    guard bytes.count == algorithm.byteCount else {
      throw CBORLDError(
        code: .invalidDigest,
        message:
          "\(algorithm.rawValue) digests must contain \(algorithm.byteCount) bytes, not \(bytes.count)."
      )
    }
    self.algorithm = algorithm
    self.domain = domain
    self.version = version
    self.bytes = bytes
  }

  public init(
    algorithm: CBORLDHashAlgorithm,
    domain: CBORLDHashDomain,
    version: UInt8 = 1,
    hex: String
  ) throws {
    guard hex.count == algorithm.byteCount * 2 else {
      throw CBORLDError(
        code: .invalidDigest,
        message:
          "\(algorithm.rawValue) hexadecimal digests must contain \(algorithm.byteCount * 2) characters."
      )
    }
    var data = Data()
    data.reserveCapacity(algorithm.byteCount)
    var index = hex.startIndex
    while index < hex.endIndex {
      let next = hex.index(index, offsetBy: 2)
      guard let byte = UInt8(hex[index..<next], radix: 16) else {
        throw CBORLDError(
          code: .invalidDigest,
          message: "Digest contains a non-hexadecimal character.")
      }
      data.append(byte)
      index = next
    }
    try self.init(algorithm: algorithm, domain: domain, version: version, bytes: data)
  }

  public var hex: String {
    bytes.map { String(format: "%02x", $0) }.joined()
  }

  public var base64URL: String {
    bytes.base64EncodedString()
      .replacingOccurrences(of: "+", with: "-")
      .replacingOccurrences(of: "/", with: "_")
      .replacingOccurrences(of: "=", with: "")
  }

  public var description: String {
    "\(algorithm.rawValue):\(domain.rawValue):v\(version):\(hex)"
  }

  init(
    uncheckedAlgorithm algorithm: CBORLDHashAlgorithm,
    domain: CBORLDHashDomain,
    version: UInt8,
    bytes: Data
  ) {
    self.algorithm = algorithm
    self.domain = domain
    self.version = version
    self.bytes = bytes
  }

  private enum CodingKeys: String, CodingKey {
    case algorithm
    case domain
    case version
    case bytes
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let algorithm = try container.decode(CBORLDHashAlgorithm.self, forKey: .algorithm)
    let domain = try container.decode(CBORLDHashDomain.self, forKey: .domain)
    let version = try container.decode(UInt8.self, forKey: .version)
    let bytes = try container.decode(Data.self, forKey: .bytes)
    try self.init(algorithm: algorithm, domain: domain, version: version, bytes: bytes)
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(algorithm, forKey: .algorithm)
    try container.encode(domain, forKey: .domain)
    try container.encode(version, forKey: .version)
    try container.encode(bytes, forKey: .bytes)
  }
}

extension CBORLD {
  /// Computes the selected SHA-2 digest over the exact CBOR-LD bytes. No
  /// domain prefix is mixed in, so `hex` is an ordinary file checksum.
  public static func transportDigest(
    of data: Data,
    algorithm: CBORLDHashAlgorithm = .sha256
  ) -> CBORLDDigest {
    transportDigest(chunks: CollectionOfOne(data), algorithm: algorithm)
  }

  /// Computes a transport digest incrementally from a sequence of byte chunks.
  /// The result has exactly the same meaning as `transportDigest(of:)` and does
  /// not include a domain prefix.
  public static func transportDigest<Chunks: Sequence>(
    chunks: Chunks,
    algorithm: CBORLDHashAlgorithm = .sha256
  ) -> CBORLDDigest where Chunks.Element == Data {
    var hasher = CBORLDSHA2Hasher(algorithm: algorithm)
    for chunk in chunks { hasher.update(data: chunk) }
    let bytes = hasher.finalize()
    return CBORLDDigest(
      uncheckedAlgorithm: algorithm,
      domain: .encodedBytes,
      version: 1,
      bytes: bytes)
  }

  /// Computes a transport digest without loading an entire file into memory.
  public static func transportDigest(
    ofFile url: URL,
    algorithm: CBORLDHashAlgorithm = .sha256,
    chunkSize: Int = 1_048_576
  ) throws -> CBORLDDigest {
    guard chunkSize > 0 else {
      throw CBORLDError.invalidInput("Hashing chunkSize must be greater than zero.")
    }
    let handle = try FileHandle(forReadingFrom: url)
    defer { try? handle.close() }

    var hasher = CBORLDSHA2Hasher(algorithm: algorithm)
    while let chunk = try handle.read(upToCount: chunkSize), !chunk.isEmpty {
      hasher.update(data: chunk)
    }
    return CBORLDDigest(
      uncheckedAlgorithm: algorithm,
      domain: .encodedBytes,
      version: 1,
      bytes: hasher.finalize())
  }

  /// Verifies the exact encoded bytes using a constant-time digest comparison.
  public static func verify(_ data: Data, against expected: CBORLDDigest) throws {
    guard expected.domain == .encodedBytes, expected.version == 1 else {
      throw incompatible(expected, requiredDomain: .encodedBytes)
    }
    let observed = transportDigest(of: data, algorithm: expected.algorithm)
    try requireMatch(observed, expected)
  }

  /// Fingerprints JSON structure using deterministic CBOR. Object key order is
  /// ignored and array order is preserved. This is not RDF dataset
  /// canonicalization and does not claim JSON-LD semantic equivalence.
  public static func structuralFingerprint(
    of document: JSONValue,
    algorithm: CBORLDHashAlgorithm = .sha256
  ) throws -> CBORLDDigest {
    let value = try CBORValue.fromJSON(document)
    let canonicalBytes = try CBOREncoder.encode(value, mode: .deterministic)
    return domainSeparatedDigest(
      canonicalBytes,
      algorithm: algorithm,
      domain: .documentStructure,
      version: 1)
  }

  public static func verifyDocument(
    _ document: JSONValue,
    against expected: CBORLDDigest
  ) throws {
    guard expected.domain == .documentStructure, expected.version == 1 else {
      throw incompatible(expected, requiredDomain: .documentStructure)
    }
    let observed = try structuralFingerprint(of: document, algorithm: expected.algorithm)
    try requireMatch(observed, expected)
  }

  /// Fingerprints the parsed structure of a JSON-LD context. This is useful
  /// when the loader does not expose the original response bytes.
  public static func contextFingerprint(
    of document: JSONValue,
    algorithm: CBORLDHashAlgorithm = .sha256
  ) throws -> CBORLDDigest {
    let value = try CBORValue.fromJSON(document)
    let canonicalBytes = try CBOREncoder.encode(value, mode: .deterministic)
    return domainSeparatedDigest(
      canonicalBytes,
      algorithm: algorithm,
      domain: .contextDocument,
      version: 1)
  }

  public static func verifyContext(
    _ document: JSONValue,
    against expected: CBORLDDigest
  ) throws {
    guard expected.domain == .contextDocument, expected.version == 1 else {
      throw incompatible(expected, requiredDomain: .contextDocument)
    }
    let observed = try contextFingerprint(of: document, algorithm: expected.algorithm)
    try requireMatch(observed, expected)
  }

  fileprivate static func dictionaryFingerprint(
    _ dictionary: CBORLDDocumentDictionary,
    algorithm: CBORLDHashAlgorithm
  ) throws -> CBORLDDigest {
    try dictionary.validate()
    let canonicalBytes = try CBOREncoder.encode(
      try dictionary.fingerprintValue(),
      mode: .deterministic)
    return domainSeparatedDigest(
      canonicalBytes,
      algorithm: algorithm,
      domain: .documentDictionary,
      version: 1)
  }

  private static func domainSeparatedDigest(
    _ canonicalBytes: Data,
    algorithm: CBORLDHashAlgorithm,
    domain: CBORLDHashDomain,
    version: UInt8
  ) -> CBORLDDigest {
    var input = Data("CBOR-LD\0".utf8)
    input.append(Data(domain.rawValue.utf8))
    input.append(0)
    input.append(version)
    input.append(canonicalBytes)
    return digest(input, algorithm: algorithm, domain: domain, version: version)
  }

  private static func digest(
    _ data: Data,
    algorithm: CBORLDHashAlgorithm,
    domain: CBORLDHashDomain,
    version: UInt8
  ) -> CBORLDDigest {
    let bytes = CBORLDSHA2Hasher.hash(data, algorithm: algorithm)
    return CBORLDDigest(
      uncheckedAlgorithm: algorithm,
      domain: domain,
      version: version,
      bytes: bytes)
  }

  private static func incompatible(
    _ digest: CBORLDDigest,
    requiredDomain: CBORLDHashDomain
  ) -> CBORLDError {
    CBORLDError(
      code: .invalidDigest,
      message:
        "Expected a version 1 \(requiredDomain.rawValue) digest, received \(digest.domain.rawValue) version \(digest.version)."
    )
  }

  fileprivate static func requireMatch(
    _ observed: CBORLDDigest,
    _ expected: CBORLDDigest
  ) throws {
    guard observed.algorithm == expected.algorithm,
      observed.domain == expected.domain,
      observed.version == expected.version,
      constantTimeEqual(observed.bytes, expected.bytes)
    else {
      throw CBORLDError(
        code: .integrityMismatch,
        message:
          "The observed \(expected.domain.rawValue) digest does not match the expected value.")
    }
  }

  private static func constantTimeEqual(_ lhs: Data, _ rhs: Data) -> Bool {
    guard lhs.count == rhs.count else { return false }
    var difference: UInt8 = 0
    for index in lhs.indices {
      difference |= lhs[index] ^ rhs[index]
    }
    return difference == 0
  }
}

extension CBORLDDocumentDictionary {
  /// Fingerprints the dictionary's registry binding and all semantic tables.
  public func fingerprint(
    algorithm: CBORLDHashAlgorithm = .sha256
  ) throws -> CBORLDDigest {
    try CBORLD.dictionaryFingerprint(self, algorithm: algorithm)
  }

  public func verifyFingerprint(_ expected: CBORLDDigest) throws {
    guard expected.domain == .documentDictionary, expected.version == 1 else {
      throw CBORLDError(
        code: .invalidDigest,
        message:
          "Expected a version 1 document-dictionary digest, received \(expected.domain.rawValue) version \(expected.version)."
      )
    }
    let observed = try fingerprint(algorithm: expected.algorithm)
    try CBORLD.requireMatch(observed, expected)
  }

  fileprivate func fingerprintValue() throws -> CBORValue {
    var entries: [CBORMapEntry] = [
      .init(key: .string("code"), value: .unsigned(code)),
      .init(key: .string("contexts"), value: stringTable(contexts)),
      .init(key: .string("uris"), value: stringTable(uris)),
      .init(key: .string("untypedValues"), value: try valueTable(untypedValues)),
    ]
    if let profileName {
      entries.append(.init(key: .string("profileName"), value: .string(profileName)))
    }
    if let profileVersion {
      entries.append(.init(key: .string("profileVersion"), value: .string(profileVersion)))
    }
    let typedEntries = try typedValues.map { type, table in
      CBORMapEntry(key: .string(type), value: try valueTable(table))
    }
    entries.append(
      .init(key: .string("typedValues"), value: .map(typedEntries)))
    // The processing model changes how bytes are read, so a non-default model
    // is bound into the fingerprint. It is omitted otherwise, which keeps every
    // version 1 fingerprint of a dictionary without one unchanged.
    // Provisional status does not change the wire format and is not bound.
    let model = effectiveProcessingModel
    if model != (code == 0 ? .uncompressed : .default) {
      entries.append(
        .init(
          key: .string("processingModel"),
          value: .map([
            .init(key: .string("semanticCompression"), value: .bool(model.semanticCompression)),
            .init(
              key: .string("codecs"),
              value: .map(
                model.codecs.map {
                  CBORMapEntry(key: .string($0.key), value: .string($0.value.rawValue))
                })),
          ])))
    }
    return .map(entries)
  }

  private func stringTable(_ table: [String: UInt64]) -> CBORValue {
    .map(
      table.map {
        CBORMapEntry(key: .string($0.key), value: .unsigned($0.value))
      })
  }

  private func valueTable(_ table: CBORLDValueTable) throws -> CBORValue {
    .map(
      try table.map {
        CBORMapEntry(key: try CBORValue.fromJSON($0.key), value: .unsigned($0.value))
      })
  }
}
