import Foundation
import XCTest

@testable import CBORLD

final class CBORLDTests: XCTestCase {
  func testCurrentEnvelopeWithoutCompression() async throws {
    let encoded = try await CBORLD.encode(
      [:], options: .init(registryEntryID: 0))
    XCTAssertEqual(encoded.hex, "d9cb1d8200a0")
    let decoded = try await CBORLD.decode(encoded)
    XCTAssertEqual(decoded, [:])
  }

  func testCurrentEnvelopeWithDefaultDictionary() async throws {
    let encoded = try await CBORLD.encode(
      [:], options: .init(registryEntryID: 1))
    XCTAssertEqual(encoded.hex, "d9cb1d8201a0")

    let inspection = try CBORLD.inspect(encoded)
    XCTAssertEqual(inspection.format, .cborLD1)
    XCTAssertEqual(inspection.registryEntryID, 1)
    XCTAssertTrue(inspection.payloadIsCompressed)
    XCTAssertEqual(inspection.byteCount, 6)
    XCTAssertEqual(inspection.payloadDescription, "{}")
    XCTAssertEqual(inspection.transportDigest, CBORLD.transportDigest(of: encoded))
  }

  func testCurrentRegistryIdentifierWidths() async throws {
    for (id, expected) in [
      (UInt64(16), "d9cb1d8210a0"),
      (UInt64(128), "d9cb1d821880a0"),
      (UInt64(1_000_000_000), "d9cb1d821a3b9aca00a0"),
    ] {
      let encoded = try await CBORLD.encode(
        [:],
        options: .init(
          registryEntryID: id,
          typeTableLoader: { requested in requested == id ? [:] : nil }))
      XCTAssertEqual(encoded.hex, expected)
      XCTAssertEqual(try CBORLD.inspect(encoded).registryEntryID, id)
    }
  }

  func testLegacyRangeVarintEnvelopes() async throws {
    let oneByte = try await CBORLD.encode(
      [:],
      options: .init(
        format: .legacyRange,
        registryEntryID: 16,
        typeTableLoader: { _ in [:] }))
    XCTAssertEqual(oneByte.hex, "d90610a0")

    let twoByte = try await CBORLD.encode(
      [:],
      options: .init(
        format: .legacyRange,
        registryEntryID: 128,
        typeTableLoader: { _ in [:] }))
    XCTAssertEqual(twoByte.hex, "d90680824101a0")
    XCTAssertEqual(try CBORLD.inspect(twoByte).registryEntryID, 128)

    let larger = try await CBORLD.encode(
      [:],
      options: .init(
        format: .legacyRange,
        registryEntryID: 1_000_000_000,
        typeTableLoader: { _ in [:] }))
    XCTAssertEqual(larger.hex, "d90680824494ebdc03a0")
    XCTAssertEqual(try CBORLD.inspect(larger).registryEntryID, 1_000_000_000)
  }

  func testNativeJSONTypesMatchJavaScriptBytes() async throws {
    let document: JSONValue = [
      "@context": ["foo": "ex:foo"],
      "foo": [-1, 0, 1, true, false, 1.1, 1.0, -1.1, "text"],
    ]
    let encoded = try await CBORLD.encode(
      document, options: .init(registryEntryID: 1))
    XCTAssertEqual(
      encoded.hex,
      "d9cb1d8201a200a163666f6f6665783a666f6f186589200001"
        + "f5f4fb3ff199999999999a01fbbff199999999999a6474657874")
    let decoded = try await CBORLD.decode(encoded)
    XCTAssertEqual(decoded, document)
  }

  func testTypedDateTimeMatchesJavaScriptBytes() async throws {
    let contextURL = "urn:foo"
    let context: JSONValue = [
      "@context": [
        "arbitraryPrefix": "http://www.w3.org/2001/XMLSchema#",
        "foo": [
          "@id": "ex:foo",
          "@type": "arbitraryPrefix:dateTime",
        ],
      ]
    ]
    let document: JSONValue = [
      "@context": .string(contextURL),
      "foo": "2021-04-09T20:38:55Z",
    ]
    let dictionary = CBORLDDocumentDictionary(
      code: 2,
      contexts: [contextURL: 0x8000])
    let encoder = CBORLDEncoder(
      dictionary: dictionary,
      documentLoader: { url in
        guard url == contextURL else { throw TestError.unknownContext(url) }
        return context
      })
    let encoded = try await encoder.encode(document)
    XCTAssertEqual(encoded.hex, "d9cb1d8202a20019800018661a6070bb5f")

    let decoder = CBORLDDecoder(
      dictionaries: [dictionary],
      documentLoader: { url in
        guard url == contextURL else { throw TestError.unknownContext(url) }
        return context
      })
    let decoded = try await decoder.decode(encoded)
    XCTAssertEqual(decoded, document)
  }

