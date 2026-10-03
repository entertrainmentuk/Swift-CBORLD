import Foundation
import XCTest

@testable import CBORLD

/// Negative paths of integrity manifests and verification reports: every
/// misconfiguration must appear as its own check and withhold decoding.
final class VerificationReportTests: XCTestCase {
  private let contextURL = "https://example.com/context"
  private let context: JSONValue = ["@context": ["name": "https://schema.org/name"]]
  private let changedContext: JSONValue = ["@context": ["name": "https://example.com/name"]]
  private let dictionary = CBORLDDocumentDictionary(
    code: 42, contexts: ["https://example.com/context": 32_768])

  private func encoded() async throws -> Data {
    let registry = CBORLDContextRegistry(documents: [contextURL: context])
    return try await CBORLDEncoder(
      dictionary: dictionary, documentLoader: registry.documentLoader
    ).encode(["@context": .string(contextURL), "name": "Ada"])
  }

  private func check(
    _ report: CBORLDVerificationReport, _ kind: CBORLDVerificationKind, subject: String? = nil
  ) -> CBORLDVerificationCheck? {
    report.checks.first { $0.kind == kind && (subject == nil || $0.subject == subject) }
  }

  func testManifestValidationRejectsEveryMalformedClaim() async throws {
    let bytes = try await encoded()
    let valid = try CBORLD.integrityManifest(
      for: bytes, dictionary: dictionary, contextDocuments: [contextURL: context])
    XCTAssertNoThrow(try valid.validate())

    let pin = try CBORLD.contextFingerprint(of: context)
    let binding = try CBORLDDictionaryBinding(
      registryEntryID: 42, fingerprint: dictionary.fingerprint())
    func manifest(
      version: UInt16 = CBORLDIntegrityManifest.currentFormatVersion,
      byteCount: Int? = nil,
      artifactName: String? = nil,
      binding: CBORLDDictionaryBinding? = nil,
      contexts: [String: CBORLDDigest] = [:]
    ) -> CBORLDIntegrityManifest {
      CBORLDIntegrityManifest(
        formatVersion: version, artifactName: artifactName,
        envelope: .init(
          format: valid.envelope.format, registryEntryID: valid.envelope.registryEntryID,
          payloadIsCompressed: valid.envelope.payloadIsCompressed,
          byteCount: byteCount ?? valid.envelope.byteCount),
        transportDigest: valid.transportDigest, dictionaryBinding: binding,
        contextFingerprints: contexts)
    }
    let unsafeBinding = try CBORLDDictionaryBinding(
      registryEntryID: UInt64(CBORLDConstants.maximumSafeInteger) + 1,
      fingerprint: dictionary.fingerprint())
    let otherBinding = try CBORLDDictionaryBinding(
      registryEntryID: 43, fingerprint: dictionary.fingerprint())
    for invalid in [
      manifest(version: 99),
      manifest(byteCount: -1),
      manifest(artifactName: " \n"),
      manifest(binding: unsafeBinding),
      manifest(binding: otherBinding),
      manifest(contexts: [" ": pin]),
    ] {
      assertCBORLDErrorSync(.invalidManifest) { try invalid.validate() }
    }
    XCTAssertNoThrow(try manifest(binding: binding, contexts: [contextURL: pin]).validate())

    // A manifest cannot bind a dictionary to a different registry entry.
    assertCBORLDErrorSync(.invalidManifest) {
      _ = try CBORLD.integrityManifest(
        for: bytes, dictionary: CBORLDDocumentDictionary(code: 43))
    }

    // An invalid manifest is reported without trusting its claims.
    let report = await CBORLD.verificationReport(
      for: bytes, against: manifest(version: 99), dictionaries: [dictionary])
    XCTAssertFalse(report.isValid)
    XCTAssertFalse(report.problems.isEmpty)
  }

  func testMalformedEnvelopeMakesEveryLaterCheckUnavailable() async throws {
    let report = await CBORLD.verificationReport(
      for: Data([0xd9, 0xcb]),
      policy: .init(
        expectedTransportDigest: CBORLD.transportDigest(of: Data([0x00])),
        requiredDictionaryFingerprints: [42: try dictionary.fingerprint()]))
    XCTAssertNil(report.inspection)
    XCTAssertFalse(report.isValid)
    XCTAssertEqual(check(report, .envelope)?.status, .invalid)
    XCTAssertEqual(check(report, .documentDecoding)?.status, .unavailable)
    XCTAssertFalse(report.checks.contains { $0.status == .verified })
  }

  func testDictionaryMisconfigurationWithholdsDecoding() async throws {
    let bytes = try await encoded()
    let registry = CBORLDContextRegistry(documents: [contextURL: context])
    let pin = try dictionary.fingerprint()

    let duplicated = await CBORLD.verificationReport(
      for: bytes,
      policy: .init(
        dictionaries: [dictionary, CBORLDDocumentDictionary(code: 42)],
        contextRegistry: registry))
    XCTAssertEqual(check(duplicated, .documentDictionary, subject: "42")?.status, .invalid)
    XCTAssertEqual(check(duplicated, .documentDecoding)?.status, .unavailable)

    let missing = await CBORLD.verificationReport(
      for: bytes,
      policy: .init(
        dictionaries: [.unregistered], requiredDictionaryFingerprints: [42: pin],
        contextRegistry: registry))
    let missingCheck = check(missing, .documentDictionary, subject: "42")
    XCTAssertEqual(missingCheck?.status, .unavailable)
    XCTAssertEqual(missingCheck?.expectedDigest, pin)
    XCTAssertEqual(check(missing, .documentDecoding)?.status, .unavailable)

    let verified = await CBORLD.verificationReport(
      for: bytes,
      policy: .init(
        dictionaries: [dictionary], requiredDictionaryFingerprints: [42: pin],
        contextRegistry: registry))
    XCTAssertTrue(verified.isValid, "\(verified.problems)")
    XCTAssertEqual(check(verified, .documentDictionary, subject: "42")?.status, .verified)
  }

