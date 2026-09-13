import Foundation

/// The supported CBOR-LD envelope formats.
public enum CBORLDFormat: String, Sendable, Codable, CaseIterable {
  /// CBOR-LD 1.0, using tag 51997 (`0xcb1d`).
  case cborLD1 = "cbor-ld-1.0"
  /// The pre-1.0 tag range 1536...1791.
  case legacyRange = "legacy-range"
  /// The legacy singleton tags 1280 and 1281.
  case legacySingleton = "legacy-singleton"
}

/// Controls how the native CBOR writer orders maps and represents floating
/// point values.
public enum CBORLDSerializationMode: String, Sendable, Codable, CaseIterable {
  /// Preserve the byte-level behavior of the JavaScript reference processor.
  case compatibility
  /// The original deterministic mode. This remains length-first so existing
  /// callers and version-1 fingerprints do not change.
  case deterministic
  /// RFC 8949 section 4.2.3 length-first deterministic encoding.
  case lengthFirstDeterministic = "length-first-deterministic"
  /// RFC 8949 section 4.2.1 core deterministic encoding, including bytewise
  /// lexical map-key ordering.
  case coreDeterministic = "core-deterministic"

  /// Every supported profile emits a stable map order. Compatibility follows
  /// the JavaScript reference processor's `cborg` length-first ordering.
  var ordersMapKeys: Bool { true }

  var usesLengthFirstMapOrdering: Bool {
    self != .coreDeterministic
  }
}

/// A registry table maps a JSON value to its unsigned CBOR-LD identifier.
public typealias CBORLDValueTable = [JSONValue: UInt64]

/// Maps CBOR-LD value types (`context`, `url`, `none`, or an IRI) to tables.
public typealias CBORLDTypeTable = [String: CBORLDValueTable]

/// Resolves a remote JSON-LD context URL to the context document.
public typealias CBORLDDocumentLoader = @Sendable (String) async throws -> JSONValue

/// Resolves a CBOR-LD registry entry identifier to its type table.
public typealias CBORLDTypeTableLoader =
  @Sendable (UInt64) async throws -> CBORLDTypeTable?

/// Controls policy checks that are independent of parser resource limits.
/// The permissive default retains the JavaScript processor's accepted input
/// surface; use ``strict`` at trust boundaries that require a reproducible
/// byte representation.
public struct CBORLDDecodingPolicy: Sendable, Hashable, Codable {
  /// Reject integer and tag arguments encoded in a wider width than needed.
  public var rejectNonPreferredIntegerWidths: Bool
  /// Reject string and container lengths encoded in a wider width than needed.
  public var rejectNonPreferredLengthWidths: Bool
  /// Reject floating-point values that have an exact shorter representation,
  /// and reject non-preferred NaN spellings.
  public var rejectNonPreferredFloatingPoint: Bool
  /// Require the exact bytes emitted by a named deterministic profile. This
  /// additionally checks definite lengths and map-key ordering.
  public var requiredSerializationMode: CBORLDSerializationMode?
  /// Permit unassigned and reserved CBOR simple values in lossless inspection.
  /// Such values still cannot be converted to JSON and therefore remain
  /// invalid for the ordinary semantic decode API.
  public var allowsReservedSimpleValuesInLosslessMode: Bool

  public init(
    rejectNonPreferredIntegerWidths: Bool = false,
    rejectNonPreferredLengthWidths: Bool = false,
    rejectNonPreferredFloatingPoint: Bool = false,
    requiredSerializationMode: CBORLDSerializationMode? = nil,
    allowsReservedSimpleValuesInLosslessMode: Bool = false
  ) {
    self.rejectNonPreferredIntegerWidths = rejectNonPreferredIntegerWidths
    self.rejectNonPreferredLengthWidths = rejectNonPreferredLengthWidths
    self.rejectNonPreferredFloatingPoint = rejectNonPreferredFloatingPoint
    self.requiredSerializationMode = requiredSerializationMode
    self.allowsReservedSimpleValuesInLosslessMode = allowsReservedSimpleValuesInLosslessMode
  }

  /// RFC 8949 length-first deterministic bytes, preferred argument and float
  /// widths, no indefinite-length items, duplicate-key rejection, and no
  /// reserved simple values. Pass this together with ``CBORLDDecodingLimits/strict``.
  public static let strict = Self(
    rejectNonPreferredIntegerWidths: true,
    rejectNonPreferredLengthWidths: true,
    rejectNonPreferredFloatingPoint: true,
    requiredSerializationMode: .lengthFirstDeterministic,
    allowsReservedSimpleValuesInLosslessMode: false)
}

