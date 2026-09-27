import CBORLD
import Foundation

// MARK: - Whole-document transformation

public enum CBORLDWholeDocumentTransformOperation: String, Sendable, Hashable, Codable,
  CaseIterable
{
  case encode
  case decode
}

/// A serializable, bounded configuration for whole-document family calls.
/// External contexts may be carried in `contextDocuments` or resolved by a
/// provider-specific asynchronous loader, but every such context must have a
/// matching entry in `requiredContextFingerprints`.
public struct CBORLDWholeDocumentTransformConfiguration: Sendable, Codable {
  public var format: CBORLDFormat
  public var serializationMode: CBORLDSerializationMode
  public var dictionary: CBORLDDocumentDictionary
  public var requiredDictionaryFingerprint: CBORLDDigest?
  public var contextDocuments: [String: JSONValue]
  public var requiredContextFingerprints: [String: CBORLDDigest]
  public var decodingLimits: CBORLDDecodingLimits
  public var maximumOutputBytes: Int

  public init(
    format: CBORLDFormat = .cborLD1,
    serializationMode: CBORLDSerializationMode = .compatibility,
    dictionary: CBORLDDocumentDictionary = .init(code: 0),
    requiredDictionaryFingerprint: CBORLDDigest? = nil,
    contextDocuments: [String: JSONValue] = [:],
    requiredContextFingerprints: [String: CBORLDDigest] = [:],
    decodingLimits: CBORLDDecodingLimits = .init(),
    maximumOutputBytes: Int = 64 * 1_024 * 1_024
  ) {
    self.format = format
    self.serializationMode = serializationMode
    self.dictionary = dictionary
    self.requiredDictionaryFingerprint = requiredDictionaryFingerprint
    self.contextDocuments = contextDocuments
    self.requiredContextFingerprints = requiredContextFingerprints
    self.decodingLimits = decodingLimits
    self.maximumOutputBytes = maximumOutputBytes
  }

  public func validate() throws {
    guard maximumOutputBytes >= 0 else {
      throw CBORLDError.invalidInput("maximumOutputBytes must not be negative.")
    }
    guard decodingLimits.maximumInputBytes >= 0,
      decodingLimits.maximumNestingDepth >= 0,
      decodingLimits.maximumContainerItems >= 0
    else {
      throw CBORLDError.invalidInput("Whole-document decoding limits must not be negative.")
    }
    try dictionary.validate()

    let hasApplicationDictionary =
      !dictionary.contexts.isEmpty || !dictionary.typedValues.isEmpty
      || !dictionary.uris.isEmpty || !dictionary.untypedValues.isEmpty
    if hasApplicationDictionary, requiredDictionaryFingerprint == nil {
      throw CBORLDError(
        code: .unpinnedDictionary,
        message: "Whole-document family requests must pin application dictionaries.")
    }
    if let requiredDictionaryFingerprint {
      try dictionary.verifyFingerprint(requiredDictionaryFingerprint)
    }

    for (url, document) in contextDocuments {
      guard let expected = requiredContextFingerprints[url] else {
        throw CBORLDError(
          code: .unpinnedContext,
          message: "Materialized context \"\(url)\" has no required fingerprint.")
      }
      try CBORLD.verifyContext(document, against: expected)
    }
    for (url, fingerprint) in requiredContextFingerprints {
      guard fingerprint.domain == .contextDocument, fingerprint.version == 1 else {
        throw CBORLDError(
          code: .invalidDigest,
          message: "Context pin for \"\(url)\" must be a version 1 context-document digest.")
      }
    }
  }
}

/// A transport-safe whole-document work item. Exactly one input field must be
/// present and it must agree with `operation`.
public struct CBORLDWholeDocumentTransformRequest: Sendable, Codable {
  public let operation: CBORLDWholeDocumentTransformOperation
  public let jsonLDDocument: JSONValue?
  public let cborldBytes: Data?
  public let configuration: CBORLDWholeDocumentTransformConfiguration

  public init(
    operation: CBORLDWholeDocumentTransformOperation,
    jsonLDDocument: JSONValue? = nil,
    cborldBytes: Data? = nil,
    configuration: CBORLDWholeDocumentTransformConfiguration = .init()
  ) {
    self.operation = operation
    self.jsonLDDocument = jsonLDDocument
    self.cborldBytes = cborldBytes
    self.configuration = configuration
  }

  public static func encoding(
    _ document: JSONValue,
    configuration: CBORLDWholeDocumentTransformConfiguration = .init()
  ) -> Self {
    .init(operation: .encode, jsonLDDocument: document, configuration: configuration)
  }

