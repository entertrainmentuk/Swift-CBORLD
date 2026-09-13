import Foundation

/// Stable envelope facts suitable for persistence in an integrity manifest.
/// Unlike `CBORLDInspection`, this type deliberately excludes a payload preview.
public struct CBORLDEnvelopeMetadata: Sendable, Hashable, Codable {
  public let format: CBORLDFormat
  public let registryEntryID: UInt64?
  public let payloadIsCompressed: Bool
  public let byteCount: Int

  public init(
    format: CBORLDFormat,
    registryEntryID: UInt64?,
    payloadIsCompressed: Bool,
    byteCount: Int
  ) {
    self.format = format
    self.registryEntryID = registryEntryID
    self.payloadIsCompressed = payloadIsCompressed
    self.byteCount = byteCount
  }

  public init(inspection: CBORLDInspection) {
    self.init(
      format: inspection.format,
      registryEntryID: inspection.registryEntryID,
      payloadIsCompressed: inspection.payloadIsCompressed,
      byteCount: inspection.byteCount)
  }
}

/// Binds a document-dictionary registry identifier to its immutable fingerprint.
public struct CBORLDDictionaryBinding: Sendable, Hashable, Codable {
  public let registryEntryID: UInt64
  public let fingerprint: CBORLDDigest

  public init(registryEntryID: UInt64, fingerprint: CBORLDDigest) {
    self.registryEntryID = registryEntryID
    self.fingerprint = fingerprint
  }
}

/// An optional sidecar description of the integrity properties expected for one
/// CBOR-LD artifact. It is not embedded in the CBOR-LD wire envelope and does
/// not contain authentication or signature material.
public struct CBORLDIntegrityManifest: Sendable, Hashable, Codable {
  public static let currentFormatVersion: UInt16 = 1

  public let formatVersion: UInt16
  public let createdAt: Date
  public let artifactName: String?
  public let producer: String?
  public let envelope: CBORLDEnvelopeMetadata
  public let transportDigest: CBORLDDigest
  public let structuralFingerprint: CBORLDDigest?
  public let dictionaryBinding: CBORLDDictionaryBinding?
  public let contextFingerprints: [String: CBORLDDigest]
  /// The mode asserted by the producer, if known. Verification does not infer
  /// this value from bytes or treat it as an authentication claim.
  public let declaredSerializationMode: CBORLDSerializationMode?
  public let notes: [String]

  public init(
    formatVersion: UInt16 = Self.currentFormatVersion,
    createdAt: Date = Date(),
    artifactName: String? = nil,
    producer: String? = nil,
    envelope: CBORLDEnvelopeMetadata,
    transportDigest: CBORLDDigest,
    structuralFingerprint: CBORLDDigest? = nil,
    dictionaryBinding: CBORLDDictionaryBinding? = nil,
    contextFingerprints: [String: CBORLDDigest] = [:],
    declaredSerializationMode: CBORLDSerializationMode? = nil,
    notes: [String] = []
  ) {
    self.formatVersion = formatVersion
    self.createdAt = createdAt
    self.artifactName = artifactName
    self.producer = producer
    self.envelope = envelope
    self.transportDigest = transportDigest
    self.structuralFingerprint = structuralFingerprint
    self.dictionaryBinding = dictionaryBinding
    self.contextFingerprints = contextFingerprints
    self.declaredSerializationMode = declaredSerializationMode
    self.notes = notes
  }