  func testMultibaseAndTypeTableMatchJavaScriptBytes() async throws {
    let contextURL = "urn:foo"
    let context: JSONValue = [
      "@context": [
        "foo": [
          "@id": "ex:foo",
          "@type": "https://w3id.org/security#multibase",
        ]
      ]
    ]
    let document: JSONValue = [
      "@context": .string(contextURL),
      "foo": ["MAQID", "zLdp", "uAQID"],
    ]
    let dictionary = CBORLDDocumentDictionary(
      code: 2,
      contexts: [contextURL: 0x8000])
    let loader: CBORLDDocumentLoader = { url in
      guard url == contextURL else { throw TestError.unknownContext(url) }
      return context
    }
    let encoded = try await CBORLDEncoder(
      dictionary: dictionary, documentLoader: loader
    ).encode(document)
    XCTAssertEqual(
      encoded.hex,
      "d9cb1d8202a200198000186583444d010203447a0102034475010203")
    let decoded = try await CBORLDDecoder(
      dictionaries: [dictionary], documentLoader: loader
    ).decode(encoded)
    XCTAssertEqual(decoded, document)

    let tableDictionary = CBORLDDocumentDictionary(
      code: 2,
      contexts: [contextURL: 0x8000],
      typedValues: [
        "https://w3id.org/security#multibase": [
          "MAQID": 0x8001,
          "zLdp": 0x8002,
          "uAQID": 0x8003,
        ]
      ])
    let tableEncoded = try await CBORLDEncoder(
      dictionary: tableDictionary, documentLoader: loader
    ).encode(document)
    XCTAssertEqual(
      tableEncoded.hex,
      "d9cb1d8202a200198000186583198001198002198003")
    let tableDecoded = try await CBORLDDecoder(
      dictionaries: [tableDictionary], documentLoader: loader
    )
    .decode(tableEncoded)
    XCTAssertEqual(tableDecoded, document)
  }

  func testTypeScopedContextMatchesJavaScriptBytes() async throws {
    let contextURL = "urn:foo"
    let context: JSONValue = [
      "@context": [
        "Foo": [
          "@id": "ex:Foo",
          "@context": [
            "foo": [
              "@id": "ex:foo",
              "@type": "https://w3id.org/security#multibase",
            ]
          ],
        ]
      ]
    ]
    let document: JSONValue = [
      "@context": .string(contextURL),
      "@type": "Foo",
      "foo": ["MAQID", "zLdp", "uAQID"],
    ]
    let dictionary = CBORLDDocumentDictionary(
      code: 2, contexts: [contextURL: 0x8000])
    let loader: CBORLDDocumentLoader = { _ in context }
    let encoded = try await CBORLDEncoder(
      dictionary: dictionary, documentLoader: loader
    ).encode(document)
    XCTAssertEqual(
      encoded.hex,
      "d9cb1d8202a300198000021864186783444d010203447a0102034475010203")
    let decoded = try await CBORLDDecoder(
      dictionaries: [dictionary], documentLoader: loader
    ).decode(encoded)
    XCTAssertEqual(decoded, document)
  }

  func testPropertyScopedContextMatchesJavaScriptBytes() async throws {
    let contextURL = "urn:foo"
    let context: JSONValue = [
      "@context": [
        "nest": [
          "@id": "ex:nest",
          "@context": [
            "foo": [
              "@id": "ex:foo",
              "@type": "https://w3id.org/security#multibase",
            ]
          ],
        ]
      ]
    ]
    let document: JSONValue = [
      "@context": .string(contextURL),
      "nest": ["foo": ["MAQID", "zLdp", "uAQID"]],
    ]
    let dictionary = CBORLDDocumentDictionary(
      code: 2, contexts: [contextURL: 0x8000])
    let loader: CBORLDDocumentLoader = { _ in context }
    let encoded = try await CBORLDEncoder(
      dictionary: dictionary, documentLoader: loader
    ).encode(document)
    XCTAssertEqual(
      encoded.hex,
      "d9cb1d8202a2001980001864a1186783444d010203447a0102034475010203")
    let decoded = try await CBORLDDecoder(
      dictionaries: [dictionary], documentLoader: loader
    ).decode(encoded)
    XCTAssertEqual(decoded, document)
  }

  func testURLCodecsMatchJavaScriptBytes() async throws {
    let contextURL = "urn:foo"
    let context: JSONValue = ["@context": ["id": "@id"]]
    let dictionary = CBORLDDocumentDictionary(
      code: 2, contexts: [contextURL: 0x8000])
    let loader: CBORLDDocumentLoader = { _ in context }
    let vectors: [(String, String)] = [
      (
        "urn:uuid:75ef3fcc-9ae3-11eb-8e3e-10bf48838a41",
        "d9cb1d8202a200198000186482035075ef3fcc9ae311eb8e3e10bf48838a41"
      ),
      (
        "urn:uuid:75EF3FCC-9AE3-11EB-8E3E-10BF48838A41",
        "d9cb1d8202a20019800018648203782437354546334643432d394145332d313145422d384533452d313042463438383338413431"
      ),
      (
        "https://test.example",
        "d9cb1d8202a200198000186482026c746573742e6578616d706c65"
      ),
      (
        "http://test.example",
        "d9cb1d8202a200198000186482016c746573742e6578616d706c65"
      ),
    ]
    for (url, expected) in vectors {
      let document: JSONValue = ["@context": .string(contextURL), "id": .string(url)]
      let encoded = try await CBORLDEncoder(
        dictionary: dictionary, documentLoader: loader
      ).encode(document)
      XCTAssertEqual(encoded.hex, expected)
      let decoded = try await CBORLDDecoder(
        dictionaries: [dictionary], documentLoader: loader
      ).decode(encoded)
      XCTAssertEqual(decoded, document)
    }
  }

  func testDataURLCodec() async throws {
    let contextURL = "https://example.org/context/v1"
    let context: JSONValue = [
      "@context": ["data": ["@id": "ex:data", "@type": "@id"]]
    ]
    let dictionary = CBORLDDocumentDictionary(
      code: 2, contexts: [contextURL: 0x8000])
    let loader: CBORLDDocumentLoader = { _ in context }
    let document: JSONValue = [
      "@context": .string(contextURL),
      "data": "data:text/plain;base64,SGVsbG8sIFdvcmxkIQ==",
    ]
    let encoded = try await CBORLDEncoder(
      dictionary: dictionary, documentLoader: loader
    ).encode(document)
    XCTAssertEqual(
      encoded.hex,
      "d9cb1d8202a200198000186483046a746578742f706c61696e4d48656c6c6f2c20576f726c6421")
    let decoded = try await CBORLDDecoder(
      dictionaries: [dictionary], documentLoader: loader
    ).decode(encoded)
    XCTAssertEqual(decoded, document)
  }