  public static func decoding(
    _ bytes: Data,
    configuration: CBORLDWholeDocumentTransformConfiguration = .init()
  ) -> Self {
    .init(operation: .decode, cborldBytes: bytes, configuration: configuration)
  }

  public func validate() throws {
    try configuration.validate()
    switch operation {
    case .encode:
      guard jsonLDDocument != nil, cborldBytes == nil else {
        throw CBORLDError.invalidInput(
          "An encode work item requires only a JSON-LD document input.")
      }
      let inputByteCount = try jsonLDDocument?.data().count ?? 0
      guard inputByteCount <= configuration.decodingLimits.maximumInputBytes else {
        throw CBORLDError(
          code: .resourceLimit,
          message: "JSON-LD input exceeds the whole-document input limit.")
      }
    case .decode:
      guard jsonLDDocument == nil, let cborldBytes else {
        throw CBORLDError.invalidInput(
          "A decode work item requires only a CBOR-LD byte input.")
      }
      guard cborldBytes.count <= configuration.decodingLimits.maximumInputBytes else {
        throw CBORLDError(
          code: .resourceLimit,
          message: "CBOR-LD input exceeds the whole-document input limit.")
      }
    }
  }
}

/// A whole-document result bound to the CBOR-LD transport bytes by SHA-256.
/// Encode returns only `cborldBytes`; decode returns only `jsonLDDocument`.
public struct CBORLDWholeDocumentTransformResult: Sendable, Codable {
  public let operation: CBORLDWholeDocumentTransformOperation
  public let jsonLDDocument: JSONValue?
  public let cborldBytes: Data?
  public let outputByteCount: Int
  public let transportDigest: CBORLDDigest
  public let inspection: CBORLDInspection

  public init(
    operation: CBORLDWholeDocumentTransformOperation,
    jsonLDDocument: JSONValue? = nil,
    cborldBytes: Data? = nil,
    outputByteCount: Int,
    transportDigest: CBORLDDigest,
    inspection: CBORLDInspection
  ) {
    self.operation = operation
    self.jsonLDDocument = jsonLDDocument
    self.cborldBytes = cborldBytes
    self.outputByteCount = outputByteCount
    self.transportDigest = transportDigest
    self.inspection = inspection
  }

  public func validate(for request: CBORLDWholeDocumentTransformRequest) throws {
    try request.validate()
    guard operation == request.operation, outputByteCount >= 0 else {
      throw invalidComputeOutput("Whole-document result does not match its work item.")
    }
    switch operation {
    case .encode:
      guard jsonLDDocument == nil, let cborldBytes,
        outputByteCount == cborldBytes.count,
        outputByteCount <= request.configuration.maximumOutputBytes
      else {
        throw invalidComputeOutput("Whole-document encode result has inconsistent output fields.")
      }
      do {
        try CBORLD.verify(cborldBytes, against: transportDigest)
        guard
          inspection
            == (try CBORLD.inspect(
              cborldBytes,
              limits: request.configuration.decodingLimits))
        else {
          throw invalidComputeOutput("Whole-document encode inspection metadata is inconsistent.")
        }
      } catch {
        if let error = error as? CBORLDError, error.code == .invalidComputeOutput {
          throw error
        }
        throw invalidComputeOutput(
          "Whole-document encode result is not bound to valid CBOR-LD inspection metadata.")
      }
    case .decode:
      guard cborldBytes == nil, let jsonLDDocument,
        let input = request.cborldBytes,
        outputByteCount == (try? jsonLDDocument.data().count),
        outputByteCount <= request.configuration.maximumOutputBytes
      else {
        throw invalidComputeOutput("Whole-document decode result has inconsistent output fields.")
      }
      do {
        try CBORLD.verify(input, against: transportDigest)
        guard
          inspection
            == (try CBORLD.inspect(
              input,
              limits: request.configuration.decodingLimits))
        else {
          throw invalidComputeOutput("Whole-document decode inspection metadata is inconsistent.")
        }
      } catch {
        if let error = error as? CBORLDError, error.code == .invalidComputeOutput {
          throw error
        }
        throw invalidComputeOutput(
          "Whole-document decode result is not bound to valid CBOR-LD inspection metadata.")
      }
    }
  }
}

public protocol CBORLDWholeDocumentTransformComputing: Sendable {
  func batchedWholeDocumentTransform(
    _ requests: [CBORLDWholeDocumentTransformRequest]
  ) async throws -> [CBORLDWholeDocumentTransformResult]
}

// MARK: - CDDL parsing and validation

