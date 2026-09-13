import Foundation
import XCTest

@testable import CBORLD

final class IntegrityTests: XCTestCase {
  func testIncrementalAndFileTransportDigestsMatchInMemoryDigest() throws {
    let data = Data((0..<250_000).map { UInt8($0 % 251) })
    var chunks: [Data] = []
    for start in stride(from: 0, to: data.count, by: 8191) {
      chunks.append(Data(data[start..<min(start + 8191, data.count)]))
    }

    let file = FileManager.default.temporaryDirectory
      .appendingPathComponent("CBORLD-digest-\(UUID().uuidString).bin")
    try data.write(to: file, options: .atomic)
    defer { try? FileManager.default.removeItem(at: file) }

    for algorithm in CBORLDHashAlgorithm.allCases {
      let expected = CBORLD.transportDigest(of: data, algorithm: algorithm)
      XCTAssertEqual(
        CBORLD.transportDigest(chunks: chunks, algorithm: algorithm),
        expected)
      XCTAssertEqual(
        try CBORLD.transportDigest(
          ofFile: file,
          algorithm: algorithm,
          chunkSize: 4093),
        expected)
    }

    XCTAssertThrowsError(try CBORLD.transportDigest(ofFile: file, chunkSize: 0)) { error in
      XCTAssertEqual((error as? CBORLDError)?.code, "ERR_INVALID_INPUT")
    }
  }

  func testIntegrityManifestAndCompleteVerificationReport() async throws {
    let contextURL = "https://example.com/contexts/person-v1"
    let context: JSONValue = [
      "@context": [
        "name": "https://schema.org/name",
        "Person": "https://schema.org/Person",
        "type": "@type",
      ]
    ]
    let dictionary = CBORLDDocumentDictionary(
      code: 42,
      profileName: "person",
      profileVersion: "1",
      contexts: [contextURL: 32_768])
    let document: JSONValue = [
      "@context": .string(contextURL),
      "type": "Person",
      "name": "Ada",
    ]
    let contextPin = try CBORLD.contextFingerprint(of: context)
    let registry = CBORLDContextRegistry(
      documents: [contextURL: context],
      expectedFingerprints: [contextURL: contextPin])
    let bytes = try await CBORLDEncoder(
      dictionary: dictionary,
      documentLoader: registry.documentLoader
    ).encode(document)

    let manifest = try CBORLD.integrityManifest(
      for: bytes,
      document: document,
      dictionary: dictionary,
      contextDocuments: [contextURL: context],
      declaredSerializationMode: .compatibility,
      artifactName: "person.cborld",
      producer: "CBORLDTests",
      createdAt: Date(timeIntervalSince1970: 1_700_000_000))
    try manifest.validate()
    XCTAssertEqual(manifest.envelope.registryEntryID, 42)
    XCTAssertEqual(manifest.contextFingerprints[contextURL], contextPin)
    XCTAssertEqual(manifest.dictionaryBinding?.registryEntryID, 42)

    let persisted = try JSONEncoder().encode(manifest)
    let restored = try JSONDecoder().decode(CBORLDIntegrityManifest.self, from: persisted)
    XCTAssertEqual(restored, manifest)
    try restored.validate()

    let report = await CBORLD.verificationReport(
      for: bytes,
      against: restored,
      dictionaries: [dictionary],
      contextRegistry: registry)
    XCTAssertTrue(report.isValid, report.problems.map(\.message).joined(separator: "\n"))
    XCTAssertTrue(report.problems.isEmpty)
    XCTAssertEqual(
      report.checks.first(where: { $0.kind == .documentDictionary })?.status,
      .verified)
    XCTAssertEqual(
      report.checks.first(where: {
        $0.kind == .contextDocument && $0.subject == contextURL
      })?.status,
      .verified)
    XCTAssertEqual(
      report.checks.first(where: { $0.kind == .structuralFingerprint })?.status,
      .verified)
  }