/// Resource limits applied while parsing untrusted CBOR-LD bytes.
public struct CBORLDDecodingLimits: Sendable, Hashable, Codable {
  /// Maximum size of one encoded CBOR-LD document.
  public var maximumInputBytes: Int
  /// Maximum nesting depth across CBOR tags, arrays, and maps.
  public var maximumNestingDepth: Int
  /// Maximum number of elements in an array or key/value pairs in a map.
  public var maximumContainerItems: Int
  /// Reject duplicate CBOR data-model map keys before semantic processing.
  /// This is opt-in so existing JavaScript-compatible error behavior remains.
  public var rejectDuplicateMapKeys: Bool
  /// Accept well-formed indefinite-length strings, arrays, and maps.
  public var allowsIndefiniteLengthItems: Bool
  /// Maximum number of nodes retained by lossless inspection. Validation still
  /// covers the complete input after this reporting bound is reached.
  public var maximumDiagnosticNodes: Int
  /// Check structured-concurrency cancellation after this many container
  /// elements while parsing one large document.
  public var cancellationCheckStride: Int

  public init(
    maximumInputBytes: Int = 64 * 1_024 * 1_024,
    maximumNestingDepth: Int = 128,
    maximumContainerItems: Int = 1_000_000,
    rejectDuplicateMapKeys: Bool = false,
    allowsIndefiniteLengthItems: Bool = true,
    maximumDiagnosticNodes: Int = 10_000,
    cancellationCheckStride: Int = 1_024
  ) {
    self.maximumInputBytes = maximumInputBytes
    self.maximumNestingDepth = maximumNestingDepth
    self.maximumContainerItems = maximumContainerItems
    self.rejectDuplicateMapKeys = rejectDuplicateMapKeys
    self.allowsIndefiniteLengthItems = allowsIndefiniteLengthItems
    self.maximumDiagnosticNodes = maximumDiagnosticNodes
    self.cancellationCheckStride = cancellationCheckStride
  }

  /// Security-oriented limits that reject duplicate map keys and indefinite
  /// lengths while retaining the standard size bounds.
  public static let strict = Self(
    rejectDuplicateMapKeys: true,
    allowsIndefiniteLengthItems: false)

  private enum CodingKeys: String, CodingKey {
    case maximumInputBytes
    case maximumNestingDepth
    case maximumContainerItems
    case rejectDuplicateMapKeys
    case allowsIndefiniteLengthItems
    case maximumDiagnosticNodes
    case cancellationCheckStride
  }

  public init(from decoder: Decoder) throws {
    let defaults = Self()
    let container = try decoder.container(keyedBy: CodingKeys.self)
    maximumInputBytes =
      try container.decodeIfPresent(Int.self, forKey: .maximumInputBytes)
      ?? defaults.maximumInputBytes
    maximumNestingDepth =
      try container.decodeIfPresent(Int.self, forKey: .maximumNestingDepth)
      ?? defaults.maximumNestingDepth
    maximumContainerItems =
      try container.decodeIfPresent(Int.self, forKey: .maximumContainerItems)
      ?? defaults.maximumContainerItems
    rejectDuplicateMapKeys =
      try container.decodeIfPresent(Bool.self, forKey: .rejectDuplicateMapKeys)
      ?? defaults.rejectDuplicateMapKeys
    allowsIndefiniteLengthItems =
      try container.decodeIfPresent(Bool.self, forKey: .allowsIndefiniteLengthItems)
      ?? defaults.allowsIndefiniteLengthItems
    maximumDiagnosticNodes =
      try container.decodeIfPresent(Int.self, forKey: .maximumDiagnosticNodes)
      ?? defaults.maximumDiagnosticNodes
    cancellationCheckStride =
      try container.decodeIfPresent(Int.self, forKey: .cancellationCheckStride)
      ?? defaults.cancellationCheckStride
  }
}

/// An application-controlled context cache that can optionally delegate misses.
public struct CBORLDContextRegistry: Sendable {
  public let documents: [String: JSONValue]
  public let expectedFingerprints: [String: CBORLDDigest]
  public let fallback: CBORLDDocumentLoader?

  public init(
    documents: [String: JSONValue] = [:],
    expectedFingerprints: [String: CBORLDDigest] = [:],
    fallback: CBORLDDocumentLoader? = nil
  ) {
    self.documents = documents
    self.expectedFingerprints = expectedFingerprints
    self.fallback = fallback
  }

  public func load(_ url: String) async throws -> JSONValue {
    let document: JSONValue
    if let registered = documents[url] {
      document = registered
    } else if let fallback {
      document = try await fallback(url)
    } else {
      throw CBORLDError(
        code: "ERR_UNKNOWN_CONTEXT",
        message: "No JSON-LD context is registered for \"\(url)\".")
    }

    if let expected = expectedFingerprints[url] {
      try CBORLD.verifyContext(document, against: expected)
    }
    return document
  }

