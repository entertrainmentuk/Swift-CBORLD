import Foundation

/// An open, stable error-code vocabulary.
///
/// Raw values match the JavaScript reference processor wherever it defines a
/// code, so logs and cross-implementation fixtures keep comparing equal. The
/// type is deliberately open: an unrecognized raw value is preserved rather
/// than rejected, and string literals convert implicitly.
///
/// ```swift
/// do {
///   _ = try await decoder.decode(bytes)
/// } catch let error as CBORLDError where error.code == .resourceLimit {
///   // Reject the input without retrying.
/// }
/// ```
public struct CBORLDErrorCode: RawRepresentable, Sendable, Hashable, Codable,
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

  /// Whether the dated CBOR-LD 1.0 editor's draft defines this error name.
  public var isDefinedBySpecification: Bool {
    Self.specificationCodes.contains(self)
  }

  /// Error names defined by the CBOR-LD 1.0 editor's draft that this package
  /// targets (w3c/cbor-ld revision `992f9335703c`).
  public static let specificationCodes: Set<Self> = [
    .invalidEncodedContext,
    .unknownCBORLDTermID,
    .unknownCompressedValue,
    .invalidPayloadStructure,
    .nonCBORLDTag,
    .protectedTermRedefinition,
    .undefinedCompressedContext,
    .unsupportedJSONType,
  ]
}

extension CBORLDErrorCode {
  // MARK: Envelope and CBOR parsing

  /// Input is not a well-formed CBOR-LD envelope. This is the JavaScript
  /// processor's code for every envelope and CBOR syntax failure.
  public static let notCBORLD: Self = "ERR_NOT_CBORLD"
  /// The editor's-draft name for an unrecognized CBOR tag.
  public static let nonCBORLDTag: Self = "ERR_NON_CBOR_LD_TAG"
  /// The editor's-draft name for a tag whose content is not
  /// `[registryEntryId, payload]`.
  public static let invalidPayloadStructure: Self = "ERR_INVALID_PAYLOAD_STRUCTURE"
  /// Raw CBOR rejected by a compute-family structural scanner.
  public static let notCBOR: Self = "ERR_NOT_CBOR"
  public static let invalidInput: Self = "ERR_INVALID_INPUT"
  /// A configured parser, encoder, context, or batch bound was reached.
  public static let resourceLimit: Self = "ERR_RESOURCE_LIMIT"
  public static let nonPreferredInteger: Self = "ERR_NON_PREFERRED_INTEGER"
  public static let nonPreferredLength: Self = "ERR_NON_PREFERRED_LENGTH"
  public static let nonPreferredFloat: Self = "ERR_NON_PREFERRED_FLOAT"
  public static let nonPreferredCBOR: Self = "ERR_NON_PREFERRED_CBOR"
  public static let reservedSimpleValue: Self = "ERR_RESERVED_SIMPLE_VALUE"
  public static let policyMismatch: Self = "ERR_POLICY_MISMATCH"
  public static let unsupportedFormat: Self = "ERR_UNSUPPORTED_FORMAT"

  // MARK: Semantic transformation

  public static let invalidEncodedContext: Self = "ERR_INVALID_ENCODED_CONTEXT"
  public static let unknownCBORLDTermID: Self = "ERR_UNKNOWN_CBORLD_TERM_ID"
  public static let unknownCompressedValue: Self = "ERR_UNKNOWN_COMPRESSED_VALUE"
  public static let undefinedCompressedContext: Self = "ERR_UNDEFINED_COMPRESSED_CONTEXT"
  public static let unsupportedJSONType: Self = "ERR_UNSUPPORTED_JSON_TYPE"
  public static let protectedTermRedefinition: Self = "ERR_PROTECTED_TERM_REDEFINITION"
  public static let invalidContext: Self = "ERR_INVALID_CONTEXT"
  public static let invalidTermDefinition: Self = "ERR_INVALID_TERM_DEFINITION"
  public static let unknownContext: Self = "ERR_UNKNOWN_CONTEXT"
  public static let noDocumentLoader: Self = "ERR_NO_DOCUMENT_LOADER"
  public static let compressionValueTooLarge: Self = "ERR_COMPRESSION_VALUE_TOO_LARGE"
  public static let unrecognizedBytes: Self = "ERR_UNRECOGNIZED_BYTES"
  /// A value cannot be represented without ambiguity by the selected
  /// processing model.
  public static let ambiguousValue: Self = "ERR_AMBIGUOUS_VALUE"

  // MARK: Registry entries, processing models, and codecs