  /// Validates manifest structure and digest domains. This checks internal
  /// consistency only; use `verificationReport(for:against:)` to check bytes.
  public func validate() throws {
    guard formatVersion == Self.currentFormatVersion else {
      throw CBORLDError(
        code: "ERR_INVALID_MANIFEST",
        message: "Unsupported integrity manifest version \(formatVersion).")
    }
    guard envelope.byteCount >= 0 else {
      throw CBORLDError(
        code: "ERR_INVALID_MANIFEST",
        message: "Integrity manifest byteCount must not be negative.")
    }
    if let artifactName, artifactName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      throw CBORLDError(
        code: "ERR_INVALID_MANIFEST",
        message: "Integrity manifest artifactName must not be empty.")
    }
    try Self.requireDigest(
      transportDigest,
      domain: .encodedBytes,
      field: "transportDigest")
    if let structuralFingerprint {
      try Self.requireDigest(
        structuralFingerprint,
        domain: .documentStructure,
        field: "structuralFingerprint")
    }
    if let dictionaryBinding {
      guard dictionaryBinding.registryEntryID <= CBORLDConstants.maximumSafeInteger else {
        throw CBORLDError(
          code: "ERR_INVALID_MANIFEST",
          message: "Dictionary registry entry exceeds the CBOR-LD safe-integer limit.")
      }
      try Self.requireDigest(
        dictionaryBinding.fingerprint,
        domain: .documentDictionary,
        field: "dictionaryBinding.fingerprint")
      if envelope.format != .legacySingleton,
        envelope.registryEntryID != dictionaryBinding.registryEntryID
      {
        throw CBORLDError(
          code: "ERR_INVALID_MANIFEST",
          message: "Dictionary binding does not match the envelope registry entry.")
      }
    }
    for (url, fingerprint) in contextFingerprints {
      guard !url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        throw CBORLDError(
          code: "ERR_INVALID_MANIFEST",
          message: "Context fingerprint URL must not be empty.")
      }
      try Self.requireDigest(
        fingerprint,
        domain: .contextDocument,
        field: "contextFingerprints[\(url)]")
    }
  }

  private static func requireDigest(
    _ digest: CBORLDDigest,
    domain: CBORLDHashDomain,
    field: String
  ) throws {
    guard digest.domain == domain, digest.version == 1 else {
      throw CBORLDError(
        code: "ERR_INVALID_MANIFEST",
        message: "\(field) must be a version 1 \(domain.rawValue) digest.")
    }
  }
}

/// The subject of one independently reported integrity check.
public enum CBORLDVerificationKind: String, Sendable, Hashable, Codable, CaseIterable {
  case manifest
  case envelope
  case envelopeMetadata = "envelope-metadata"
  case formatSupport = "format-support"
  case transportDigest = "transport-digest"
  case documentDictionary = "document-dictionary"
  case contextDocument = "context-document"
  case documentDecoding = "document-decoding"
  case structuralFingerprint = "structural-fingerprint"
}

/// A verification result that preserves the distinction between failure and a
/// check that was not requested or could not be performed.
public enum CBORLDVerificationStatus: String, Sendable, Hashable, Codable, CaseIterable {
  case verified
  case mismatch
  case invalid
  case notChecked = "not-checked"
  case unavailable
}

public struct CBORLDVerificationCheck: Sendable, Hashable, Codable {
  public let kind: CBORLDVerificationKind
  public let subject: String?
  public let status: CBORLDVerificationStatus
  public let expectedDigest: CBORLDDigest?
  public let observedDigest: CBORLDDigest?
  public let message: String

  public init(
    kind: CBORLDVerificationKind,
    subject: String? = nil,
    status: CBORLDVerificationStatus,
    expectedDigest: CBORLDDigest? = nil,
    observedDigest: CBORLDDigest? = nil,
    message: String
  ) {
    self.kind = kind
    self.subject = subject
    self.status = status
    self.expectedDigest = expectedDigest
    self.observedDigest = observedDigest
    self.message = message
  }
}

/// Inputs used to verify one CBOR-LD artifact. Expectations are explicit;
/// absent digest expectations are reported as `notChecked`.
public struct CBORLDVerificationPolicy: Sendable {
  public var expectedEnvelope: CBORLDEnvelopeMetadata?
  public var expectedTransportDigest: CBORLDDigest?
  public var expectedStructuralFingerprint: CBORLDDigest?
  public var dictionaries: [CBORLDDocumentDictionary]
  public var requiredDictionaryFingerprints: [UInt64: CBORLDDigest]
  public var contextRegistry: CBORLDContextRegistry?
  public var expectedContextFingerprints: [String: CBORLDDigest]
  public var supportedFormats: Set<CBORLDFormat>
  public var legacyApplicationContextMap: [String: UInt64]?
  public var limits: CBORLDDecodingLimits