public enum CBORLDCDDLDocumentEncoding: String, Sendable, Hashable, Codable, CaseIterable {
  case cbor
  case json
}

public enum CBORLDCDDLRegexPolicy: String, Sendable, Hashable, Codable, CaseIterable {
  case disabled
  case anchoredOnly = "anchored-only"
  case enabled
}

public struct CBORLDCDDLValidationLimits: Sendable, Hashable, Codable {
  public var maximumSchemaBytes: Int
  public var maximumDocumentBytes: Int
  public var maximumASTNodes: Int
  public var maximumRecursionDepth: Int
  public var maximumDiagnostics: Int
  public var regexPolicy: CBORLDCDDLRegexPolicy

  public init(
    maximumSchemaBytes: Int = 1_048_576,
    maximumDocumentBytes: Int = 64 * 1_024 * 1_024,
    maximumASTNodes: Int = 1_000_000,
    maximumRecursionDepth: Int = 256,
    maximumDiagnostics: Int = 100,
    regexPolicy: CBORLDCDDLRegexPolicy = .disabled
  ) {
    self.maximumSchemaBytes = maximumSchemaBytes
    self.maximumDocumentBytes = maximumDocumentBytes
    self.maximumASTNodes = maximumASTNodes
    self.maximumRecursionDepth = maximumRecursionDepth
    self.maximumDiagnostics = maximumDiagnostics
    self.regexPolicy = regexPolicy
  }

  public func validate() throws {
    guard maximumSchemaBytes >= 0, maximumDocumentBytes >= 0,
      maximumASTNodes >= 0, maximumRecursionDepth >= 0, maximumDiagnostics >= 0
    else {
      throw CBORLDError.invalidInput("CDDL validation limits must not be negative.")
    }
  }
}

public struct CBORLDCDDLValidationRequest: Sendable, Hashable, Codable {
  public let schema: String
  public let rootRule: String?
  public let document: Data
  public let documentEncoding: CBORLDCDDLDocumentEncoding
  public let limits: CBORLDCDDLValidationLimits

  public init(
    schema: String,
    rootRule: String? = nil,
    document: Data,
    documentEncoding: CBORLDCDDLDocumentEncoding,
    limits: CBORLDCDDLValidationLimits = .init()
  ) {
    self.schema = schema
    self.rootRule = rootRule
    self.document = document
    self.documentEncoding = documentEncoding
    self.limits = limits
  }

  public var schemaByteCount: Int { schema.utf8.count }

  public func validate() throws {
    try limits.validate()
    guard !schema.isEmpty else {
      throw CBORLDError.invalidInput("A CDDL work item requires a non-empty schema.")
    }
    guard schemaByteCount <= limits.maximumSchemaBytes else {
      throw CBORLDError(code: .resourceLimit, message: "CDDL schema exceeds its limit.")
    }
    guard document.count <= limits.maximumDocumentBytes else {
      throw CBORLDError(code: .resourceLimit, message: "CDDL document exceeds its limit.")
    }
    if let rootRule, rootRule.isEmpty {
      throw CBORLDError.invalidInput("CDDL rootRule must be nil or non-empty.")
    }
  }
}

public enum CBORLDCDDLDiagnosticSeverity: String, Sendable, Hashable, Codable, CaseIterable {
  case error
  case warning
  case information
}

public enum CBORLDCDDLDiagnosticPhase: String, Sendable, Hashable, Codable, CaseIterable {
  case lexing
  case parsing
  case control
  case validation
}

/// Diagnostic offsets are UTF-8 byte offsets. EOF diagnostics may equal the
/// corresponding input byte count.
public struct CBORLDCDDLDiagnostic: Sendable, Hashable, Codable {
  public let code: String
  public let severity: CBORLDCDDLDiagnosticSeverity
  public let phase: CBORLDCDDLDiagnosticPhase
  public let message: String
  public let path: String?
  public let rule: String?
  public let schemaByteOffset: Int?
  public let documentByteOffset: Int?

  public init(
    code: String,
    severity: CBORLDCDDLDiagnosticSeverity,
    phase: CBORLDCDDLDiagnosticPhase,
    message: String,
    path: String? = nil,
    rule: String? = nil,
    schemaByteOffset: Int? = nil,
    documentByteOffset: Int? = nil
  ) {
    self.code = code
    self.severity = severity
    self.phase = phase
    self.message = message
    self.path = path
    self.rule = rule
    self.schemaByteOffset = schemaByteOffset
    self.documentByteOffset = documentByteOffset
  }
}