  func testDataURLCompatibilityMatrix() async throws {
    let contextURL = "https://example.org/context/v1"
    let context: JSONValue = [
      "@context": ["data": ["@id": "ex:data", "@type": "@id"]]
    ]
    let dictionary = CBORLDDocumentDictionary(
      code: 2, contexts: [contextURL: 0x8000])
    let loader: CBORLDDocumentLoader = { _ in context }
    let vectors: [(JSONValue, String)] = [
      (
        "data:",
        "d9cb1d8202a2001980001864820460"
      ),
      (
        "data:,",
        "d9cb1d8202a20019800018648204612c"
      ),
      (
        "data:;base64,",
        "d9cb1d8202a200198000186483046040"
      ),
      (
        "data:text/plain,test",
        "d9cb1d8202a200198000186482046f746578742f706c61696e2c74657374"
      ),
      (
        "data:image/gif;base64,R0lGODdhAQABAIABAAAAAAAAACwAAAAAAQABAAACAkwBADs",
        "d9cb1d8202a200198000186482047840696d6167652f6769663b6261736536342c52306c474f4464684151414241494142414141414141414141437741414141414151414241414143416b7742414473"
      ),
      (
        ["other:url", "data:"],
        "d9cb1d8202a200198000186582696f746865723a75726c820460"
      ),
    ]

    for (value, expected) in vectors {
      let document: JSONValue = ["@context": .string(contextURL), "data": value]
      let encoded = try await CBORLDEncoder(
        dictionary: dictionary, documentLoader: loader
      ).encode(document)
      XCTAssertEqual(encoded.hex, expected)
      let decoded = try await CBORLDDecoder(
        dictionaries: [dictionary], documentLoader: loader
      ).decode(encoded)
      XCTAssertEqual(decoded, document)
    }
  }

  func testDIDURLCodecsMatchJavaScriptBytes() async throws {
    let contextURL = "https://w3id.org/did/v0.11"
    let context: JSONValue = [
      "@context": [
        "@protected": true,
        "id": "@id",
        "type": "@type",
        "authentication": [
          "@id": "https://w3id.org/security#authenticationMethod",
          "@type": "@id",
          "@container": "@set",
        ],
      ]
    ]
    let dictionary = CBORLDDocumentDictionary(
      code: 2, contexts: [contextURL: 0x8744])
    let loader: CBORLDDocumentLoader = { _ in context }
    let multikey = "z6MkpTHR8VNsBxYAAWHut2Geadd9jSwuBV8xRoAnwWsdvktH"
    let vectors: [(String, String)] = [
      (
        "did:key:",
        "d9cb1d8202a300198744186581831904015822ed0194966b7c08e405775f8de6cc1c4508f6eb227403e1025b2c8ad2d7477398c5b25822ed0194966b7c08e405775f8de6cc1c4508f6eb227403e1025b2c8ad2d7477398c5b21866821904015822ed0194966b7c08e405775f8de6cc1c4508f6eb227403e1025b2c8ad2d7477398c5b2"
      ),
      (
        "did:v1:nym:",
        "d9cb1d8202a300198744186581831904005822ed0194966b7c08e405775f8de6cc1c4508f6eb227403e1025b2c8ad2d7477398c5b25822ed0194966b7c08e405775f8de6cc1c4508f6eb227403e1025b2c8ad2d7477398c5b21866821904005822ed0194966b7c08e405775f8de6cc1c4508f6eb227403e1025b2c8ad2d7477398c5b2"
      ),
    ]
    for (prefix, expected) in vectors {
      let id = prefix + multikey
      let document: JSONValue = [
        "@context": .string(contextURL),
        "id": .string(id),
        "authentication": [.string(id + "#" + multikey)],
      ]
      let encoded = try await CBORLDEncoder(
        dictionary: dictionary, documentLoader: loader
      ).encode(document)
      XCTAssertEqual(encoded.hex, expected)
      let decoded = try await CBORLDDecoder(
        dictionaries: [dictionary], documentLoader: loader
      ).decode(encoded)
      XCTAssertEqual(decoded, document)
    }
  }

  func testDateCodecsAndWideLexicalRange() async throws {
    let context: JSONValue = [
      "date": [
        "@id": "ex:date",
        "@type": "http://www.w3.org/2001/XMLSchema#date",
      ],
      "dateTime": [
        "@id": "ex:dateTime",
        "@type": "http://www.w3.org/2001/XMLSchema#dateTime",
      ],
    ]
    let document: JSONValue = [
      "@context": context,
      "date": [
        "-1000-01-01", "0-01-01", "1000-01-01", "1969-12-31",
        "1970-01-01", "2021-04-09", "3000-01-01", "10000-01-01",
      ],
      "dateTime": [
        "-1000-01-01T00:00:00Z", "0-01-01T00:00:00Z",
        "1000-01-01T00:00:00Z", "1000-01-01T00:00:00.123Z",
        "1969-12-31T23:59:59Z", "1970-01-01T00:00:00Z",
        "2021-04-09T20:38:55Z", "3000-01-01T00:00:00.123Z",
        "10000-01-01T00:00:00Z",
      ],
    ]
    let encoded = try await CBORLDEncoder().encode(document)
    let decoded = try await CBORLDDecoder().decode(encoded)
    XCTAssertEqual(decoded, document)

    let remoteURL = "urn:date-context"
    let remote: JSONValue = ["@context": context]
    let dictionary = CBORLDDocumentDictionary(
      code: 2, contexts: [remoteURL: 0x8000])
    let loader: CBORLDDocumentLoader = { _ in remote }
    let singleDate: JSONValue = [
      "@context": .string(remoteURL),
      "date": "2021-04-09",
    ]
    let dateBytes = try await CBORLDEncoder(
      dictionary: dictionary, documentLoader: loader
    ).encode(singleDate)
    XCTAssertEqual(dateBytes.hex, "d9cb1d8202a20019800018641a606f9900")
  }

