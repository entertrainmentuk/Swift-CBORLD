// TEMPORARY: the same call through a non-testable import. Remove before merging.
import CBORLD
import Foundation
import XCTest

final class ZBisectPlainTests: XCTestCase {
  func testP1_PreparedOverPlainImport() async throws {
    let document: JSONValue = ["text": .string(String(repeating: "x", count: 2_000))]
    let prepared = try CBORLDPreparedEncoder(limits: .init(maximumOutputBytes: 64))
    do {
      _ = try await prepared.encode(document)
      XCTFail("no error")
    } catch let error as CBORLDError {
      XCTAssertEqual(error.code, .resourceLimit)
    }
  }
}
