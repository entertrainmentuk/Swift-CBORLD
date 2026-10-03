import Foundation
import XCTest

@testable import CBORLD

/// A small deterministic generator for reproducible test inputs. Failures
/// report their seed so a case can be replayed exactly.
struct SplitMix64: RandomNumberGenerator {
  private(set) var state: UInt64

  init(seed: UInt64) {
    state = seed
  }

  mutating func next() -> UInt64 {
    state &+= 0x9e37_79b9_7f4a_7c15
    var value = state
    value = (value ^ (value >> 30)) &* 0xbf58_476d_1ce4_e5b9
    value = (value ^ (value >> 27)) &* 0x94d0_49bb_1331_11eb
    return value ^ (value >> 31)
  }
}

extension Data {
  var hexString: String { map { String(format: "%02x", $0) }.joined() }

  init(hexString: String) {
    self.init()
    var index = hexString.startIndex
    while index < hexString.endIndex {
      let next = hexString.index(index, offsetBy: 2)
      append(UInt8(hexString[index..<next], radix: 16)!)
      index = next
    }
  }
}

/// A document loader over fixed documents that fails for anything else.
func fixedLoader(_ documents: [String: JSONValue]) -> CBORLDDocumentLoader {
  { url in
    guard let document = documents[url] else {
      throw CBORLDError(code: .unknownContext, message: "No test document for \(url).")
    }
    return document
  }
}

/// Asserts that `body` throws a ``CBORLDError`` with `code`.
func assertCBORLDError(
  _ code: CBORLDErrorCode,
  file: StaticString = #filePath,
  line: UInt = #line,
  _ body: () async throws -> Void
) async {
  do {
    try await body()
    XCTFail("Expected \(code), but no error was thrown.", file: file, line: line)
  } catch let error as CBORLDError {
    XCTAssertEqual(error.code, code, error.message, file: file, line: line)
  } catch {
    XCTFail("Expected \(code), but received \(error).", file: file, line: line)
  }
}

/// Synchronous form of ``assertCBORLDError(_:file:line:_:)``.
func assertCBORLDErrorSync(
  _ code: CBORLDErrorCode,
  file: StaticString = #filePath,
  line: UInt = #line,
  _ body: () throws -> Void
) {
  do {
    try body()
    XCTFail("Expected \(code), but no error was thrown.", file: file, line: line)
  } catch let error as CBORLDError {
    XCTAssertEqual(error.code, code, error.message, file: file, line: line)
  } catch {
    XCTFail("Expected \(code), but received \(error).", file: file, line: line)
  }
}