  public init(
    expectedEnvelope: CBORLDEnvelopeMetadata? = nil,
    expectedTransportDigest: CBORLDDigest? = nil,
    expectedStructuralFingerprint: CBORLDDigest? = nil,
    dictionaries: [CBORLDDocumentDictionary] = [.unregistered],
    requiredDictionaryFingerprints: [UInt64: CBORLDDigest] = [:],
    contextRegistry: CBORLDContextRegistry? = nil,
    expectedContextFingerprints: [String: CBORLDDigest] = [:],
    supportedFormats: Set<CBORLDFormat> = Set(CBORLDFormat.allCases),
    legacyApplicationContextMap: [String: UInt64]? = nil,
    limits: CBORLDDecodingLimits = .init()
  ) {
    self.expectedEnvelope = expectedEnvelope
    self.expectedTransportDigest = expectedTransportDigest
    self.expectedStructuralFingerprint = expectedStructuralFingerprint
    self.dictionaries = dictionaries
    self.requiredDictionaryFingerprints = requiredDictionaryFingerprints
    self.contextRegistry = contextRegistry
    self.expectedContextFingerprints = expectedContextFingerprints
    self.supportedFormats = supportedFormats
    self.legacyApplicationContextMap = legacyApplicationContextMap
    self.limits = limits
  }
}

/// A complete, inspectable verification outcome. `isValid` is false for every
/// mismatch, invalid input, or required check that was unavailable.
public struct CBORLDVerificationReport: Sendable, Hashable, Codable {
  public let checkedAt: Date
  public let inspection: CBORLDInspection?
  public let checks: [CBORLDVerificationCheck]
  public let warnings: [String]

  public init(
    checkedAt: Date = Date(),
    inspection: CBORLDInspection?,
    checks: [CBORLDVerificationCheck],
    warnings: [String] = []
  ) {
    self.checkedAt = checkedAt
    self.inspection = inspection
    self.checks = checks
    self.warnings = warnings
  }

  public var isValid: Bool {
    checks.allSatisfy { $0.status == .verified || $0.status == .notChecked }
  }

  public var problems: [CBORLDVerificationCheck] {
    checks.filter { $0.status != .verified && $0.status != .notChecked }
  }
}

extension CBORLD {
  /// Creates a versioned sidecar manifest without modifying the CBOR-LD bytes.
  /// Context documents must be supplied explicitly so the manifest does not
  /// perform hidden network access or claim to pin contexts it did not inspect.
  public static func integrityManifest(
    for data: Data,
    document: JSONValue? = nil,
    dictionary: CBORLDDocumentDictionary? = nil,
    contextDocuments: [String: JSONValue] = [:],
    declaredSerializationMode: CBORLDSerializationMode? = nil,
    artifactName: String? = nil,
    producer: String? = nil,
    createdAt: Date = Date(),
    notes: [String] = [],
    limits: CBORLDDecodingLimits = .init()
  ) throws -> CBORLDIntegrityManifest {
    let inspection = try inspect(data, limits: limits)
    let structuralFingerprint = try document.map { try self.structuralFingerprint(of: $0) }
    let dictionaryBinding: CBORLDDictionaryBinding?
    if let dictionary {
      try dictionary.validate()
      if inspection.format != .legacySingleton,
        inspection.registryEntryID != dictionary.code
      {
        throw CBORLDError(
          code: "ERR_INVALID_MANIFEST",
          message: "Dictionary code does not match the encoded registry entry.")
      }
      dictionaryBinding = try CBORLDDictionaryBinding(
        registryEntryID: dictionary.code,
        fingerprint: dictionary.fingerprint())
    } else {
      dictionaryBinding = nil
    }

    var contextFingerprints: [String: CBORLDDigest] = [:]
    for (url, context) in contextDocuments {
      contextFingerprints[url] = try contextFingerprint(of: context)
    }

    let manifest = CBORLDIntegrityManifest(
      createdAt: createdAt,
      artifactName: artifactName,
      producer: producer,
      envelope: CBORLDEnvelopeMetadata(inspection: inspection),
      transportDigest: inspection.transportDigest,
      structuralFingerprint: structuralFingerprint,
      dictionaryBinding: dictionaryBinding,
      contextFingerprints: contextFingerprints,
      declaredSerializationMode: declaredSerializationMode,
      notes: notes)
    try manifest.validate()
    return manifest
  }

