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

/// Resolves a CBOR-LD registry entry identifier to its type table. The entry
/// uses the default processing model; use ``CBORLDRegistryEntryLoader`` to
/// resolve complete registry entries.
public typealias CBORLDTypeTableLoader =
  @Sendable (UInt64) async throws -> CBORLDTypeTable?

/// Controls policy checks that are independent of parser resource limits.
/// The permissive default retains the JavaScript processor's accepted input
/// surface; use ``strict`` at trust boundaries that require a reproducible
/// byte representation, or the complete
/// ``CBORLDDecodingConfiguration/untrustedDeterministic`` preset.
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
  /// reserved simple values. Pass this together with ``CBORLDDecodingLimits/strict``,
  /// or use ``CBORLDDecodingConfiguration/untrustedDeterministic``.
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

/// A complete parser configuration for one trust boundary.
///
/// ``CBORLDDecodingLimits`` bounds the work a document may cause, while
/// ``CBORLDDecodingPolicy`` decides which byte representations are acceptable.
/// Safe input and deterministic transport are related but distinct
/// requirements, so the presets keep them separate:
///
/// - ``untrustedCompatible`` accepts any representation the JavaScript
///   processor produces, inside tight resource bounds and without duplicate
///   keys or indefinite lengths.
/// - ``untrustedDeterministic`` additionally requires the exact bytes of the
///   RFC 8949 length-first deterministic profile.
///
/// Contexts loaded while decoding are bounded separately by
/// ``CBORLDContextLoadingPolicy``; use ``CBORLDContextLoadingPolicy/strict``
/// alongside either untrusted preset.
public struct CBORLDDecodingConfiguration: Sendable, Hashable, Codable {
  public var limits: CBORLDDecodingLimits
  public var policy: CBORLDDecodingPolicy

  public init(
    limits: CBORLDDecodingLimits = .init(),
    policy: CBORLDDecodingPolicy = .init()
  ) {
    self.limits = limits
    self.policy = policy
  }

  /// The package defaults: generous bounds and the JavaScript-compatible
  /// accepted input surface.
  public static let permissive = Self()

  /// Bounded parsing for untrusted input that may use any compatible
  /// representation: 16 MiB input, 64 levels of nesting, 65,536 items per
  /// container, duplicate-key rejection, no indefinite-length items, 1,024
  /// retained diagnostic nodes, and cancellation checks every 256 elements.
  public static let untrustedCompatible = Self(
    limits: untrustedLimits,
    policy: .init())

  /// ``untrustedCompatible`` plus preferred integer, length, and
  /// floating-point widths and the exact RFC 8949 length-first deterministic
  /// byte representation.
  public static let untrustedDeterministic = Self(
    limits: untrustedLimits,
    policy: .strict)

  private static let untrustedLimits = CBORLDDecodingLimits(
    maximumInputBytes: 16 * 1_024 * 1_024,
    maximumNestingDepth: 64,
    maximumContainerItems: 65_536,
    rejectDuplicateMapKeys: true,
    allowsIndefiniteLengthItems: false,
    maximumDiagnosticNodes: 1_024,
    cancellationCheckStride: 256)
}

/// Resource limits applied while producing CBOR-LD bytes. Every limit is
/// enforced while the output is being built: the writer refuses to grow past
/// ``maximumOutputBytes`` instead of inspecting a completed buffer.
public struct CBORLDEncodingLimits: Sendable, Hashable, Codable {
  /// Maximum size of the complete encoded CBOR-LD document.
  public var maximumOutputBytes: Int
  /// Maximum nesting depth across the emitted CBOR tags, arrays, and maps,
  /// counted exactly as ``CBORLDDecodingLimits/maximumNestingDepth`` counts
  /// it, so output within this limit also satisfies an equal decoding limit.
  public var maximumNestingDepth: Int
  /// Maximum number of elements in an array or key/value pairs in a map.
  public var maximumContainerItems: Int
  /// Check structured-concurrency cancellation after this many container
  /// elements while encoding one large document.
  public var cancellationCheckStride: Int

  public init(
    maximumOutputBytes: Int = 64 * 1_024 * 1_024,
    maximumNestingDepth: Int = 128,
    maximumContainerItems: Int = 1_000_000,
    cancellationCheckStride: Int = 1_024
  ) {
    self.maximumOutputBytes = maximumOutputBytes
    self.maximumNestingDepth = maximumNestingDepth
    self.maximumContainerItems = maximumContainerItems
    self.cancellationCheckStride = cancellationCheckStride
  }