  func testConflictingAndMissingContextPinsWithholdDecoding() async throws {
    let bytes = try await encoded()
    let pin = try CBORLD.contextFingerprint(of: context)
    let otherPin = try CBORLD.contextFingerprint(of: changedContext)

    // The registry and the policy disagree about the same context.
    let conflicting = await CBORLD.verificationReport(
      for: bytes,
      policy: .init(
        dictionaries: [dictionary],
        contextRegistry: CBORLDContextRegistry(
          documents: [contextURL: context], expectedFingerprints: [contextURL: pin]),
        expectedContextFingerprints: [contextURL: otherPin]))
    let conflict = check(conflicting, .contextDocument, subject: contextURL)
    XCTAssertEqual(conflict?.status, .invalid)
    XCTAssertEqual(conflict?.expectedDigest, otherPin)
    XCTAssertEqual(conflict?.observedDigest, pin)
    XCTAssertEqual(check(conflicting, .documentDecoding)?.status, .unavailable)

    // A pinned context that nothing can supply is unavailable, not skipped.
    let missing = await CBORLD.verificationReport(
      for: bytes,
      policy: .init(
        dictionaries: [dictionary], contextRegistry: CBORLDContextRegistry(),
        expectedContextFingerprints: [contextURL: pin]))
    XCTAssertEqual(check(missing, .contextDocument, subject: contextURL)?.status, .unavailable)
    XCTAssertEqual(check(missing, .documentDecoding)?.status, .unavailable)

    // Unpinned contexts are decoded, with a warning that nothing was pinned.
    let unpinned = await CBORLD.verificationReport(
      for: bytes,
      policy: .init(
        dictionaries: [dictionary],
        contextRegistry: CBORLDContextRegistry(documents: [contextURL: context])))
    XCTAssertTrue(unpinned.isValid, "\(unpinned.problems)")
    XCTAssertEqual(check(unpinned, .contextDocument)?.status, .notChecked)
    XCTAssertFalse(unpinned.warnings.isEmpty)
  }

  func testFallbackContextsAreFingerprintedRatherThanRejectedByTheirPin() async throws {
    let bytes = try await encoded()
    let pin = try CBORLD.contextFingerprint(of: context)
    let otherPin = try CBORLD.contextFingerprint(of: changedContext)
    let loads = LoadCounter()
    let fallback: CBORLDDocumentLoader = { [context] url in
      await loads.increment()
      guard url == "https://example.com/context" else {
        throw CBORLDError(code: .unknownContext, message: "No context at \(url).")
      }
      return context
    }

    // The fallback's document matches the pin: the report verifies it and
    // then decodes with the resolved copy.
    let matching = await CBORLD.verificationReport(
      for: bytes,
      policy: .init(
        dictionaries: [dictionary],
        contextRegistry: CBORLDContextRegistry(
          expectedFingerprints: [contextURL: pin], fallback: fallback)))
    XCTAssertTrue(matching.isValid, "\(matching.problems)")
    XCTAssertEqual(check(matching, .contextDocument, subject: contextURL)?.status, .verified)
    XCTAssertEqual(check(matching, .documentDecoding)?.status, .verified)
    let loadsAfterMatch = await loads.count
    XCTAssertEqual(loadsAfterMatch, 1)

    // A different pin is a mismatch that names the observed digest, instead
    // of a load failure that hides it.
    let mismatched = await CBORLD.verificationReport(
      for: bytes,
      policy: .init(
        dictionaries: [dictionary],
        contextRegistry: CBORLDContextRegistry(
          expectedFingerprints: [contextURL: otherPin], fallback: fallback)))
    let mismatch = check(mismatched, .contextDocument, subject: contextURL)
    XCTAssertEqual(mismatch?.status, .mismatch)
    XCTAssertEqual(mismatch?.expectedDigest, otherPin)
    XCTAssertEqual(mismatch?.observedDigest, pin)
    XCTAssertEqual(check(mismatched, .documentDecoding)?.status, .unavailable)

    // A fallback that fails is reported as an invalid context check.
    let failing = await CBORLD.verificationReport(
      for: bytes,
      policy: .init(
        dictionaries: [dictionary],
        contextRegistry: CBORLDContextRegistry(
          expectedFingerprints: ["https://example.com/other": pin], fallback: fallback)))
    XCTAssertEqual(
      check(failing, .contextDocument, subject: "https://example.com/other")?.status, .invalid)
    XCTAssertEqual(check(failing, .documentDecoding)?.status, .unavailable)
  }
}

private actor LoadCounter {
  private(set) var count = 0

  func increment() { count += 1 }
}