public struct CBORLDCDDLValidationResult: Sendable, Hashable, Codable {
  public let schemaByteCount: Int
  public let documentByteCount: Int
  public let schemaIsValid: Bool
  public let documentIsValid: Bool
  public let astNodeCount: Int
  public let maximumValidationDepth: Int
  public let flatInstructionCount: Int?
  public let failedInstructionIndex: Int?
  public let diagnostics: [CBORLDCDDLDiagnostic]

  public init(
    schemaByteCount: Int,
    documentByteCount: Int,
    schemaIsValid: Bool,
    documentIsValid: Bool,
    astNodeCount: Int,
    maximumValidationDepth: Int,
    flatInstructionCount: Int? = nil,
    failedInstructionIndex: Int? = nil,
    diagnostics: [CBORLDCDDLDiagnostic]
  ) {
    self.schemaByteCount = schemaByteCount
    self.documentByteCount = documentByteCount
    self.schemaIsValid = schemaIsValid
    self.documentIsValid = documentIsValid
    self.astNodeCount = astNodeCount
    self.maximumValidationDepth = maximumValidationDepth
    self.flatInstructionCount = flatInstructionCount
    self.failedInstructionIndex = failedInstructionIndex
    self.diagnostics = diagnostics
  }

  public func validate(for request: CBORLDCDDLValidationRequest) throws {
    try request.validate()
    guard schemaByteCount == request.schemaByteCount,
      documentByteCount == request.document.count,
      astNodeCount >= 0,
      astNodeCount <= request.limits.maximumASTNodes,
      maximumValidationDepth >= 0,
      maximumValidationDepth <= request.limits.maximumRecursionDepth,
      diagnostics.count <= request.limits.maximumDiagnostics
    else {
      throw invalidComputeOutput("CDDL result metrics do not match their bounded work item.")
    }
    guard !documentIsValid || schemaIsValid else {
      throw invalidComputeOutput("A document cannot validate against an invalid CDDL schema.")
    }
    if schemaIsValid, astNodeCount == 0 {
      throw invalidComputeOutput("A valid CDDL schema must report at least one AST node.")
    }
    if !schemaIsValid || !documentIsValid {
      guard diagnostics.contains(where: { $0.severity == .error }) else {
        throw invalidComputeOutput("An invalid CDDL result must contain an error diagnostic.")
      }
    }
    switch (flatInstructionCount, failedInstructionIndex) {
    case (nil, nil):
      break
    case (.some(let count), let failure):
      guard count > 0 else {
        throw invalidComputeOutput("A CDDL flat plan must contain at least one instruction.")
      }
      if let failure, !(0..<count).contains(failure) {
        throw invalidComputeOutput("CDDL failed-instruction index is outside its flat plan.")
      }
    case (nil, .some):
      throw invalidComputeOutput("A CDDL failure index requires a flat instruction count.")
    }
    for diagnostic in diagnostics {
      guard !diagnostic.code.isEmpty, !diagnostic.message.isEmpty else {
        throw invalidComputeOutput("CDDL diagnostics require non-empty codes and messages.")
      }
      if diagnostic.path?.isEmpty == true || diagnostic.rule?.isEmpty == true {
        throw invalidComputeOutput("CDDL diagnostic path and rule must be nil or non-empty.")
      }
      if let offset = diagnostic.schemaByteOffset,
        !(0...schemaByteCount).contains(offset)
      {
        throw invalidComputeOutput("CDDL diagnostic schema offset is out of range.")
      }
      if let offset = diagnostic.documentByteOffset,
        !(0...documentByteCount).contains(offset)
      {
        throw invalidComputeOutput("CDDL diagnostic document offset is out of range.")
      }
    }
  }
}

public protocol CBORLDCDDLValidationComputing: Sendable {
  func batchedCDDLValidation(
    _ requests: [CBORLDCDDLValidationRequest]
  ) async throws -> [CBORLDCDDLValidationResult]
}

/// Implement this small interface with cddl-rs or another independent CPU
/// parser. The Swift package intentionally does not silently substitute its
/// CBOR structural scanner for grammar and semantic CDDL validation.
public protocol CBORLDCDDLCPUOracle: Sendable {
  func validateCDDL(
    _ request: CBORLDCDDLValidationRequest
  ) async throws -> CBORLDCDDLValidationResult
}

// MARK: - Acceptance and CPU reference

extension CBORLD {
  public static func batchedWholeDocumentTransform<Provider: CBORLDWholeDocumentTransformComputing>(
    _ requests: [CBORLDWholeDocumentTransformRequest],
    using provider: Provider
  ) async throws -> [CBORLDWholeDocumentTransformResult] {
    for request in requests { try request.validate() }
    let results = try await provider.batchedWholeDocumentTransform(requests)
    guard results.count == requests.count else {
      throw invalidComputeOutput("Whole-document backend returned the wrong number of work items.")
    }
    for index in requests.indices { try results[index].validate(for: requests[index]) }
    return results
  }