  func testCryptosuiteTypedTableAndProtectedTerms() async throws {
    let contextURL = "urn:security-context"
    let context: JSONValue = [
      "@context": [
        "@protected": true,
        "foo": [
          "@id": "ex:foo",
          "@type": "https://w3id.org/security#cryptosuiteString",
        ],
      ]
    ]
    let dictionary = CBORLDDocumentDictionary(
      code: 2,
      contexts: [contextURL: 0x8000],
      typedValues: [
        "https://w3id.org/security#cryptosuiteString": [
          "ecdsa-rdfc-2019": 1,
          "ecdsa-sd-2023": 2,
          "eddsa-rdfc-2022": 3,
        ]
      ])
    let loader: CBORLDDocumentLoader = { _ in context }
    let document: JSONValue = [
      "@context": .string(contextURL),
      "foo": ["ecdsa-rdfc-2019", "ecdsa-sd-2023", "eddsa-rdfc-2022"],
    ]
    let encoded = try await CBORLDEncoder(
      dictionary: dictionary, documentLoader: loader
    ).encode(document)
    XCTAssertEqual(encoded.hex, "d9cb1d8202a200198000186583010203")
    let decoded = try await CBORLDDecoder(
      dictionaries: [dictionary], documentLoader: loader
    ).decode(encoded)
    XCTAssertEqual(decoded, document)

    let redefined: JSONValue = [
      "@context": [
        .string(contextURL),
        ["foo": "ex:changed"],
      ],
      "foo": "ecdsa-rdfc-2019",
    ]
    do {
      _ = try await CBORLDEncoder(
        dictionary: dictionary, documentLoader: loader
      ).encode(redefined)
      XCTFail("Expected protected term redefinition to fail")
    } catch let error as CBORLDError {
      XCTAssertEqual(error.code, "ERR_PROTECTED_TERM_REDEFINITION")
    }
  }

  func testUndefinedCompressedContextIsRejected() async throws {
    let encoded = Data(
      hex: "d9cb1d8202a200198000186583444d010203447a0102034475010203")
    let dictionary = CBORLDDocumentDictionary(code: 2)
    do {
      _ = try await CBORLDDecoder(dictionaries: [dictionary]).decode(encoded)
      XCTFail("Expected undefined compressed context to fail")
    } catch let error as CBORLDError {
      XCTAssertEqual(error.code, "ERR_UNDEFINED_COMPRESSED_CONTEXT")
    }
  }

  func testLegacyNoteFixtureIsByteCompatible() async throws {
    let context = try JSONValue(
      data: Data(contentsOf: try fixtureURL(named: "activitystreams", extension: "jsonld")))
    let document = try JSONValue(
      data: Data(contentsOf: try fixtureURL(named: "note", extension: "jsonld")))
    let expected = try Data(contentsOf: try fixtureURL(named: "note", extension: "cborld"))
    let loader: CBORLDDocumentLoader = { url in
      guard url == "https://www.w3.org/ns/activitystreams" else {
        throw TestError.unknownContext(url)
      }
      return context
    }

    let encoder = CBORLDEncoder(
      format: .legacySingleton,
      documentLoader: loader)
    let encoded = try await encoder.encode(document)
    XCTAssertEqual(encoded, expected)
    let decoded = try await CBORLDDecoder(documentLoader: loader).decode(expected)
    XCTAssertEqual(decoded, document)
  }

  func testHopperDidKeyFixtureIsDataNotCode() throws {
    let data = try Data(contentsOf: try fixtureURL(named: "didKey", extension: "cborld"))
    let inspection = try CBORLD.inspect(data)
    XCTAssertEqual(inspection.format, .legacySingleton)
    XCTAssertNil(inspection.registryEntryID)
    XCTAssertTrue(inspection.payloadIsCompressed)
    XCTAssertEqual(inspection.byteCount, 534)
    XCTAssertTrue(inspection.payloadDescription.hasPrefix("{"))
    XCTAssertTrue(inspection.payloadDescription.contains("h'"))
  }

  func testConfiguredDecoderRejectsDisabledFormat() async throws {
    let legacy = try await CBORLD.encode(
      [:],
      options: .init(
        format: .legacySingleton,
        registryEntryID: nil))
    let decoder = CBORLDDecoder(supportedFormats: [.cborLD1])
    do {
      _ = try await decoder.decode(legacy)
      XCTFail("Expected unsupported format error")
    } catch let error as CBORLDError {
      XCTAssertEqual(error.code, "ERR_UNSUPPORTED_FORMAT")
    }
  }

