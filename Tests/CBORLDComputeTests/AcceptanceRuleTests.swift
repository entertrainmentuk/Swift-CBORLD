import CBORLD
import CBORLDCompute
import Foundation
import XCTest

/// The acceptance facades must reject every malformed work item before a
/// backend runs and every result that is not bound to its work item.
final class AcceptanceRuleTests: XCTestCase {
  private let cpu = CBORLDCPUComputeProvider()

  // MARK: Whole-document transforms

  func testWholeDocumentWorkItemsAreValidatedBeforeAnyBackendRuns() throws {
    let context: JSONValue = ["@context": ["name": "https://schema.org/name"]]
    let contextPin = try CBORLD.contextFingerprint(of: context)
    let bytes = try CBORLD.encodeUncompressed(["name": "Ada"])
    let invalidConfigurations = [
      CBORLDWholeDocumentTransformConfiguration(maximumOutputBytes: -1),
      .init(decodingLimits: .init(maximumInputBytes: -1)),
      .init(contextDocuments: ["https://example.com/c": context]),
      .init(
        contextDocuments: ["https://example.com/c": context],
        requiredContextFingerprints: [
          "https://example.com/c": try CBORLD.contextFingerprint(of: ["@context": [:]])
        ]),
      .init(requiredContextFingerprints: [
        "https://example.com/c": CBORLD.transportDigest(of: bytes)
      ]),
    ]
    for configuration in invalidConfigurations {
      XCTAssertThrowsError(try configuration.validate())
      XCTAssertThrowsError(
        try CBORLDWholeDocumentTransformRequest.decoding(
          bytes, configuration: configuration
        ).validate())
    }
    XCTAssertNoThrow(
      try CBORLDWholeDocumentTransformConfiguration(
        contextDocuments: ["https://example.com/c": context],
        requiredContextFingerprints: ["https://example.com/c": contextPin]
      ).validate())

    let small = CBORLDWholeDocumentTransformConfiguration(
      decodingLimits: .init(maximumInputBytes: 4))
    let cases: [(CBORLDWholeDocumentTransformRequest, CBORLDErrorCode)] = [
      (.init(operation: .encode, jsonLDDocument: [:], cborldBytes: bytes), .invalidInput),
      (.init(operation: .encode), .invalidInput),
      (.encoding(["name": "Ada Lovelace"], configuration: small), .resourceLimit),
      (.init(operation: .decode, jsonLDDocument: [:], cborldBytes: bytes), .invalidInput),
      (.init(operation: .decode), .invalidInput),
      (.decoding(bytes, configuration: small), .resourceLimit),
    ]
    for (request, code) in cases {
      XCTAssertThrowsError(try request.validate()) { error in
        XCTAssertEqual((error as? CBORLDError)?.code, code)
      }
    }
  }