  /// Verifies all configured layers and returns every independently observable
  /// result instead of throwing at the first mismatch.
  public static func verificationReport(
    for data: Data,
    policy: CBORLDVerificationPolicy = .init()
  ) async -> CBORLDVerificationReport {
    var checks: [CBORLDVerificationCheck] = []
    var warnings: [String] = []
    let inspection: CBORLDInspection
    do {
      inspection = try inspect(data, limits: policy.limits)
      checks.append(
        .init(kind: .envelope, status: .verified, message: "CBOR-LD envelope is well formed."))
    } catch {
      checks.append(
        .init(
          kind: .envelope,
          status: .invalid,
          message: "CBOR-LD envelope could not be inspected: \(error)"))
      appendUnavailableChecks(afterEnvelopeFailureTo: &checks, policy: policy)
      return CBORLDVerificationReport(inspection: nil, checks: checks, warnings: warnings)
    }

    if let expectedEnvelope = policy.expectedEnvelope {
      let observed = CBORLDEnvelopeMetadata(inspection: inspection)
      checks.append(
        .init(
          kind: .envelopeMetadata,
          status: observed == expectedEnvelope ? .verified : .mismatch,
          message: observed == expectedEnvelope
            ? "Envelope metadata matches the expected values."
            : "Envelope format, registry entry, compression state, or byte count differs from the expected values."
        ))
    } else {
      checks.append(
        .init(
          kind: .envelopeMetadata,
          status: .notChecked,
          message: "No envelope metadata expectation was configured."))
    }

    let formatSupported = policy.supportedFormats.contains(inspection.format)
    checks.append(
      .init(
        kind: .formatSupport,
        subject: inspection.format.rawValue,
        status: formatSupported ? .verified : .mismatch,
        message: formatSupported
          ? "Envelope format is enabled by the verification policy."
          : "Envelope format is disabled by the verification policy."))

    if let expected = policy.expectedTransportDigest {
      let observed = transportDigest(of: data, algorithm: expected.algorithm)
      checks.append(
        digestCheck(
          kind: .transportDigest,
          expected: expected,
          observed: observed,
          verify: { try self.verify(data, against: expected) }))
    } else {
      checks.append(
        .init(
          kind: .transportDigest,
          status: .notChecked,
          message: "No expected transport digest was configured."))
    }

    var dictionaryMap: [UInt64: CBORLDDocumentDictionary] = [:]
    var dictionaryConfigurationIsValid = true
    for dictionary in policy.dictionaries {
      if dictionaryMap[dictionary.code] != nil {
        dictionaryConfigurationIsValid = false
        checks.append(
          .init(
            kind: .documentDictionary,
            subject: String(dictionary.code),
            status: .invalid,
            message: "More than one dictionary uses registry entry \(dictionary.code)."))
      } else {
        dictionaryMap[dictionary.code] = dictionary
      }
    }

    if let id = inspection.registryEntryID,
      let expected = policy.requiredDictionaryFingerprints[id]
    {
      if let dictionary = dictionaryMap[id] {
        do {
          let observed = try dictionary.fingerprint(algorithm: expected.algorithm)
          checks.append(
            digestCheck(
              kind: .documentDictionary,
              subject: String(id),
              expected: expected,
              observed: observed,
              verify: { try dictionary.verifyFingerprint(expected) }))
          if checks.last?.status != .verified { dictionaryConfigurationIsValid = false }
        } catch {
          dictionaryConfigurationIsValid = false
          checks.append(
            .init(
              kind: .documentDictionary,
              subject: String(id),
              status: .invalid,
              expectedDigest: expected,
              message: "Dictionary fingerprint could not be computed: \(error)"))
        }
      } else {
        dictionaryConfigurationIsValid = false
        checks.append(
          .init(
            kind: .documentDictionary,
            subject: String(id),
            status: .unavailable,
            expectedDigest: expected,
            message: "The pinned dictionary for registry entry \(id) was not supplied."))
      }
    } else {
      checks.append(
        .init(
          kind: .documentDictionary,
          subject: inspection.registryEntryID.map(String.init),
          status: .notChecked,
          message: "No dictionary fingerprint was required for this registry entry."))
    }

    var expectedContexts = policy.contextRegistry?.expectedFingerprints ?? [:]
    var contextConfigurationIsValid = true
    for (url, expected) in policy.expectedContextFingerprints {
      if let configured = expectedContexts[url], configured != expected {
        contextConfigurationIsValid = false
        checks.append(
          .init(
            kind: .contextDocument,
            subject: url,
            status: .invalid,
            expectedDigest: expected,
            observedDigest: configured,
            message: "Context registry and verification policy contain different pins."))
      } else {
        expectedContexts[url] = expected
      }
    }

    var resolvedContexts = policy.contextRegistry?.documents ?? [:]
    if expectedContexts.isEmpty {
      checks.append(
        .init(
          kind: .contextDocument,
          status: .notChecked,
          message: "No context fingerprints were configured."))
    } else {
      for url in expectedContexts.keys.sorted() {
        guard
          !checks.contains(where: {
            $0.kind == .contextDocument && $0.subject == url && $0.status == .invalid
          })
        else { continue }
        guard let expected = expectedContexts[url] else { continue }
        do {
          let context: JSONValue
          if let registered = resolvedContexts[url] {
            context = registered
          } else if let fallback = policy.contextRegistry?.fallback {
            context = try await fallback(url)
            resolvedContexts[url] = context
          } else {
            contextConfigurationIsValid = false
            checks.append(
              .init(
                kind: .contextDocument,
                subject: url,
                status: .unavailable,
                expectedDigest: expected,
                message:
                  "Pinned context document was not supplied and no fallback loader is configured."))
            continue
          }
          let observed = try contextFingerprint(of: context, algorithm: expected.algorithm)
          checks.append(
            digestCheck(
              kind: .contextDocument,
              subject: url,
              expected: expected,
              observed: observed,
              verify: { try verifyContext(context, against: expected) }))
          if checks.last?.status != .verified { contextConfigurationIsValid = false }
        } catch {
          contextConfigurationIsValid = false
          checks.append(
            .init(
              kind: .contextDocument,
              subject: url,
              status: .invalid,
              expectedDigest: expected,
              message: "Pinned context could not be loaded or fingerprinted: \(error)"))
        }
      }
    }

    let effectiveRegistry = policy.contextRegistry.map {
      CBORLDContextRegistry(
        documents: resolvedContexts,
        expectedFingerprints: expectedContexts,
        fallback: $0.fallback)
    }

    var decodedDocument: JSONValue?
    if formatSupported && dictionaryConfigurationIsValid && contextConfigurationIsValid {
      let decoder = CBORLDDecoder(
        supportedFormats: policy.supportedFormats,
        dictionaries: policy.dictionaries,
        requiredDictionaryFingerprints: policy.requiredDictionaryFingerprints,
        legacyApplicationContextMap: policy.legacyApplicationContextMap,
        documentLoader: effectiveRegistry?.documentLoader,
        limits: policy.limits)
      do {
        decodedDocument = try await decoder.decode(data)
        checks.append(
          .init(
            kind: .documentDecoding,
            status: .verified,
            message: "CBOR-LD semantic decoding completed successfully."))
      } catch {
        checks.append(
          .init(
            kind: .documentDecoding,
            status: .invalid,
            message: "CBOR-LD semantic decoding failed: \(error)"))
      }
    } else {
      checks.append(
        .init(
          kind: .documentDecoding,
          status: .unavailable,
          message: "Semantic decoding was withheld because a required prerequisite failed."))
    }

    if let expected = policy.expectedStructuralFingerprint {
      if let decodedDocument {
        do {
          let observed = try structuralFingerprint(
            of: decodedDocument,
            algorithm: expected.algorithm)
          checks.append(
            digestCheck(
              kind: .structuralFingerprint,
              expected: expected,
              observed: observed,
              verify: { try verifyDocument(decodedDocument, against: expected) }))
        } catch {
          checks.append(
            .init(
              kind: .structuralFingerprint,
              status: .invalid,
              expectedDigest: expected,
              message: "Structural fingerprint could not be computed: \(error)"))
        }
      } else {
        checks.append(
          .init(
            kind: .structuralFingerprint,
            status: .unavailable,
            expectedDigest: expected,
            message: "Structural verification requires a successfully decoded document."))
      }
    } else {
      checks.append(
        .init(
          kind: .structuralFingerprint,
          status: .notChecked,
          message: "No structural fingerprint was configured."))
    }

    if expectedContexts.isEmpty, effectiveRegistry != nil {
      warnings.append(
        "A context loader was available, but no context identities were pinned by this verification policy."
      )
    }
    return CBORLDVerificationReport(
      inspection: inspection,
      checks: checks,
      warnings: warnings)
  }