  public static let noTypeTable: Self = "ERR_NO_TYPETABLE"
  public static let invalidTypeTable: Self = "ERR_INVALID_TYPETABLE"
  public static let unsupportedLiteralType: Self = "ERR_UNSUPPORTED_LITERAL_TYPE"
  public static let invalidRegistryEntry: Self = "ERR_INVALID_REGISTRY_ENTRY"
  public static let provisionalRegistryEntry: Self = "ERR_PROVISIONAL_REGISTRY_ENTRY"
  public static let invalidProcessingModel: Self = "ERR_INVALID_PROCESSING_MODEL"
  /// A processing model names a codec that is neither built in nor supplied.
  public static let unknownCodec: Self = "ERR_UNKNOWN_CODEC"
  /// A user-supplied codec produced output that does not decode to its input.
  public static let codecNotInvertible: Self = "ERR_CODEC_NOT_INVERTIBLE"

  // MARK: Context resolution

  /// A context URL, redirect, or media type is outside the configured policy.
  public static let contextNotAllowed: Self = "ERR_CONTEXT_NOT_ALLOWED"
  public static let unpinnedContext: Self = "ERR_UNPINNED_CONTEXT"

  // MARK: Integrity

  public static let integrityMismatch: Self = "ERR_INTEGRITY_MISMATCH"
  public static let invalidDigest: Self = "ERR_INVALID_DIGEST"
  public static let invalidManifest: Self = "ERR_INVALID_MANIFEST"
  public static let invalidDictionary: Self = "ERR_INVALID_DICTIONARY"
  public static let unpinnedDictionary: Self = "ERR_UNPINNED_DICTIONARY"

  // MARK: Batch execution

  public static let batchLimit: Self = "ERR_BATCH_LIMIT"
  public static let batchItem: Self = "ERR_BATCH_ITEM"
  public static let invalidExecutionPolicy: Self = "ERR_INVALID_EXECUTION_POLICY"

  // MARK: Compute families

  public static let invalidComputeOutput: Self = "ERR_INVALID_COMPUTE_OUTPUT"
  public static let computeFamilyUnavailable: Self = "ERR_COMPUTE_FAMILY_UNAVAILABLE"
  public static let integerOverflow: Self = "ERR_INTEGER_OVERFLOW"
  /// A candidate compute backend disagreed with its CPU reference.
  public static let shadowParityMismatch: Self = "ERR_SHADOW_PARITY_MISMATCH"
}

/// Machine-readable location and policy information attached to parser errors.
public struct CBORLDSourceDiagnostic: Sendable, Hashable, Codable, CustomStringConvertible {
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

  public var description: String {
    var parts = ["byte offset \(byteOffset)"]
    if let endOffset { parts[0] += "..<\(endOffset)" }
    if let majorType, let additionalInformation {
      parts.append("major type \(majorType), additional information \(additionalInformation)")
    }
    if let violation { parts.append(violation) }
    if let relatedByteOffset { parts.append("related byte offset \(relatedByteOffset)") }
    if let jsonPath {
      parts.append("JSON path \(jsonPath)")
    } else if !containerPath.isEmpty {
      parts.append("CBOR path \(containerPath.joined())")
    }
    return parts.joined(separator: "; ")
  }
}

/// A processor error with the same stable error-code vocabulary as the
/// JavaScript implementation.
public struct CBORLDError: Error, Sendable, Equatable, CustomStringConvertible, LocalizedError {
  public let code: CBORLDErrorCode
  public let message: String
  public let diagnostic: CBORLDSourceDiagnostic?
  private let explicitSpecificationCode: CBORLDErrorCode?

  public init(
    code: CBORLDErrorCode,
    message: String,
    diagnostic: CBORLDSourceDiagnostic? = nil,
    specificationCode: CBORLDErrorCode? = nil
  ) {
    self.code = code
    self.message = message
    self.diagnostic = diagnostic
    self.explicitSpecificationCode = specificationCode
  }

  /// The CBOR-LD editor's-draft name for this failure, when the draft names
  /// one. Envelope failures keep the JavaScript-compatible ``code``
  /// `ERR_NOT_CBORLD` and report the draft's more specific
  /// `ERR_NON_CBOR_LD_TAG` or `ERR_INVALID_PAYLOAD_STRUCTURE` here instead of
  /// silently changing the established code.
  public var specificationCode: CBORLDErrorCode? {
    explicitSpecificationCode ?? (code.isDefinedBySpecification ? code : nil)
  }

  public var description: String { "\(code): \(message)" }

  public var errorDescription: String? { message }

  public var failureReason: String? { diagnostic?.description }
}

extension CBORLDError {
  static func invalidInput(_ message: String) -> Self {
    .init(code: .invalidInput, message: message)
  }

  static func resourceLimit(_ message: String) -> Self {
    .init(code: .resourceLimit, message: message)
  }
}