  func testWholeDocumentResultsMustBeBoundToTheirWorkItem() async throws {
    let document: JSONValue = ["name": "Ada"]
    let encode = CBORLDWholeDocumentTransformRequest.encoding(document)
    let reference = try await cpu.batchedWholeDocumentTransform([encode])[0]
    let bytes = try XCTUnwrap(reference.cborldBytes)
    let decode = CBORLDWholeDocumentTransformRequest.decoding(bytes)
    let decoded = try await cpu.batchedWholeDocumentTransform([decode])[0]
    XCTAssertNoThrow(try reference.validate(for: encode))
    XCTAssertNoThrow(try decoded.validate(for: decode))

    let other = try CBORLD.encodeUncompressed(["name": "Grace"])
    let otherInspection = try CBORLD.inspect(other)
    let tampered: [(CBORLDWholeDocumentTransformRequest, CBORLDWholeDocumentTransformResult)] = [
      // The operation differs from the work item.
      (encode, decoded),
      // The digest does not bind the returned bytes.
      (
        encode,
        .init(
          operation: .encode, cborldBytes: bytes, outputByteCount: bytes.count,
          transportDigest: CBORLD.transportDigest(of: other), inspection: reference.inspection)
      ),
      // The inspection metadata describes different bytes.
      (
        encode,
        .init(
          operation: .encode, cborldBytes: bytes, outputByteCount: bytes.count,
          transportDigest: reference.transportDigest, inspection: otherInspection)
      ),
      // A decode result names the wrong output size.
      (
        decode,
        .init(
          operation: .decode, jsonLDDocument: document, outputByteCount: 1,
          transportDigest: decoded.transportDigest, inspection: decoded.inspection)
      ),
      // The digest does not bind the decoded input.
      (
        decode,
        .init(
          operation: .decode, jsonLDDocument: document,
          outputByteCount: decoded.outputByteCount,
          transportDigest: CBORLD.transportDigest(of: other), inspection: decoded.inspection)
      ),
      // The inspection metadata describes different input.
      (
        decode,
        .init(
          operation: .decode, jsonLDDocument: document,
          outputByteCount: decoded.outputByteCount,
          transportDigest: decoded.transportDigest, inspection: otherInspection)
      ),
    ]
    for (request, result) in tampered {
      XCTAssertThrowsError(try result.validate(for: request)) { error in
        XCTAssertEqual((error as? CBORLDError)?.code, .invalidComputeOutput)
      }
      await assertRejected {
        _ = try await CBORLD.batchedWholeDocumentTransform(
          [request], using: FixedWholeDocumentProvider(results: [result]))
      }
    }
    await assertRejected {
      _ = try await CBORLD.batchedWholeDocumentTransform(
        [encode], using: FixedWholeDocumentProvider(results: []))
    }
  }

  func testCPUWholeDocumentTransformEnforcesTheOutputLimit() async throws {
    let limited = CBORLDWholeDocumentTransformConfiguration(maximumOutputBytes: 8)
    let document: JSONValue = ["name": "a value longer than the output limit"]
    await assertRejected(.resourceLimit) {
      _ = try await self.cpu.batchedWholeDocumentTransform([
        .encoding(document, configuration: limited)
      ])
    }
    let bytes = try CBORLD.encodeUncompressed(document)
    await assertRejected(.resourceLimit) {
      _ = try await self.cpu.batchedWholeDocumentTransform([
        .decoding(bytes, configuration: limited)
      ])
    }
  }

  // MARK: CDDL

  func testCDDLWorkItemsAreValidatedBeforeAnyBackendRuns() {
    let document = Data([0xa0])
    let cases: [(CBORLDCDDLValidationRequest, CBORLDErrorCode)] = [
      (
        .init(
          schema: "root = {}", document: document, documentEncoding: .cbor,
          limits: .init(maximumDiagnostics: -1)), .invalidInput
      ),
      (.init(schema: "", document: document, documentEncoding: .cbor), .invalidInput),
      (
        .init(
          schema: "root = {}", document: document, documentEncoding: .cbor,
          limits: .init(maximumSchemaBytes: 3)), .resourceLimit
      ),
      (
        .init(
          schema: "root = {}", document: document, documentEncoding: .cbor,
          limits: .init(maximumDocumentBytes: 0)), .resourceLimit
      ),
      (
        .init(schema: "root = {}", rootRule: "", document: document, documentEncoding: .cbor),
        .invalidInput
      ),
    ]
    for (request, code) in cases {
      XCTAssertThrowsError(try request.validate()) { error in
        XCTAssertEqual((error as? CBORLDError)?.code, code)
      }
    }
  }