  /// Verifies bytes against a sidecar manifest and the supplied semantic
  /// resources. An invalid manifest is reported without trusting its claims.
  public static func verificationReport(
    for data: Data,
    against manifest: CBORLDIntegrityManifest,
    dictionaries: [CBORLDDocumentDictionary] = [.unregistered],
    contextRegistry: CBORLDContextRegistry? = nil,
    supportedFormats: Set<CBORLDFormat> = Set(CBORLDFormat.allCases),
    legacyApplicationContextMap: [String: UInt64]? = nil,
    limits: CBORLDDecodingLimits = .init()
  ) async -> CBORLDVerificationReport {
    do {
      try manifest.validate()
    } catch {
      let base = await verificationReport(
        for: data,
        policy: .init(
          dictionaries: dictionaries,
          contextRegistry: contextRegistry,
          supportedFormats: supportedFormats,
          legacyApplicationContextMap: legacyApplicationContextMap,
          limits: limits))
      return CBORLDVerificationReport(
        checkedAt: base.checkedAt,
        inspection: base.inspection,
        checks: [
          .init(
            kind: .manifest,
            status: .invalid,
            message: "Integrity manifest is invalid: \(error)")
        ] + base.checks,
        warnings: base.warnings)
    }

    var dictionaryPins: [UInt64: CBORLDDigest] = [:]
    if let binding = manifest.dictionaryBinding {
      dictionaryPins[binding.registryEntryID] = binding.fingerprint
    }
    let base = await verificationReport(
      for: data,
      policy: .init(
        expectedEnvelope: manifest.envelope,
        expectedTransportDigest: manifest.transportDigest,
        expectedStructuralFingerprint: manifest.structuralFingerprint,
        dictionaries: dictionaries,
        requiredDictionaryFingerprints: dictionaryPins,
        contextRegistry: contextRegistry,
        expectedContextFingerprints: manifest.contextFingerprints,
        supportedFormats: supportedFormats,
        legacyApplicationContextMap: legacyApplicationContextMap,
        limits: limits))
    return CBORLDVerificationReport(
      checkedAt: base.checkedAt,
      inspection: base.inspection,
      checks: [
        .init(
          kind: .manifest,
          status: .verified,
          message: "Integrity manifest structure and digest domains are valid.")
      ] + base.checks,
      warnings: base.warnings)
  }