  public var documentLoader: CBORLDDocumentLoader {
    { url in try await self.load(url) }
  }
}

public struct CBORLDEncodingOptions: Sendable {
  public var format: CBORLDFormat
  public var serializationMode: CBORLDSerializationMode
  public var registryEntryID: UInt64?
  public var documentLoader: CBORLDDocumentLoader?
  public var typeTableLoader: CBORLDTypeTableLoader?
  public var applicationContextMap: [String: UInt64]?
  public var compressionMode: UInt8?
  public var diagnostic: (@Sendable (String) -> Void)?

  public init(
    format: CBORLDFormat = .cborLD1,
    serializationMode: CBORLDSerializationMode = .compatibility,
    registryEntryID: UInt64? = nil,
    documentLoader: CBORLDDocumentLoader? = nil,
    typeTableLoader: CBORLDTypeTableLoader? = nil,
    applicationContextMap: [String: UInt64]? = nil,
    compressionMode: UInt8? = nil,
    diagnostic: (@Sendable (String) -> Void)? = nil
  ) {
    self.format = format
    self.serializationMode = serializationMode
    self.registryEntryID = registryEntryID
    self.documentLoader = documentLoader
    self.typeTableLoader = typeTableLoader
    self.applicationContextMap = applicationContextMap
    self.compressionMode = compressionMode
    self.diagnostic = diagnostic
  }
}

/// Metadata extracted without resolving contexts or decoding the JSON-LD body.
public struct CBORLDInspection: Sendable, Hashable, Codable {
  public let format: CBORLDFormat
  public let registryEntryID: UInt64?
  public let payloadIsCompressed: Bool
  public let byteCount: Int
  public let payloadDescription: String
  /// SHA-256 of the exact encoded CBOR-LD bytes.
  public let transportDigest: CBORLDDigest
}

public struct CBORLDDecodingOptions: Sendable {
  public var documentLoader: CBORLDDocumentLoader?
  public var typeTableLoader: CBORLDTypeTableLoader?
  public var applicationContextMap: [String: UInt64]?
  public var limits: CBORLDDecodingLimits
  public var policy: CBORLDDecodingPolicy
  public var diagnostic: (@Sendable (String) -> Void)?

  public init(
    documentLoader: CBORLDDocumentLoader? = nil,
    typeTableLoader: CBORLDTypeTableLoader? = nil,
    applicationContextMap: [String: UInt64]? = nil,
    limits: CBORLDDecodingLimits = .init(),
    policy: CBORLDDecodingPolicy = .init(),
    diagnostic: (@Sendable (String) -> Void)? = nil
  ) {
    self.documentLoader = documentLoader
    self.typeTableLoader = typeTableLoader
    self.applicationContextMap = applicationContextMap
    self.limits = limits
    self.policy = policy
    self.diagnostic = diagnostic
  }
}

/// Machine-readable location and policy information attached to parser errors.
public struct CBORLDSourceDiagnostic: Sendable, Hashable, Codable {
  public let byteOffset: Int
  public let endOffset: Int?
  public let containerPath: [String]
  public let jsonPath: String?
  public let majorType: UInt8?
  public let additionalInformation: UInt8?
  public let violation: String?
  public let relatedByteOffset: Int?

  public init(
    byteOffset: Int,
    endOffset: Int? = nil,
    containerPath: [String] = [],
    jsonPath: String? = nil,
    majorType: UInt8? = nil,
    additionalInformation: UInt8? = nil,
    violation: String? = nil,
    relatedByteOffset: Int? = nil
  ) {
    self.byteOffset = byteOffset
    self.endOffset = endOffset
    self.containerPath = containerPath
    self.jsonPath = jsonPath
    self.majorType = majorType
    self.additionalInformation = additionalInformation
    self.violation = violation
    self.relatedByteOffset = relatedByteOffset
  }
}

/// A processor error with the same stable error-code vocabulary as the
/// JavaScript implementation.
public struct CBORLDError: Error, Sendable, Equatable, CustomStringConvertible {
  public let code: String
  public let message: String
  public let diagnostic: CBORLDSourceDiagnostic?

  public init(
    code: String,
    message: String,
    diagnostic: CBORLDSourceDiagnostic? = nil
  ) {
    self.code = code
    self.message = message
    self.diagnostic = diagnostic
  }

  public var description: String { "\(code): \(message)" }
}

extension CBORLDError {
  static func invalidInput(_ message: String) -> Self {
    .init(code: "ERR_INVALID_INPUT", message: message)
  }
}