  /// Internal hashing and fingerprinting of caller-supplied values keeps its
  /// historical unbounded behavior.
  static let unbounded = Self(
    maximumOutputBytes: .max,
    maximumNestingDepth: .max,
    maximumContainerItems: .max,
    cancellationCheckStride: 1_024)

  func validate() throws {
    guard maximumOutputBytes >= 0,
      maximumNestingDepth >= 0,
      maximumContainerItems >= 0,
      cancellationCheckStride > 0
    else {
      throw CBORLDError.resourceLimit(
        "CBOR-LD encoding limits must not be negative and cancellationCheckStride must be positive."
      )
    }
  }

  private enum CodingKeys: String, CodingKey {
    case maximumOutputBytes
    case maximumNestingDepth
    case maximumContainerItems
    case cancellationCheckStride
  }

  public init(from decoder: Decoder) throws {
    let defaults = Self()
    let container = try decoder.container(keyedBy: CodingKeys.self)
    maximumOutputBytes =
      try container.decodeIfPresent(Int.self, forKey: .maximumOutputBytes)
      ?? defaults.maximumOutputBytes
    maximumNestingDepth =
      try container.decodeIfPresent(Int.self, forKey: .maximumNestingDepth)
      ?? defaults.maximumNestingDepth
    maximumContainerItems =
      try container.decodeIfPresent(Int.self, forKey: .maximumContainerItems)
      ?? defaults.maximumContainerItems
    cancellationCheckStride =
      try container.decodeIfPresent(Int.self, forKey: .cancellationCheckStride)
      ?? defaults.cancellationCheckStride
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
  /// Resolves complete registry entries, including processing models. Use
  /// this or ``typeTableLoader``, not both.
  public var registryEntryLoader: CBORLDRegistryEntryLoader?
  /// The application's table for a registry entry whose `typeTables`
  /// requires a caller-provided table.
  public var callerProvidedTypeTable: CBORLDTypeTable?
  /// Codecs for identifiers that processing models use beyond the built-in
  /// codecs.
  public var codecs: [any CBORLDTypedValueCodec]
  /// Whether provisional registry entries may be used.
  public var allowsProvisionalRegistryEntries: Bool
  /// Bounds on the produced bytes and their structure.
  public var limits: CBORLDEncodingLimits
  /// Bounds and integrity requirements for contexts loaded while encoding.
  public var contextPolicy: CBORLDContextLoadingPolicy
  /// A metadata-reporting context loader. Use this or ``documentLoader``,
  /// not both.
  public var contextDocumentLoader: CBORLDContextDocumentLoader?

  public init(
    format: CBORLDFormat = .cborLD1,
    serializationMode: CBORLDSerializationMode = .compatibility,
    registryEntryID: UInt64? = nil,
    documentLoader: CBORLDDocumentLoader? = nil,
    typeTableLoader: CBORLDTypeTableLoader? = nil,
    applicationContextMap: [String: UInt64]? = nil,
    compressionMode: UInt8? = nil,
    diagnostic: (@Sendable (String) -> Void)? = nil,
    registryEntryLoader: CBORLDRegistryEntryLoader? = nil,
    callerProvidedTypeTable: CBORLDTypeTable? = nil,
    codecs: [any CBORLDTypedValueCodec] = [],
    allowsProvisionalRegistryEntries: Bool = true,
    limits: CBORLDEncodingLimits = .init(),
    contextPolicy: CBORLDContextLoadingPolicy = .init(),
    contextDocumentLoader: CBORLDContextDocumentLoader? = nil
  ) {
    self.format = format
    self.serializationMode = serializationMode
    self.registryEntryID = registryEntryID
    self.documentLoader = documentLoader
    self.typeTableLoader = typeTableLoader
    self.applicationContextMap = applicationContextMap
    self.compressionMode = compressionMode
    self.diagnostic = diagnostic
    self.registryEntryLoader = registryEntryLoader
    self.callerProvidedTypeTable = callerProvidedTypeTable
    self.codecs = codecs
    self.allowsProvisionalRegistryEntries = allowsProvisionalRegistryEntries
    self.limits = limits
    self.contextPolicy = contextPolicy
    self.contextDocumentLoader = contextDocumentLoader
  }
}

/// Metadata extracted without resolving contexts or decoding the JSON-LD body.
public struct CBORLDInspection: Sendable, Hashable, Codable {
  public let format: CBORLDFormat
  public let registryEntryID: UInt64?
  /// Whether the envelope selects something other than the uncompressed
  /// representation: any registry entry except `0`, or legacy tag 1281.
  /// Inspection does not resolve registry entries, so the transform actually
  /// applied depends on the selected entry's processing model.
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
  /// Resolves complete registry entries, including processing models. Use
  /// this or ``typeTableLoader``, not both.
  public var registryEntryLoader: CBORLDRegistryEntryLoader?
  /// The application's table for a registry entry whose `typeTables`
  /// requires a caller-provided table.
  public var callerProvidedTypeTable: CBORLDTypeTable?
  /// Codecs for identifiers that processing models use beyond the built-in
  /// codecs.
  public var codecs: [any CBORLDTypedValueCodec]
  /// Whether documents may select provisional registry entries.
  public var allowsProvisionalRegistryEntries: Bool
  /// Bounds and integrity requirements for contexts loaded while decoding.
  public var contextPolicy: CBORLDContextLoadingPolicy
  /// A metadata-reporting context loader. Use this or ``documentLoader``,
  /// not both.
  public var contextDocumentLoader: CBORLDContextDocumentLoader?