  private static func digestCheck(
    kind: CBORLDVerificationKind,
    subject: String? = nil,
    expected: CBORLDDigest,
    observed: CBORLDDigest,
    verify: () throws -> Void
  ) -> CBORLDVerificationCheck {
    do {
      try verify()
      return .init(
        kind: kind,
        subject: subject,
        status: .verified,
        expectedDigest: expected,
        observedDigest: observed,
        message: "Observed digest matches the expected digest.")
    } catch let error as CBORLDError where error.code == "ERR_INTEGRITY_MISMATCH" {
      return .init(
        kind: kind,
        subject: subject,
        status: .mismatch,
        expectedDigest: expected,
        observedDigest: observed,
        message: error.message)
    } catch {
      return .init(
        kind: kind,
        subject: subject,
        status: .invalid,
        expectedDigest: expected,
        observedDigest: observed,
        message: "Digest expectation is invalid: \(error)")
    }
  }

  private static func appendUnavailableChecks(
    afterEnvelopeFailureTo checks: inout [CBORLDVerificationCheck],
    policy: CBORLDVerificationPolicy
  ) {
    let requested: [(CBORLDVerificationKind, Bool)] = [
      (.envelopeMetadata, policy.expectedEnvelope != nil),
      (.formatSupport, true),
      (.transportDigest, policy.expectedTransportDigest != nil),
      (.documentDictionary, !policy.requiredDictionaryFingerprints.isEmpty),
      (
        .contextDocument,
        !policy.expectedContextFingerprints.isEmpty
          || !(policy.contextRegistry?.expectedFingerprints.isEmpty ?? true)
      ),
      (.documentDecoding, true),
      (.structuralFingerprint, policy.expectedStructuralFingerprint != nil),
    ]
    for (kind, isRequested) in requested {
      checks.append(
        .init(
          kind: kind,
          status: isRequested ? .unavailable : .notChecked,
          message: isRequested
            ? "Check is unavailable because the CBOR-LD envelope is invalid."
            : "No expectation was configured for this check."))
    }
  }
}