  func testReportAggregatesTransportAndStructuralMismatches() async throws {
    let original: JSONValue = ["value": 1]
    let changed: JSONValue = ["value": 2]
    let originalBytes = try await CBORLD.encode(
      original, options: .init(registryEntryID: 0))
    let changedBytes = try await CBORLD.encode(
      changed, options: .init(registryEntryID: 0))
    XCTAssertEqual(originalBytes.count, changedBytes.count)

    let manifest = try CBORLD.integrityManifest(
      for: originalBytes,
      document: original,
      declaredSerializationMode: .compatibility)
    let report = await CBORLD.verificationReport(for: changedBytes, against: manifest)

    XCTAssertFalse(report.isValid)
    XCTAssertEqual(
      report.checks.first(where: { $0.kind == .envelopeMetadata })?.status,
      .verified)
    XCTAssertEqual(
      report.checks.first(where: { $0.kind == .transportDigest })?.status,
      .mismatch)
    XCTAssertEqual(
      report.checks.first(where: { $0.kind == .documentDecoding })?.status,
      .verified)
    XCTAssertEqual(
      report.checks.first(where: { $0.kind == .structuralFingerprint })?.status,
      .mismatch)
    XCTAssertEqual(report.problems.count, 2)
  }

  func testFailedContextPinWithholdsSemanticDecoding() async throws {
    let contextURL = "https://example.com/context"
    let expectedContext: JSONValue = [
      "@context": ["name": "https://schema.org/name"]
    ]
    let changedContext: JSONValue = [
      "@context": ["name": "https://example.com/name"]
    ]
    let dictionary = CBORLDDocumentDictionary(
      code: 42,
      contexts: [contextURL: 32_768])
    let document: JSONValue = ["@context": .string(contextURL), "name": "Ada"]
    let encoderRegistry = CBORLDContextRegistry(documents: [contextURL: expectedContext])
    let bytes = try await CBORLDEncoder(
      dictionary: dictionary,
      documentLoader: encoderRegistry.documentLoader
    ).encode(document)
    let manifest = try CBORLD.integrityManifest(
      for: bytes,
      document: document,
      dictionary: dictionary,
      contextDocuments: [contextURL: expectedContext])

    let changedRegistry = CBORLDContextRegistry(documents: [contextURL: changedContext])
    let report = await CBORLD.verificationReport(
      for: bytes,
      against: manifest,
      dictionaries: [dictionary],
      contextRegistry: changedRegistry)
    XCTAssertFalse(report.isValid)
    XCTAssertEqual(
      report.checks.first(where: { $0.kind == .contextDocument })?.status,
      .mismatch)
    XCTAssertEqual(
      report.checks.first(where: { $0.kind == .documentDecoding })?.status,
      .unavailable)
    XCTAssertEqual(
      report.checks.first(where: { $0.kind == .structuralFingerprint })?.status,
      .unavailable)
  }

  func testManifestRejectsDigestDomainConfusion() async throws {
    let document: JSONValue = ["value": 1]
    let bytes = try await CBORLD.encode(
      document, options: .init(registryEntryID: 0))
    let valid = try CBORLD.integrityManifest(for: bytes, document: document)
    let invalid = CBORLDIntegrityManifest(
      createdAt: valid.createdAt,
      envelope: valid.envelope,
      transportDigest: valid.transportDigest,
      structuralFingerprint: valid.transportDigest)

    XCTAssertThrowsError(try invalid.validate()) { error in
      XCTAssertEqual((error as? CBORLDError)?.code, "ERR_INVALID_MANIFEST")
    }
    let report = await CBORLD.verificationReport(for: bytes, against: invalid)
    XCTAssertFalse(report.isValid)
    XCTAssertEqual(report.checks.first?.kind, .manifest)
    XCTAssertEqual(report.checks.first?.status, .invalid)
  }
}
