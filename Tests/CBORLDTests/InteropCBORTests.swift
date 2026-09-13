import Foundation
import XCTest

@testable import CBORLD

final class InteropCBORTests: XCTestCase {
  private struct CBORLDEnvelopeCorpus: Decodable {
    struct Source: Decodable {
      let implementation: String
      let url: String
      let version: String
      let fixture: String
      let license: String
    }

    struct Vector: Decodable {
      let name: String
      let format: CBORLDFormat
      let registryEntryID: UInt64?
      let compressionMode: UInt8?
      let compressed: Bool
      let hex: String
      let assertedBy: [String]
    }

    let description: String
    let sources: [Source]
    let vectors: [Vector]
  }

  private struct Corpus: Decodable {
    let source: String
    let vectors: [Vector]
  }

  private struct Vector: Decodable {
    let name: String
    let hex: String
    let expectedJSON: String?
    let deterministicHex: String
    let indefinite: Bool?
  }

  func testCrossLanguageCBORLDEnvelopeCorpus() async throws {
    let corpus: CBORLDEnvelopeCorpus = try loadFixture(
      named: "cborld-cross-language")
    XCTAssertTrue(corpus.description.contains("exact-byte"))
    XCTAssertEqual(corpus.sources.count, 3)
    XCTAssertEqual(Set(corpus.sources.map(\.license)), ["BSD-3-Clause", "MIT"])
    XCTAssertTrue(
      corpus.sources.allSatisfy {
        !$0.implementation.isEmpty
          && !$0.version.isEmpty
          && !$0.fixture.isEmpty
          && URL(string: $0.url)?.scheme == "https"
      })
    XCTAssertGreaterThanOrEqual(corpus.vectors.count, 10)

    for vector in corpus.vectors {
      XCTAssertFalse(vector.assertedBy.isEmpty, vector.name)
      let expected = Data(testHex: vector.hex)
      let inspection = try CBORLD.inspect(expected)
      XCTAssertEqual(inspection.format, vector.format, vector.name)
      XCTAssertEqual(inspection.registryEntryID, vector.registryEntryID, vector.name)
      XCTAssertEqual(inspection.payloadIsCompressed, vector.compressed, vector.name)

      let typeTableLoader: CBORLDTypeTableLoader?
      if let expectedID = vector.registryEntryID {
        typeTableLoader = { @Sendable requestedID in
          requestedID == expectedID ? [:] : nil
        }
      } else {
        typeTableLoader = nil
      }
      let options = CBORLDEncodingOptions(
        format: vector.format,
        registryEntryID: vector.registryEntryID,
        typeTableLoader: typeTableLoader,
        compressionMode: vector.compressionMode)
      let encoded = try await CBORLD.encode(JSONValue.object([:]), options: options)
      XCTAssertEqual(encoded, expected, vector.name)

      let decoded = try await CBORLD.decode(
        expected,
        options: .init(typeTableLoader: typeTableLoader))
      XCTAssertEqual(decoded, JSONValue.object([:]), vector.name)
    }
  }

  func testCuratedRFC8949Corpus() throws {
    let corpus: Corpus = try loadFixture(named: "rfc8949-curated")
    XCTAssertTrue(corpus.source.contains("cbor/test-vectors"))
    XCTAssertGreaterThanOrEqual(corpus.vectors.count, 16)

    for vector in corpus.vectors {
      var decoder = CBORDecoder(data: Data(testHex: vector.hex))
      let value = try decoder.decodeComplete()
      XCTAssertEqual(
        try CBOREncoder.encode(value, mode: .lengthFirstDeterministic).testHex,
        vector.deterministicHex,
        vector.name)

      if let expectedJSON = vector.expectedJSON {
        XCTAssertEqual(
          try value.toJSON(),
          try JSONValue(data: Data(expectedJSON.utf8)),
          vector.name)
      } else {
        XCTAssertThrowsError(try value.toJSON(), vector.name)
      }

      if vector.indefinite == true {
        var strict = CBORDecoder(
          data: Data(testHex: vector.hex),
          limits: .init(allowsIndefiniteLengthItems: false))
        XCTAssertThrowsError(try strict.decodeComplete(), vector.name)
      }
    }
  }

  func testLengthFirstAndCoreDeterministicProfilesMatchIndependentGoVectors() throws {
    let map = CBORValue.map([
      .init(key: .unsigned(10), value: .bool(true)),
      .init(key: .negative(-1), value: .bool(true)),
      .init(key: .bool(false), value: .bool(true)),
      .init(key: .unsigned(100), value: .bool(true)),
      .init(key: .string("z"), value: .bool(true)),
      .init(key: .array([.negative(-1)]), value: .bool(true)),
      .init(key: .string("aa"), value: .bool(true)),
      .init(key: .array([.unsigned(100)]), value: .bool(true)),
    ])
    let tagged = CBORValue.tagged(100, map)
    let lengthFirst =
      "d864a80af520f5f4f51864f5617af58120f5626161f5811864f5"
    let core =
      "d864a80af51864f520f5617af5626161f5811864f58120f5f4f5"

    XCTAssertEqual(try CBOREncoder.encode(tagged, mode: .deterministic).testHex, lengthFirst)
    XCTAssertEqual(
      try CBOREncoder.encode(tagged, mode: .lengthFirstDeterministic).testHex,
      lengthFirst)
    XCTAssertEqual(
      try CBOREncoder.encode(tagged, mode: .coreDeterministic).testHex,
      core)
  }

  func testStrictDuplicateKeyRejectionIsOptIn() throws {
    let duplicateMap = Data(testHex: "a2616101616102")
    var compatible = CBORDecoder(data: duplicateMap)
    XCTAssertNoThrow(try compatible.decodeComplete())

    var strict = CBORDecoder(
      data: duplicateMap,
      limits: .init(rejectDuplicateMapKeys: true))
    XCTAssertThrowsError(try strict.decodeComplete()) { error in
      XCTAssertEqual((error as? CBORLDError)?.code, "ERR_NOT_CBORLD")
    }

    // The same unsigned key encoded once normally and once non-preferentially
    // is still one CBOR data-model key.
    var nonPreferredDuplicate = CBORDecoder(
      data: Data(testHex: "a20100180101"),
      limits: .init(rejectDuplicateMapKeys: true))
    XCTAssertThrowsError(try nonPreferredDuplicate.decodeComplete())
  }

  func testMalformedCBORCorpusFailsCleanly() {
    let malformed = [
      "ff",  // break outside an indefinite item
      "1a0000",  // truncated integer
      "61ff",  // invalid UTF-8
      "5f6161ff",  // text chunk in an indefinite byte string
      "9f01",  // unterminated indefinite array
      "0001",  // trailing CBOR item
    ]
    for hex in malformed {
      var decoder = CBORDecoder(data: Data(testHex: hex))
      XCTAssertThrowsError(try decoder.decodeComplete(), hex)
    }
  }

  private func loadFixture<Value: Decodable>(named name: String) throws -> Value {
    let url = try XCTUnwrap(
      Bundle.module.url(
        forResource: name,
        withExtension: "json",
        subdirectory: "Fixtures"))
    return try JSONDecoder().decode(Value.self, from: Data(contentsOf: url))
  }
}

extension Data {
  fileprivate init(testHex: String) {
    self.init()
    var index = testHex.startIndex
    while index < testHex.endIndex {
      let next = testHex.index(index, offsetBy: 2)
      append(UInt8(testHex[index..<next], radix: 16)!)
      index = next
    }
  }

  fileprivate var testHex: String { map { String(format: "%02x", $0) }.joined() }
}