  public init(
    documentLoader: CBORLDDocumentLoader? = nil,
    typeTableLoader: CBORLDTypeTableLoader? = nil,
    applicationContextMap: [String: UInt64]? = nil,
    limits: CBORLDDecodingLimits = .init(),
    policy: CBORLDDecodingPolicy = .init(),
    diagnostic: (@Sendable (String) -> Void)? = nil,
    registryEntryLoader: CBORLDRegistryEntryLoader? = nil,
    callerProvidedTypeTable: CBORLDTypeTable? = nil,
    codecs: [any CBORLDTypedValueCodec] = [],
    allowsProvisionalRegistryEntries: Bool = true,
    contextPolicy: CBORLDContextLoadingPolicy = .init(),
    contextDocumentLoader: CBORLDContextDocumentLoader? = nil
  ) {
    self.documentLoader = documentLoader
    self.typeTableLoader = typeTableLoader
    self.applicationContextMap = applicationContextMap
    self.limits = limits
    self.policy = policy
    self.diagnostic = diagnostic
    self.registryEntryLoader = registryEntryLoader
    self.callerProvidedTypeTable = callerProvidedTypeTable
    self.codecs = codecs
    self.allowsProvisionalRegistryEntries = allowsProvisionalRegistryEntries
    self.contextPolicy = contextPolicy
    self.contextDocumentLoader = contextDocumentLoader
  }

  /// Creates options from a complete parser configuration, such as
  /// ``CBORLDDecodingConfiguration/untrustedCompatible``.
  public init(
    configuration: CBORLDDecodingConfiguration,
    documentLoader: CBORLDDocumentLoader? = nil,
    typeTableLoader: CBORLDTypeTableLoader? = nil,
    applicationContextMap: [String: UInt64]? = nil,
    diagnostic: (@Sendable (String) -> Void)? = nil,
    registryEntryLoader: CBORLDRegistryEntryLoader? = nil,
    callerProvidedTypeTable: CBORLDTypeTable? = nil,
    codecs: [any CBORLDTypedValueCodec] = [],
    allowsProvisionalRegistryEntries: Bool = true,
    contextPolicy: CBORLDContextLoadingPolicy = .init(),
    contextDocumentLoader: CBORLDContextDocumentLoader? = nil
  ) {
    self.init(
      documentLoader: documentLoader,
      typeTableLoader: typeTableLoader,
      applicationContextMap: applicationContextMap,
      limits: configuration.limits,
      policy: configuration.policy,
      diagnostic: diagnostic,
      registryEntryLoader: registryEntryLoader,
      callerProvidedTypeTable: callerProvidedTypeTable,
      codecs: codecs,
      allowsProvisionalRegistryEntries: allowsProvisionalRegistryEntries,
      contextPolicy: contextPolicy,
      contextDocumentLoader: contextDocumentLoader)
  }

  /// The parser limits and representation policy as one value.
  public var configuration: CBORLDDecodingConfiguration {
    get { .init(limits: limits, policy: policy) }
    set {
      limits = newValue.limits
      policy = newValue.policy
    }
  }
}
