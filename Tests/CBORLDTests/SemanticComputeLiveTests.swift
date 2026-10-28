import Foundation
import XCTest

@testable import CBORLD

#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif

/// Opt-in interoperability evidence against a running SemanticCompute Live service.
/// Ordinary `swift test` runs stay hermetic; an integration job supplies the service URL and token.
final class SemanticComputeLiveTests: XCTestCase {
  private struct Receipt: Decodable {
    struct Result: Decodable {
      let compatible: Bool
      let comparedByteCount: Int
      let mismatchCount: Int
      let firstMismatchOffset: Int?
    }
    struct Attestation: Decodable {
      let mode: String
      let sha256: String
      let signature: String?
    }
    let schemaVersion: String
    let receiptID: String
    let serviceVersion: String
    let engineVersion: String
    let engineBuildCommit: String
    let executionStatus: String
    let executionTarget: String
    let requestSHA256: String
    let result: Result
    let attestation: Attestation
  }

  func testPinnedEmptyObjectFixtureWithSemanticComputeLive() async throws {
    let environment = ProcessInfo.processInfo.environment
    guard let rawURL = environment["SC_LIVE_URL"], !rawURL.isEmpty else {
      throw XCTSkip("Set SC_LIVE_URL to run the opt-in SemanticCompute Live release check.")
    }
    let endpoint = try XCTUnwrap(URL(string: rawURL)?.appendingPathComponent("v1/check/bytes"))

    // This expected value is pinned in the independent cross-language corpus. The candidate is freshly encoded
    // by Swift-CBORLD, so sending both to SC proves the released code still emits the expected CBOR-LD bytes.
    let expected = Data(liveHex: "d9cb1d8200a0")
    let candidate = try CBORLD.encodeUncompressed(.object([:]))
    let body: [String: String] = [
      "label": "Swift-CBORLD pinned CBOR-LD 1.0 empty-object fixture",
      "referenceBase64": expected.base64EncodedString(),
      "candidateBase64": candidate.base64EncodedString(),
    ]

    var request = URLRequest(url: endpoint)
    request.httpMethod = "POST"
    request.timeoutInterval = 15
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    if let token = environment["SC_LIVE_TOKEN"], !token.isEmpty {
      request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    }
    request.httpBody = try JSONEncoder().encode(body)

    let (data, response) = try await URLSession.shared.data(for: request)
    let http = try XCTUnwrap(response as? HTTPURLResponse)
    XCTAssertEqual(http.statusCode, 200, String(data: data, encoding: .utf8) ?? "non-UTF8 response")
    let receipt = try JSONDecoder().decode(Receipt.self, from: data)

    XCTAssertEqual(receipt.schemaVersion, "semanticcompute.live.byte-parity-receipt/1")
    XCTAssertFalse(receipt.receiptID.isEmpty)
    XCTAssertEqual(receipt.executionStatus, "executed")
    // As with the other optional variables, an empty value means unset.
    let expectedTarget = environment["SC_LIVE_EXPECTED_TARGET"].flatMap { $0.isEmpty ? nil : $0 }
    XCTAssertEqual(receipt.executionTarget, expectedTarget ?? "cpu-reference")
    XCTAssertTrue(receipt.result.compatible)
    XCTAssertEqual(receipt.result.comparedByteCount, expected.count)
    XCTAssertEqual(receipt.result.mismatchCount, 0)
    XCTAssertNil(receipt.result.firstMismatchOffset)
    XCTAssertEqual(receipt.requestSHA256.count, 64)
    XCTAssertEqual(receipt.attestation.sha256.count, 64)

    if let expectedEngine = environment["SC_LIVE_EXPECTED_ENGINE"], !expectedEngine.isEmpty {
      XCTAssertEqual(receipt.engineVersion, expectedEngine)
    }
    // This beta endpoint provides execution and parity evidence, not authenticated provenance.
    XCTAssertEqual(receipt.attestation.mode, "digest-only")
    XCTAssertNil(receipt.attestation.signature)

    print(
      "SemanticCompute receipt \(receipt.receiptID): engine=\(receipt.engineVersion) "
        + "service=\(receipt.serviceVersion) target=\(receipt.executionTarget)")
  }
}

extension Data {
  fileprivate init(liveHex value: String) {
    self.init()
    var index = value.startIndex
    while index < value.endIndex {
      let next = value.index(index, offsetBy: 2)
      append(UInt8(value[index..<next], radix: 16)!)
      index = next
    }
  }
}