  func testCodableConvenienceAPIAndContextRegistry() async throws {
    struct Note: Codable, Equatable, Sendable {
      var `context`: String
      var type: String
      var summary: String

      enum CodingKeys: String, CodingKey {
        case context = "@context"
        case type
        case summary
      }
    }

    let contextURL = "https://example.com/notes"
    let context: JSONValue = [
      "@context": [
        "type": "@type",
        "Note": "https://example.com/Note",
        "summary": "https://example.com/summary",
      ]
    ]
    let registry = CBORLDContextRegistry(documents: [contextURL: context])
    let note = Note(context: contextURL, type: "Note", summary: "Swift")
    let options = CBORLDEncodingOptions(
      registryEntryID: 1,
      documentLoader: registry.documentLoader)
    let encoded = try await CBORLD.encode(note, options: options)
    let decoded = try await CBORLD.decode(
      Note.self,
      from: encoded,
      options: .init(documentLoader: registry.documentLoader))
    XCTAssertEqual(decoded, note)

    let reusableEncoder = CBORLDEncoder(documentLoader: registry.documentLoader)
    let reusableBytes = try await reusableEncoder.encode(note)
    let reusableDecoder = CBORLDDecoder(documentLoader: registry.documentLoader)
    let reusableNote = try await reusableDecoder.decode(Note.self, from: reusableBytes)
    XCTAssertEqual(reusableNote, note)
  }