  func testCDDLResultsMustBeConsistentWithTheirWorkItem() async throws {
    let request = CBORLDCDDLValidationRequest(
      schema: "root = {}", document: Data([0xa0]), documentEncoding: .cbor)
    let failure = CBORLDCDDLDiagnostic(
      code: "E1", severity: .error, phase: .validation, message: "Mismatch.",
      path: "$", rule: "root", schemaByteOffset: 0, documentByteOffset: 1)
    func result(
      schemaByteCount: Int? = nil,
      schemaIsValid: Bool = true,
      documentIsValid: Bool = true,
      astNodeCount: Int = 2,
      flatInstructionCount: Int? = nil,
      failedInstructionIndex: Int? = nil,
      diagnostics: [CBORLDCDDLDiagnostic] = []
    ) -> CBORLDCDDLValidationResult {
      .init(
        schemaByteCount: schemaByteCount ?? request.schemaByteCount,
        documentByteCount: request.document.count, schemaIsValid: schemaIsValid,
        documentIsValid: documentIsValid, astNodeCount: astNodeCount,
        maximumValidationDepth: 1, flatInstructionCount: flatInstructionCount,
        failedInstructionIndex: failedInstructionIndex, diagnostics: diagnostics)
    }
    func diagnostic(
      code: String = "E1", path: String? = "$", schemaOffset: Int? = 0,
      documentOffset: Int? = 1
    ) -> CBORLDCDDLDiagnostic {
      .init(
        code: code, severity: .error, phase: .validation, message: "Mismatch.", path: path,
        schemaByteOffset: schemaOffset, documentByteOffset: documentOffset)
    }

    let accepted = [
      result(),
      result(documentIsValid: false, diagnostics: [failure]),
      result(flatInstructionCount: 3, failedInstructionIndex: 2),
    ]
    for valid in accepted { XCTAssertNoThrow(try valid.validate(for: request)) }

    let rejected = [
      result(schemaByteCount: 1),
      result(schemaIsValid: false, documentIsValid: true, diagnostics: [failure]),
      result(astNodeCount: 0),
      result(documentIsValid: false),
      result(flatInstructionCount: 0),
      result(flatInstructionCount: 2, failedInstructionIndex: 2),
      result(failedInstructionIndex: 0),
      result(documentIsValid: false, diagnostics: [failure, diagnostic(code: "")]),
      result(documentIsValid: false, diagnostics: [diagnostic(path: "")]),
      result(documentIsValid: false, diagnostics: [diagnostic(schemaOffset: 99)]),
      result(documentIsValid: false, diagnostics: [diagnostic(documentOffset: 2)]),
    ]
    for invalid in rejected {
      XCTAssertThrowsError(try invalid.validate(for: request)) { error in
        XCTAssertEqual((error as? CBORLDError)?.code, .invalidComputeOutput)
      }
    }

    await assertRejected {
      _ = try await CBORLD.batchedCDDLValidation(
        [request, request], using: FixedCDDLProvider(results: [result()]))
    }
    let results = try await CBORLD.batchedCDDLValidation(
      [request], using: FixedCDDLProvider(results: [result()]))
    XCTAssertEqual(results, [result()])
  }

  // MARK: Helpers

  private func assertRejected(
    _ code: CBORLDErrorCode = .invalidComputeOutput,
    file: StaticString = #filePath,
    line: UInt = #line,
    _ operation: () async throws -> Void
  ) async {
    do {
      try await operation()
      XCTFail("Expected \(code).", file: file, line: line)
    } catch let error as CBORLDError {
      XCTAssertEqual(error.code, code, file: file, line: line)
    } catch {
      XCTFail("Unexpected \(error).", file: file, line: line)
    }
  }
}

private struct FixedWholeDocumentProvider: CBORLDWholeDocumentTransformComputing {
  let results: [CBORLDWholeDocumentTransformResult]

  func batchedWholeDocumentTransform(
    _ requests: [CBORLDWholeDocumentTransformRequest]
  ) async throws -> [CBORLDWholeDocumentTransformResult] {
    results
  }
}

private struct FixedCDDLProvider: CBORLDCDDLValidationComputing {
  let results: [CBORLDCDDLValidationResult]

  func batchedCDDLValidation(
    _ requests: [CBORLDCDDLValidationRequest]
  ) async throws -> [CBORLDCDDLValidationResult] {
    results
  }
}
