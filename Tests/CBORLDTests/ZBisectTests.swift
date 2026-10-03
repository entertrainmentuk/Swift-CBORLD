// TEMPORARY: diagnostics for the Swift 6.0.3 x86_64 release-mode crash.
// Remove before merging.
import Foundation
import XCTest

@testable import CBORLD

final class ZBisectTests: XCTestCase {
  let document: JSONValue = ["text": .string(String(repeating: "x", count: 2_000))]

  func testF1_PreparedOverDirect() async throws {
    let prepared = try CBORLDPreparedEncoder(limits: .init(maximumOutputBytes: 64))
    do {
      _ = try await prepared.encode(document)
      XCTFail("no error")
    } catch let error as CBORLDError {
      XCTAssertEqual(error.code, .resourceLimit)
    }
  }

  func testF2_PreparedFits() async throws {
    let prepared = try CBORLDPreparedEncoder()
    let bytes = try await prepared.encode(document)
    XCTAssertGreaterThan(bytes.count, 2_000)
  }

  func testF3_PreparedSmallLimitSmallDocument() async throws {
    let prepared = try CBORLDPreparedEncoder(limits: .init(maximumOutputBytes: 64))
    let bytes = try await prepared.encode(["a": 1])
    XCTAssertLessThan(bytes.count, 64)
  }

  func testF4_PreparedConstructOnly() throws {
    _ = try CBORLDPreparedEncoder(limits: .init(maximumOutputBytes: 64))
  }

  func testF5_PreparedRegistryZero() async throws {
    let prepared = try CBORLDPreparedEncoder(
      dictionary: .init(code: 0), limits: .init(maximumOutputBytes: 64))
    do {
      _ = try await prepared.encode(document)
      XCTFail("no error")
    } catch let error as CBORLDError {
      XCTAssertEqual(error.code, .resourceLimit)
    }
  }

  func testF6_PreparedDefaultLimitsSmallDocument() async throws {
    let prepared = try CBORLDPreparedEncoder()
    _ = try await prepared.encode(["a": 1])
  }

  func testF7_PreparedFromStaticHelper() async throws {
    let code = await Self.encodeThroughHelper(document)
    XCTAssertEqual(code, .resourceLimit)
  }

  @inline(never)
  static func encodeThroughHelper(_ document: JSONValue) async -> CBORLDErrorCode? {
    do {
      let prepared = try CBORLDPreparedEncoder(limits: .init(maximumOutputBytes: 64))
      _ = try await prepared.encode(document)
      return nil
    } catch let error as CBORLDError {
      return error.code
    } catch {
      return nil
    }
  }
}