  public static func batchedCDDLValidation<Provider: CBORLDCDDLValidationComputing>(
    _ requests: [CBORLDCDDLValidationRequest],
    using provider: Provider
  ) async throws -> [CBORLDCDDLValidationResult] {
    for request in requests { try request.validate() }
    let results = try await provider.batchedCDDLValidation(requests)
    guard results.count == requests.count else {
      throw invalidComputeOutput("CDDL backend returned the wrong number of work items.")
    }
    for index in requests.indices { try results[index].validate(for: requests[index]) }
    return results
  }
}

extension CBORLDCPUComputeProvider {
  public func batchedWholeDocumentTransform(
    _ requests: [CBORLDWholeDocumentTransformRequest]
  ) async throws -> [CBORLDWholeDocumentTransformResult] {
    var results: [CBORLDWholeDocumentTransformResult] = []
    results.reserveCapacity(requests.count)
    for request in requests {
      try request.validate()
      let configuration = request.configuration
      let contextRegistry = CBORLDContextRegistry(
        documents: configuration.contextDocuments,
        expectedFingerprints: configuration.requiredContextFingerprints,
        fallback: wholeDocumentLoader)

      switch request.operation {
      case .encode:
        guard let document = request.jsonLDDocument else {
          throw CBORLDError.invalidInput("Missing JSON-LD encode input.")
        }
        // The output bound is enforced while bytes are produced; the writer
        // refuses to grow past it rather than checking a finished buffer.
        let encoder = CBORLDEncoder(
          format: configuration.format,
          serializationMode: configuration.serializationMode,
          dictionary: configuration.dictionary,
          documentLoader: contextRegistry.documentLoader,
          limits: CBORLDEncodingLimits(maximumOutputBytes: configuration.maximumOutputBytes))
        let bytes = try await encoder.encode(document)
        guard bytes.count <= configuration.maximumOutputBytes else {
          throw CBORLDError(
            code: .resourceLimit,
            message: "CBOR-LD output exceeds the whole-document output limit.")
        }
        results.append(
          .init(
            operation: .encode,
            cborldBytes: bytes,
            outputByteCount: bytes.count,
            transportDigest: CBORLD.transportDigest(of: bytes),
            inspection: try CBORLD.inspect(bytes, limits: configuration.decodingLimits)))
      case .decode:
        guard let bytes = request.cborldBytes else {
          throw CBORLDError.invalidInput("Missing CBOR-LD decode input.")
        }
        let dictionaryPin: [UInt64: CBORLDDigest]
        if let fingerprint = configuration.requiredDictionaryFingerprint {
          dictionaryPin = [configuration.dictionary.code: fingerprint]
        } else {
          dictionaryPin = [:]
        }
        let decoder = CBORLDDecoder(
          supportedFormats: [configuration.format],
          dictionaries: [configuration.dictionary],
          requiredDictionaryFingerprints: dictionaryPin,
          legacyApplicationContextMap: configuration.dictionary.contexts,
          documentLoader: contextRegistry.documentLoader,
          limits: configuration.decodingLimits)
        let document = try await decoder.decode(bytes)
        let outputByteCount = try document.data().count
        guard outputByteCount <= configuration.maximumOutputBytes else {
          throw CBORLDError(
            code: .resourceLimit,
            message: "JSON-LD output exceeds the whole-document output limit.")
        }
        results.append(
          .init(
            operation: .decode,
            jsonLDDocument: document,
            outputByteCount: outputByteCount,
            transportDigest: CBORLD.transportDigest(of: bytes),
            inspection: try CBORLD.inspect(bytes, limits: configuration.decodingLimits)))
      }
    }
    return results
  }

  public func batchedCDDLValidation(
    _ requests: [CBORLDCDDLValidationRequest]
  ) async throws -> [CBORLDCDDLValidationResult] {
    guard let cddlOracle else {
      throw CBORLDError(
        code: .computeFamilyUnavailable,
        message: "CDDL validation requires an explicitly injected independent CPU oracle.")
    }
    var results: [CBORLDCDDLValidationResult] = []
    results.reserveCapacity(requests.count)
    for request in requests {
      try request.validate()
      let result = try await cddlOracle.validateCDDL(request)
      try result.validate(for: request)
      results.append(result)
    }
    return results
  }
}