  func testTransportDigestKnownAnswersAndVerification() throws {
    let input = Data("abc".utf8)
    let sha256 = CBORLD.transportDigest(of: input)
    XCTAssertEqual(
      sha256.hex,
      "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    XCTAssertEqual(sha256.algorithm, .sha256)
    XCTAssertEqual(sha256.domain, .encodedBytes)
    XCTAssertEqual(sha256.version, 1)
    XCTAssertNoThrow(try CBORLD.verify(input, against: sha256))

    let sha384 = CBORLD.transportDigest(of: input, algorithm: .sha384)
    XCTAssertEqual(
      sha384.hex,
      "cb00753f45a35e8bb5a03d699ac65007272c32ab0eded1631a8b605a43ff5bed"
        + "8086072ba1e7cc2358baeca134c825a7")

    let sha512 = CBORLD.transportDigest(of: input, algorithm: .sha512)
    XCTAssertEqual(
      sha512.hex,
      "ddaf35a193617abacc417349ae20413112e6fa4e89a97ea20a9eeee64b55d39a"
        + "2192992a274fc1a836ba3c23a3feebbd454d4423643ce80e2a9ac94fa54ca49f")

    XCTAssertThrowsError(try CBORLD.verify(Data("abd".utf8), against: sha256)) { error in
      XCTAssertEqual((error as? CBORLDError)?.code, "ERR_INTEGRITY_MISMATCH")
    }
  }

  func testDigestHexAndCodableRoundTrip() throws {
    let original = CBORLD.transportDigest(of: Data("persist me".utf8))
    let parsed = try CBORLDDigest(
      algorithm: original.algorithm,
      domain: original.domain,
      version: original.version,
      hex: original.hex)
    XCTAssertEqual(parsed, original)
    XCTAssertFalse(parsed.base64URL.contains("="))
    XCTAssertTrue(parsed.description.hasPrefix("sha2-256:encoded-bytes:v1:"))

    let encoded = try JSONEncoder().encode(original)
    XCTAssertEqual(try JSONDecoder().decode(CBORLDDigest.self, from: encoded), original)
    XCTAssertThrowsError(
      try CBORLDDigest(
        algorithm: .sha256,
        domain: .encodedBytes,
        hex: "not-a-digest"))
  }

  func testStructuralFingerprintHasExplicitSemanticBoundary() throws {
    var firstObject: [String: JSONValue] = [:]
    firstObject["longer"] = 1
    firstObject["b"] = [true, "value"]

    var reorderedObject: [String: JSONValue] = [:]
    reorderedObject["b"] = [true, "value"]
    reorderedObject["longer"] = 1

    let first = try CBORLD.structuralFingerprint(of: .object(firstObject))
    let reordered = try CBORLD.structuralFingerprint(of: .object(reorderedObject))
    XCTAssertEqual(first, reordered)
    XCTAssertEqual(first.domain, .documentStructure)
    XCTAssertNoThrow(try CBORLD.verifyDocument(.object(reorderedObject), against: first))

    let changed: JSONValue = ["b": ["value", true], "longer": 1]
    XCTAssertNotEqual(try CBORLD.structuralFingerprint(of: changed), first)
    XCTAssertThrowsError(try CBORLD.verifyDocument(changed, against: first)) { error in
      XCTAssertEqual((error as? CBORLDError)?.code, "ERR_INTEGRITY_MISMATCH")
    }

    let contextFingerprint = try CBORLD.contextFingerprint(of: .object(firstObject))
    XCTAssertNotEqual(contextFingerprint, first)
    XCTAssertEqual(contextFingerprint.domain, .contextDocument)
  }

  func testDeterministicSerializationIsExplicitAndRoundTrips() async throws {
    let rawMap = CBORValue.map([
      .init(key: .string("aa"), value: .unsigned(0)),
      .init(key: .string("b"), value: .unsigned(0)),
    ])
    XCTAssertEqual(
      try CBOREncoder.encode(rawMap, mode: .compatibility).hex,
      "a261620062616100")
    XCTAssertEqual(
      try CBOREncoder.encode(rawMap, mode: .deterministic).hex,
      "a261620062616100")
    XCTAssertEqual(
      try CBOREncoder.encode(.double(1.5), mode: .deterministic).hex,
      "f93e00")
    XCTAssertEqual(
      try CBOREncoder.encode(.double(1.5), mode: .compatibility).hex,
      "f93e00")
    XCTAssertEqual(
      try CBOREncoder.encode(.double(-0.0), mode: .deterministic).hex,
      "f98000")
    XCTAssertEqual(
      try CBOREncoder.encode(.double(.nan), mode: .deterministic).hex,
      "f97e00")

    let document: JSONValue = ["aa": 0, "b": 0]
    let compatible = try await CBORLD.encode(
      document,
      options: .init(registryEntryID: 0))
    let deterministic = try await CBORLD.encode(
      document,
      options: .init(
        serializationMode: .deterministic,
        registryEntryID: 0))
    XCTAssertEqual(compatible.hex, "d9cb1d8200a261620062616100")
    XCTAssertEqual(deterministic.hex, "d9cb1d8200a261620062616100")
    let compatibleDecoded = try await CBORLD.decode(compatible)
    let deterministicDecoded = try await CBORLD.decode(deterministic)
    XCTAssertEqual(compatibleDecoded, document)
    XCTAssertEqual(deterministicDecoded, document)
  }

  func testCompatibilityJSONShapesMatchJavaScriptPreferredBytes() async throws {
    let document: JSONValue = [
      "active": true,
      "count": 7,
      "items": [nil, "hello", -3, 1.5],
      "nested": ["a": 1, "longer-key": "value"],
    ]
    let encoded = try await CBORLD.encode(
      document,
      options: .init(registryEntryID: 0))
    let synchronous = try CBORLD.encodeUncompressed(document)
    XCTAssertEqual(synchronous, encoded)
    XCTAssertEqual(
      encoded.hex,
      "d9cb1d8200a465636f756e7407656974656d7384f66568656c6c6f22f93e0066616374697665f5666e6573746564a26161016a6c6f6e6765722d6b65796576616c7565"
    )
    XCTAssertEqual(try CBORLD.decodeUncompressed(encoded), document)
  }

  func testDictionaryValidationAndFingerprinting() throws {
    let first = CBORLDDocumentDictionary(
      code: 42,
      profileName: "example",
      profileVersion: "1",
      contexts: ["urn:z": 32_769, "urn:a": 32_768],
      typedValues: ["urn:type": ["active": 32_770]],
      uris: ["https://example.com": 32_771],
      untypedValues: ["constant": 32_772])
    let reordered = CBORLDDocumentDictionary(
      code: 42,
      profileName: "example",
      profileVersion: "1",
      contexts: ["urn:a": 32_768, "urn:z": 32_769],
      typedValues: ["urn:type": ["active": 32_770]],
      uris: ["https://example.com": 32_771],
      untypedValues: ["constant": 32_772])
    try first.validate()
    let fingerprint = try first.fingerprint()
    XCTAssertEqual(fingerprint, try reordered.fingerprint())
    XCTAssertEqual(fingerprint.domain, .documentDictionary)
    XCTAssertNoThrow(try reordered.verifyFingerprint(fingerprint))
    let persisted = try JSONEncoder().encode(first)
    XCTAssertEqual(
      try JSONDecoder().decode(CBORLDDocumentDictionary.self, from: persisted), first)

    let changed = CBORLDDocumentDictionary(
      code: 42,
      profileName: "example",
      profileVersion: "2",
      contexts: first.contexts,
      typedValues: first.typedValues,
      uris: first.uris,
      untypedValues: first.untypedValues)
    XCTAssertNotEqual(try changed.fingerprint(), fingerprint)
    XCTAssertThrowsError(try changed.verifyFingerprint(fingerprint)) { error in
      XCTAssertEqual((error as? CBORLDError)?.code, "ERR_INTEGRITY_MISMATCH")
    }

    for invalid in [
      CBORLDDocumentDictionary(code: 0, contexts: ["urn:x": 1]),
      CBORLDDocumentDictionary(code: 2, contexts: ["urn:x": 7, "urn:y": 7]),
      CBORLDDocumentDictionary(code: 2, typedValues: ["context": [:]]),
      CBORLDDocumentDictionary(code: CBORLDConstants.maximumSafeInteger + 1),
    ] {
      XCTAssertThrowsError(try invalid.validate()) { error in
        XCTAssertEqual((error as? CBORLDError)?.code, "ERR_INVALID_DICTIONARY")
      }
    }
  }

  func testPinnedContextFingerprint() async throws {
    let url = "https://example.com/context"
    let context: JSONValue = ["@context": ["name": "https://schema.org/name"]]
    let expected = try CBORLD.contextFingerprint(of: context)
    let registry = CBORLDContextRegistry(
      documents: [url: context],
      expectedFingerprints: [url: expected])
    let loaded = try await registry.load(url)
    XCTAssertEqual(loaded, context)

    let changed: JSONValue = ["@context": ["name": "https://example.com/name"]]
    let tampered = CBORLDContextRegistry(
      documents: [url: changed],
      expectedFingerprints: [url: expected])
    do {
      _ = try await tampered.load(url)
      XCTFail("Expected a context integrity failure")
    } catch let error as CBORLDError {
      XCTAssertEqual(error.code, "ERR_INTEGRITY_MISMATCH")
    }

    let wrongDomain = try CBORLD.structuralFingerprint(of: context)
    let misconfigured = CBORLDContextRegistry(
      documents: [url: context],
      expectedFingerprints: [url: wrongDomain])
    do {
      _ = try await misconfigured.load(url)
      XCTFail("Expected a digest-domain failure")
    } catch let error as CBORLDError {
      XCTAssertEqual(error.code, "ERR_INVALID_DIGEST")
    }
  }

  func testDuplicateDecoderDictionaryCodesAreRejectedWithoutTrap() async throws {
    let encoded = try await CBORLD.encode(
      [:], options: .init(registryEntryID: 1))
    let decoder = CBORLDDecoder(
      dictionaries: [.unregistered, .unregistered])
    do {
      _ = try await decoder.decode(encoded)
      XCTFail("Expected an invalid dictionary error")
    } catch let error as CBORLDError {
      XCTAssertEqual(error.code, "ERR_INVALID_DICTIONARY")
    }
  }

  func testDecoderCanPinDictionaryIdentity() async throws {
    let dictionary = CBORLDDocumentDictionary(
      code: 42,
      profileName: "example-profile",
      profileVersion: "1",
      contexts: ["urn:example": 32_768])
    let expected = try dictionary.fingerprint()
    let document: JSONValue = [:]
    let encoded = try await CBORLDEncoder(dictionary: dictionary).encode(document)

    let pinned = CBORLDDecoder(
      dictionaries: [dictionary],
      requiredDictionaryFingerprints: [dictionary.code: expected])
    let pinnedDecoded = try await pinned.decode(encoded)
    XCTAssertEqual(pinnedDecoded, document)

    let changed = CBORLDDocumentDictionary(
      code: 42,
      profileName: "example-profile",
      profileVersion: "2",
      contexts: dictionary.contexts)
    let mismatched = CBORLDDecoder(
      dictionaries: [changed],
      requiredDictionaryFingerprints: [dictionary.code: expected])
    do {
      _ = try await mismatched.decode(encoded)
      XCTFail("Expected a dictionary integrity failure")
    } catch let error as CBORLDError {
      XCTAssertEqual(error.code, "ERR_INTEGRITY_MISMATCH")
    }

    let missing = CBORLDDecoder(
      dictionaries: [],
      requiredDictionaryFingerprints: [dictionary.code: expected])
    do {
      _ = try await missing.decode(encoded)
      XCTFail("Expected a missing dictionary failure")
    } catch let error as CBORLDError {
      XCTAssertEqual(error.code, "ERR_INVALID_DICTIONARY")
    }
  }

  func testMalformedEnvelopeIsRejected() throws {
    for hex in [
      "a0",  // a CBOR map, but not tagged CBOR-LD
      "d9cb1d8101",  // current envelope has only one array item
      "d9068082420100a0",  // legacy varint terminates before a trailing byte
    ] {
      XCTAssertThrowsError(try CBORLD.inspect(Data(hex: hex))) { error in
        XCTAssertEqual((error as? CBORLDError)?.code, "ERR_NOT_CBORLD")
      }
    }
  }

  func testMalformedSemanticPayloadsAreRejected() async throws {
    let duplicateContext = Data(hex: "d9cb1d8201a200a000a0")
    do {
      _ = try await CBORLD.decode(duplicateContext)
      XCTFail("Expected duplicate context key to fail")
    } catch let error as CBORLDError {
      XCTAssertEqual(error.code, "ERR_INVALID_ENCODED_CONTEXT")
    }

    let duplicateTerm = Data(hex: "d9cb1d8201a2617801617802")
    do {
      _ = try await CBORLD.decode(duplicateTerm)
      XCTFail("Expected duplicate term to fail")
    } catch let error as CBORLDError {
      XCTAssertEqual(error.code, "ERR_INVALID_INPUT")
    }

    let nonFiniteJSONNumber = Data(hex: "d9cb1d8200f97e00")
    do {
      _ = try await CBORLD.decode(nonFiniteJSONNumber)
      XCTFail("Expected non-finite JSON number to fail")
    } catch let error as CBORLDError {
      XCTAssertEqual(error.code, "ERR_INVALID_INPUT")
    }
  }

  func testCircularContextImportsAreRejected() async throws {
    let firstURL = "urn:context:first"
    let secondURL = "urn:context:second"
    let first: JSONValue = [
      "@context": ["@import": .string(secondURL), "first": "ex:first"]
    ]
    let second: JSONValue = [
      "@context": ["@import": .string(firstURL), "second": "ex:second"]
    ]
    let loader: CBORLDDocumentLoader = { url in
      switch url {
      case firstURL: return first
      case secondURL: return second
      default: throw TestError.unknownContext(url)
      }
    }
    let dictionary = CBORLDDocumentDictionary(
      code: 2, contexts: [firstURL: 32_768])
    let document: JSONValue = ["@context": .string(firstURL), "first": "value"]
    do {
      _ = try await CBORLDEncoder(
        dictionary: dictionary, documentLoader: loader
      ).encode(document)
      XCTFail("Expected a circular context import to fail")
    } catch let error as CBORLDError {
      XCTAssertEqual(error.code, "ERR_INVALID_CONTEXT")
    }
  }

  func testRemoteContextImportRoundTrip() async throws {
    let baseURL = "urn:context:base"
    let applicationURL = "urn:context:application"
    let base: JSONValue = ["@context": ["name": "https://schema.org/name"]]
    let application: JSONValue = [
      "@context": [
        "@import": .string(baseURL),
        "status": "https://example.com/status",
      ]
    ]
    let loader: CBORLDDocumentLoader = { url in
      switch url {
      case baseURL: return base
      case applicationURL: return application
      default: throw TestError.unknownContext(url)
      }
    }
    let dictionary = CBORLDDocumentDictionary(
      code: 2, contexts: [applicationURL: 32_768])
    let document: JSONValue = [
      "@context": .string(applicationURL),
      "name": "Ada",
      "status": "active",
    ]
    let encoded = try await CBORLDEncoder(
      dictionary: dictionary, documentLoader: loader
    ).encode(document)
    let decoded = try await CBORLDDecoder(
      dictionaries: [dictionary], documentLoader: loader
    ).decode(encoded)
    XCTAssertEqual(decoded, document)
  }

  func testVocabPluralTypesAndNestedArraysRoundTrip() async throws {
    let document: JSONValue = [
      "@context": [
        "@vocab": "http://example.com/vocab/",
        "type": "@type",
        "Type1": "ex:Type1",
        "Type2": "ex:Type2",
        "set": "ex:set",
      ],
      "type": ["Type1", "Type2"],
      "set": [
        [["type": "Type1"]],
        ["string1", "string2", ["string3"]],
      ],
    ]
    let encoded = try await CBORLDEncoder().encode(document)
    let decoded = try await CBORLDDecoder().decode(encoded)
    XCTAssertEqual(decoded, document)
  }

  func testLargeRepeatedObjectKeysRoundTripThroughFastPath() throws {
    let record: JSONValue = [
      "active": true,
      "flags": ["verified": false],
      "id": 42,
      "label": "Repeated record",
      "tags": ["one", "two"],
      "uri": "https://example.test/records/42",
      "values": [1, 2, 3, 4],
    ]
    let document: JSONValue = [
      "records": .array(Array(repeating: record, count: 256))
    ]

    let encoded = try CBORLD.encodeUncompressed(document)
    XCTAssertGreaterThan(encoded.count, 4_096)
    XCTAssertEqual(try CBORLD.decodeUncompressed(encoded), document)
  }

  func testLargeFastPathRejectsInvalidUTF8() {
    var malformed = Data([0xd9, 0xcb, 0x1d, 0x82, 0x00, 0x79, 0x10, 0x00])
    malformed.append(contentsOf: repeatElement(UInt8(0x61), count: 4_095))
    malformed.append(0xff)

    XCTAssertThrowsError(try CBORLD.decodeUncompressed(malformed)) { error in
      XCTAssertEqual((error as? CBORLDError)?.code, "ERR_NOT_CBORLD")
    }
  }

  func testSmallFastPathRejectsInvalidUTF8() {
    let malformed = Data([0xd9, 0xcb, 0x1d, 0x82, 0x00, 0x61, 0xff])

    XCTAssertThrowsError(try CBORLD.decodeUncompressed(malformed)) { error in
      XCTAssertEqual((error as? CBORLDError)?.code, "ERR_NOT_CBORLD")
    }
  }

  func testLargeFastPathHandlesUniqueUnicodeDeepAndWideObjects() throws {
    let uniqueShort = JSONValue.object(
      Dictionary(
        uniqueKeysWithValues: (0..<1_024).map { index in
          (String(format: "k%06d", index), JSONValue.integer(Int64(index)))
        }))
    let uniqueBytes = try CBORLD.encodeUncompressed(uniqueShort)
    XCTAssertGreaterThan(uniqueBytes.count, 4_096)
    XCTAssertEqual(try CBORLD.decodeUncompressed(uniqueBytes), uniqueShort)

    let unicode = JSONValue.object(
      Dictionary(
        uniqueKeysWithValues: (0..<256).map { index in
          ("長い🔐フィールド名-\(index)", JSONValue.string("値-\(index)"))
        }))
    let unicodeBytes = try CBORLD.encodeUncompressed(unicode)
    XCTAssertGreaterThan(unicodeBytes.count, 4_096)
    XCTAssertEqual(try CBORLD.decodeUncompressed(unicodeBytes), unicode)

    var deep: JSONValue = ["padding": .string(String(repeating: "x", count: 4_096))]
    for _ in 0..<64 { deep = ["nested": deep] }
    let deepBytes = try CBORLD.encodeUncompressed(deep)
    XCTAssertGreaterThan(deepBytes.count, 4_096)
    XCTAssertEqual(try CBORLD.decodeUncompressed(deepBytes), deep)
  }

  func testDecodingResourceLimits() throws {
    let valid = Data(hex: "d9cb1d8200a0")
    XCTAssertThrowsError(
      try CBORLD.inspect(
        valid,
        limits: .init(maximumInputBytes: 5))
    ) { error in
      XCTAssertEqual((error as? CBORLDError)?.code, "ERR_RESOURCE_LIMIT")
    }

    let tooManyArrayItems = Data(hex: "d9cb1d820083000102")
    XCTAssertThrowsError(
      try CBORLD.inspect(
        tooManyArrayItems,
        limits: .init(maximumContainerItems: 2))
    ) { error in
      XCTAssertEqual((error as? CBORLDError)?.code, "ERR_RESOURCE_LIMIT")
    }

    let deeplyNested = Data(hex: "d9cb1d820081818100")
    XCTAssertThrowsError(
      try CBORLD.inspect(
        deeplyNested,
        limits: .init(maximumNestingDepth: 4))
    ) { error in
      XCTAssertEqual((error as? CBORLDError)?.code, "ERR_RESOURCE_LIMIT")
    }
  }

  private func fixtureURL(named name: String, extension fileExtension: String) throws -> URL {
    try XCTUnwrap(
      Bundle.module.url(
        forResource: name,
        withExtension: fileExtension,
        subdirectory: "Fixtures/upstream-digitalbazaar"))
  }
}

private enum TestError: Error {
  case unknownContext(String)
}

extension Data {
  fileprivate var hex: String { map { String(format: "%02x", $0) }.joined() }

  fileprivate init(hex: String) {
    self.init()
    var index = hex.startIndex
    while index < hex.endIndex {
      let next = hex.index(index, offsetBy: 2)
      append(UInt8(hex[index..<next], radix: 16)!)
      index = next
    }
  }
}
