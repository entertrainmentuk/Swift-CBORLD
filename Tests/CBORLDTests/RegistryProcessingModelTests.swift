import Foundation
import XCTest

@testable import CBORLD

/// Registry entries select a processing model, registry dictionaries, and a
/// provisional status (CBOR-LD 1.0 editor's draft, w3c/cbor-ld 992f9335703c).
final class RegistryProcessingModelTests: XCTestCase {
  private let dateTimeType = CBORLDProcessingModel.xsdDateTimeType
  private let ipv4Type = "https://example.org/vocab#ipv4"

  // MARK: Default model compatibility

  func testDefaultProcessingModelKeepsEstablishedJavaScriptBytes() async throws {
    let contextURL = "urn:foo"
    let loader = fixedLoader([
      contextURL: [
        "@context": [
          "arbitraryPrefix": "http://www.w3.org/2001/XMLSchema#",
          "foo": ["@id": "ex:foo", "@type": "arbitraryPrefix:dateTime"],
        ]
      ]
    ])
    let document: JSONValue = ["@context": .string(contextURL), "foo": "2021-04-09T20:38:55Z"]
    let expected = "d9cb1d8202a20019800018661a6070bb5f"
    let tables: CBORLDTypeTable = ["context": [.string(contextURL): 0x8000]]

    let viaTypeTable = try await CBORLD.encode(
      document,
      options: .init(
        registryEntryID: 2, documentLoader: loader, typeTableLoader: { _ in tables }))
    XCTAssertEqual(viaTypeTable.hexString, expected)

    for model in [nil, CBORLDProcessingModel.default] {
      let entry = CBORLDRegistryEntry(id: 2, processingModel: model, typeTables: tables)
      let bytes = try await CBORLD.encode(
        document,
        options: .init(
          registryEntryID: 2, documentLoader: loader, registryEntryLoader: { _ in entry }))
      XCTAssertEqual(bytes.hexString, expected)
      let decoded = try await CBORLD.decode(
        bytes, options: .init(documentLoader: loader, registryEntryLoader: { _ in entry }))
      XCTAssertEqual(decoded, document)
    }
  }

  func testDefaultModelMatchesTheDraftExample() throws {
    let example = Data(
      """
      {"semanticCompression": true, "codecs": {
        "url": "url",
        "http://www.w3.org/2001/XMLSchema#date": "xsd-date",
        "http://www.w3.org/2001/XMLSchema#dateTime": "xsd-date-time",
        "https://w3id.org/security#multibase": "multibase"}}
      """.utf8)
    XCTAssertEqual(
      try JSONDecoder().decode(CBORLDProcessingModel.self, from: example), .default)
    // An absent member is `true`; absent codecs bind nothing outside the
    // default model.
    let empty = try JSONDecoder().decode(CBORLDProcessingModel.self, from: Data("{}".utf8))
    XCTAssertTrue(empty.semanticCompression)
    XCTAssertTrue(empty.codecs.isEmpty)
    XCTAssertEqual(CBORLDRegistryEntry(id: 7).effectiveProcessingModel, .default)
    XCTAssertEqual(CBORLDRegistryEntry.uncompressed.effectiveProcessingModel, .uncompressed)
  }

  // MARK: Semantic compression disabled

  func testNonzeroEntryWithoutSemanticCompressionEmitsPlainCBOR() async throws {
    let entry = CBORLDRegistryEntry(
      id: 100, useCase: "plain", processingModel: .uncompressed)
    let document: JSONValue = [
      "@context": "urn:never-loaded", "name": "plain", "values": [1, 2.5, "x"],
    ]
    let bytes = try await CBORLD.encode(
      document, options: .init(registryEntryID: 100, registryEntryLoader: { _ in entry }))
    let plain = try CBORLD.encodeUncompressed(document).hexString
    XCTAssertEqual(bytes.hexString, "d9cb1d821864" + plain.dropFirst(10))

    // No context is loaded, so no document loader is needed in either direction.
    let decoded = try await CBORLD.decode(
      bytes, options: .init(registryEntryLoader: { _ in entry }))
    XCTAssertEqual(decoded, document)
    let inspection = try CBORLD.inspect(bytes)
    XCTAssertEqual(inspection.registryEntryID, 100)
    XCTAssertTrue(inspection.payloadIsCompressed, "Inspection reports the envelope only.")
  }

  func testProcessingModelWithOnlyTheDateTimeCodec() async throws {
    let contextURL = "urn:ctx"
    let loader = fixedLoader([
      contextURL: [
        "@context": [
          "when": ["@id": "ex:when", "@type": .string(dateTimeType)],
          "day": ["@id": "ex:day", "@type": .string(CBORLDProcessingModel.xsdDateType)],
          "link": ["@id": "ex:link", "@type": "@id"],
        ]
      ]
    ])
    let entry = CBORLDRegistryEntry(
      id: 101,
      processingModel: .init(
        semanticCompression: false, codecs: [dateTimeType: .xsdDateTime]))
    let options = CBORLDEncodingOptions(
      registryEntryID: 101, documentLoader: loader, registryEntryLoader: { _ in entry })
    let decodeOptions = CBORLDDecodingOptions(
      documentLoader: loader, registryEntryLoader: { _ in entry })

    let document: JSONValue = [
      "@context": .string(contextURL),
      "when": "2021-04-09T20:38:55Z",
      "day": "2021-04-09",
      "link": "https://example.com/a",
    ]
    let bytes = try await CBORLD.encode(document, options: options)
    // Keys stay strings; only the dateTime value is compressed.
    XCTAssertEqual(
      bytes.hexString,
      "d9cb1d821865a4" + "63646179" + "6a323032312d30342d3039" + "646c696e6b"
        + "7568747470733a2f2f6578616d706c652e636f6d2f61" + "647768656e" + "1a6070bb5f"
        + "6840636f6e74657874" + "6775726e3a637478")
    let restored = try await CBORLD.decode(bytes, options: decodeOptions)
    XCTAssertEqual(restored, document)

    for when: JSONValue in [
      ["2021-04-09T20:38:55Z"],
      ["2021-04-09T20:38:55Z", "2021-04-09T20:38:56Z"],
      ["2021-04-09T20:38:55Z", "2021-04-09T20:38:56Z", "2021-04-09T20:38:57Z"],
      "2021-04-09T20:38:55.123Z",
      ["2021-04-09T20:38:55.123Z", "2021-04-09T20:38:56Z"],
    ] {
      let value: JSONValue = ["@context": .string(contextURL), "when": when]
      let encoded = try await CBORLD.encode(value, options: options)
      let decoded = try await CBORLD.decode(encoded, options: decodeOptions)
      XCTAssertEqual(decoded, value, "\(when)")
    }

    // Two whole-second values would read back as one fractional dateTime, so
    // they are carried as strings instead.
    let pair: JSONValue = [
      "@context": .string(contextURL), "when": ["2021-04-09T20:38:55Z", "2021-04-09T20:38:56Z"],
    ]
    let pairBytes = try await CBORLD.encode(pair, options: options)
    XCTAssertTrue(pairBytes.hexString.contains(Data("2021-04-09T20:38:56Z".utf8).hexString))

    // Integers are not dateTimes and no fallback can separate them.
    await assertCBORLDError(.ambiguousValue) {
      _ = try await CBORLD.encode(
        ["@context": .string(contextURL), "when": [1, 2]], options: options)
    }
  }

  func testTypeTablesApplyWithoutSemanticTermCompression() async throws {
    let contextURL = "urn:suite"
    let suiteType = "https://w3id.org/security#cryptosuiteString"
    let loader = fixedLoader([
      contextURL: [
        "@context": [
          "cryptosuite": [
            "@id": "https://w3id.org/security#cryptosuite", "@type": .string(suiteType),
          ]
        ]
      ]
    ])
    let entry = CBORLDRegistryEntry(
      id: 106,
      processingModel: .uncompressed,
      typeTables: [
        "context": [.string(contextURL): 1],
        suiteType: ["ecdsa-rdfc-2019": 1],
      ])
    let document: JSONValue = ["@context": .string(contextURL), "cryptosuite": "ecdsa-rdfc-2019"]
    let bytes = try await CBORLD.encode(
      document,
      options: .init(
        registryEntryID: 106, documentLoader: loader, registryEntryLoader: { _ in entry }))
    XCTAssertEqual(
      bytes.hexString,
      "d9cb1d82186aa2" + "6840636f6e74657874" + "01" + "6b63727970746f7375697465" + "01")
    let decoded = try await CBORLD.decode(
      bytes, options: .init(documentLoader: loader, registryEntryLoader: { _ in entry }))
    XCTAssertEqual(decoded, document)
  }

  // MARK: Codecs

  func testUnknownCodecIdentifierIsRejectedBeforeAnyWork() async throws {
    let entry = CBORLDRegistryEntry(
      id: 102, processingModel: .init(codecs: [ipv4Type: "https://example.org/codecs#none"]))
    await assertCBORLDError(.unknownCodec) {
      _ = try await CBORLD.encode(
        ["a": 1], options: .init(registryEntryID: 102, registryEntryLoader: { _ in entry }))
    }
    let bytes = Data(hexString: "d9cb1d821866a0")
    await assertCBORLDError(.unknownCodec) {
      _ = try await CBORLD.decode(bytes, options: .init(registryEntryLoader: { _ in entry }))
    }
  }

  func testUserSuppliedCodecRoundTripsWithExactBytes() async throws {
    let contextURL = "urn:ip"
    let loader = fixedLoader([
      contextURL: ["@context": ["address": ["@id": "ex:address", "@type": .string(ipv4Type)]]]
    ])
    var codecs = CBORLDProcessingModel.default.codecs
    codecs[ipv4Type] = IPv4Codec.id
    let entry = CBORLDRegistryEntry(id: 103, processingModel: .init(codecs: codecs))
    let codec = IPv4Codec(expectedRegistryEntryID: 103)
    let options = CBORLDEncodingOptions(
      registryEntryID: 103, documentLoader: loader,
      registryEntryLoader: { _ in entry }, codecs: [codec])
    let decodeOptions = CBORLDDecodingOptions(
      documentLoader: loader, registryEntryLoader: { _ in entry }, codecs: [codec])

    let document: JSONValue = ["@context": .string(contextURL), "address": "192.168.0.1"]
    let bytes = try await CBORLD.encode(document, options: options)
    XCTAssertEqual(
      bytes.hexString, "d9cb1d821867a200" + "6675726e3a6970" + "1864" + "44c0a80001")
    let restored = try await CBORLD.decode(bytes, options: decodeOptions)
    XCTAssertEqual(restored, document)

    // Values the codec declines are carried through unchanged.
    let mixed: JSONValue = ["@context": .string(contextURL), "address": ["10.0.0.1", "::1"]]
    let mixedDecoded = try await CBORLD.decode(
      try await CBORLD.encode(mixed, options: options), options: decodeOptions)
    XCTAssertEqual(mixedDecoded, mixed)

    // A reusable dictionary-based encoder and decoder bind the same model.
    let dictionary = CBORLDDocumentDictionary(
      code: 103, processingModel: .init(codecs: codecs))
    let encoder = CBORLDEncoder(dictionary: dictionary, documentLoader: loader, codecs: [codec])
    let decoder = CBORLDDecoder(
      dictionaries: [dictionary], documentLoader: loader, codecs: [codec])
    let viaDictionary = try await encoder.encode(document)
    XCTAssertEqual(viaDictionary, bytes)
    let decodedByDictionary = try await decoder.decode(viaDictionary)
    XCTAssertEqual(decodedByDictionary, document)
    let decodedByPrepared = try await decoder.prepare().decode(viaDictionary)
    XCTAssertEqual(decodedByPrepared, document)
  }

  func testUserCodecsMustBeInvertibleAndCannotCollideWithTables() async throws {
    let contextURL = "urn:ip"
    let loader = fixedLoader([
      contextURL: ["@context": ["address": ["@id": "ex:address", "@type": .string(ipv4Type)]]]
    ])
    let document: JSONValue = ["@context": .string(contextURL), "address": "192.168.0.1"]

    let lossy = CBORLDRegistryEntry(
      id: 110, processingModel: .init(codecs: [ipv4Type: LossyCodec.id]))
    await assertCBORLDError(.codecNotInvertible) {
      _ = try await CBORLD.encode(
        document,
        options: .init(
          registryEntryID: 110, documentLoader: loader,
          registryEntryLoader: { _ in lossy }, codecs: [LossyCodec()]))
    }

    // The codec emits an integer that the type's registry dictionary claims.
    let colliding = CBORLDRegistryEntry(
      id: 111,
      processingModel: .init(codecs: [ipv4Type: CollidingCodec.id]),
      typeTables: [ipv4Type: ["10.9.8.7": 1]])
    await assertCBORLDError(.codecNotInvertible) {
      _ = try await CBORLD.encode(
        document,
        options: .init(
          registryEntryID: 111, documentLoader: loader,
          registryEntryLoader: { _ in colliding }, codecs: [CollidingCodec()]))
    }

    let replacingBuiltIn = CBORLDRegistryEntry(id: 112)
    await assertCBORLDError(.invalidProcessingModel) {
      _ = try await CBORLD.encode(
        document,
        options: .init(
          registryEntryID: 112, documentLoader: loader,
          registryEntryLoader: { _ in replacingBuiltIn }, codecs: [BuiltInImpostor()]))
    }
    await assertCBORLDError(.invalidProcessingModel) {
      _ = try await CBORLD.encode(
        document,
        options: .init(
          registryEntryID: 112, documentLoader: loader,
          registryEntryLoader: { _ in replacingBuiltIn },
          codecs: [
            IPv4Codec(expectedRegistryEntryID: nil), IPv4Codec(expectedRegistryEntryID: nil),
          ]))
    }
    XCTAssertThrowsError(
      try CBORLDProcessingModel(codecs: ["none": .url]).validate())
  }

  // MARK: Caller-provided tables and provisional entries

  func testCallerProvidedTypeTable() async throws {
    let contextURL = "urn:ctx2"
    let loader = fixedLoader([contextURL: ["@context": ["name": "ex:name"]]])
    let entry = CBORLDRegistryEntry(id: 104, requiresCallerProvidedTypeTable: true)
    let table: CBORLDTypeTable = ["context": [.string(contextURL): 0x8000]]
    let document: JSONValue = ["@context": .string(contextURL), "name": "x"]

    await assertCBORLDError(.noTypeTable) {
      _ = try await CBORLD.encode(
        document,
        options: .init(
          registryEntryID: 104, documentLoader: loader, registryEntryLoader: { _ in entry }))
    }
    let bytes = try await CBORLD.encode(
      document,
      options: .init(
        registryEntryID: 104, documentLoader: loader,
        registryEntryLoader: { _ in entry }, callerProvidedTypeTable: table))
    XCTAssertEqual(bytes.hexString, "d9cb1d821868a200198000" + "1864" + "6178")
    let decoded = try await CBORLD.decode(
      bytes,
      options: .init(
        documentLoader: loader, registryEntryLoader: { _ in entry },
        callerProvidedTypeTable: table))
    XCTAssertEqual(decoded, document)
    await assertCBORLDError(.noTypeTable) {
      _ = try await CBORLD.decode(
        bytes, options: .init(documentLoader: loader, registryEntryLoader: { _ in entry }))
    }

    // A caller table cannot redefine a registered type table.
    let registered = CBORLDRegistryEntry(
      id: 104, typeTables: ["context": ["urn:other": 1]], requiresCallerProvidedTypeTable: true)
    await assertCBORLDError(.invalidTypeTable) {
      _ = try await CBORLD.encode(
        document,
        options: .init(
          registryEntryID: 104, documentLoader: loader,
          registryEntryLoader: { _ in registered }, callerProvidedTypeTable: table))
    }
    // Encoding with a table the entry does not use is a configuration error;
    // a decoder configured with one still decodes other entries.
    await assertCBORLDError(.invalidInput) {
      _ = try await CBORLD.encode(
        ["a": 1], options: .init(registryEntryID: 1, callerProvidedTypeTable: table))
    }
    let other = try await CBORLD.encode(["a": 1], options: .init(registryEntryID: 1))
    let otherDecoded = try await CBORLD.decode(
      other, options: .init(callerProvidedTypeTable: table))
    XCTAssertEqual(otherDecoded, ["a": 1])
  }

  func testProvisionalEntriesCanBeRefused() async throws {
    let entry = CBORLDRegistryEntry(id: 105, provisional: true)
    let bytes = try await CBORLD.encode(
      ["a": 1], options: .init(registryEntryID: 105, registryEntryLoader: { _ in entry }))
    let decoded = try await CBORLD.decode(
      bytes, options: .init(registryEntryLoader: { _ in entry }))
    XCTAssertEqual(decoded, ["a": 1])

    await assertCBORLDError(.provisionalRegistryEntry) {
      _ = try await CBORLD.encode(
        ["a": 1],
        options: .init(
          registryEntryID: 105, registryEntryLoader: { _ in entry },
          allowsProvisionalRegistryEntries: false))
    }
    await assertCBORLDError(.provisionalRegistryEntry) {
      _ = try await CBORLD.decode(
        bytes,
        options: .init(
          registryEntryLoader: { _ in entry }, allowsProvisionalRegistryEntries: false))
    }

    let dictionary = CBORLDDocumentDictionary(code: 105, provisional: true)
    let strictDecoder = CBORLDDecoder(
      dictionaries: [dictionary], allowsProvisionalRegistryEntries: false)
    await assertCBORLDError(.provisionalRegistryEntry) {
      _ = try await strictDecoder.decode(bytes)
    }
    await assertCBORLDError(.provisionalRegistryEntry) {
      _ = try await strictDecoder.prepare().decode(bytes)
    }
    let permissive = try await CBORLDDecoder(dictionaries: [dictionary]).decode(bytes)
    XCTAssertEqual(permissive, ["a": 1])
  }

  // MARK: Representation and identity

  func testRegistryEntryCodableAcceptsDraftAndRegistryFileShapes() throws {
    let registryFile = Data(
      """
      {"id": 100, "domain": "Verifiable Credential Barcodes Examples", "mode": "default",
       "provisional": true,
       "compressionTable": [
         {"type": "context", "table": {"32768": "https://www.w3.org/ns/credentials/v2",
                                       "32769": "https://w3id.org/vc-barcodes/v1"}},
         {"type": "https://w3id.org/security#cryptosuiteString",
          "table": {"1": "ecdsa-rdfc-2019", "2": "ecdsa-sd-2023"}}]}
      """.utf8)
    let entry = try JSONDecoder().decode(CBORLDRegistryEntry.self, from: registryFile)
    XCTAssertEqual(entry.id, 100)
    XCTAssertEqual(entry.useCase, "Verifiable Credential Barcodes Examples")
    XCTAssertTrue(entry.provisional)
    XCTAssertNil(entry.processingModel)
    XCTAssertEqual(entry.typeTables["context"]?["https://w3id.org/vc-barcodes/v1"], 32_769)
    XCTAssertEqual(
      entry.typeTables["https://w3id.org/security#cryptosuiteString"]?["ecdsa-sd-2023"], 2)
    XCTAssertNoThrow(try entry.validate())

    let draft = Data(
      """
      {"id": 70000, "useCase": "caller tables",
       "processingModel": {"semanticCompression": false,
                           "codecs": {"http://www.w3.org/2001/XMLSchema#dateTime": "xsd-date-time"}},
       "typeTables": ["callerProvidedTable"]}
      """.utf8)
    let callerEntry = try JSONDecoder().decode(CBORLDRegistryEntry.self, from: draft)
    XCTAssertTrue(callerEntry.requiresCallerProvidedTypeTable)
    XCTAssertEqual(callerEntry.processingModel?.semanticCompression, false)
    XCTAssertEqual(callerEntry.processingModel?.codecs[dateTimeType], .xsdDateTime)

    for original in [entry, callerEntry] {
      let reencoded = try JSONEncoder().encode(original)
      XCTAssertEqual(try JSONDecoder().decode(CBORLDRegistryEntry.self, from: reencoded), original)
    }
    XCTAssertThrowsError(
      try JSONDecoder().decode(
        CBORLDRegistryEntry.self,
        from: Data(#"{"id": 3, "typeTables": [{"type": "url", "table": {"x": "a"}}]}"#.utf8)))
  }

  func testReservedEntriesAreBuiltIn() async throws {
    XCTAssertThrowsError(
      try CBORLDRegistryEntry(id: 1, processingModel: .uncompressed).validate())
    XCTAssertThrowsError(
      try CBORLDRegistryEntry(id: 0, typeTables: ["context": ["urn:x": 1]]).validate())
    XCTAssertThrowsError(
      try CBORLDDocumentDictionary(code: 0, processingModel: .default).validate())

    let calls = CallCounter()
    let loader: CBORLDRegistryEntryLoader = { id in
      calls.increment()
      return CBORLDRegistryEntry(id: id, processingModel: .uncompressed)
    }
    for id: UInt64 in [0, 1] {
      let bytes = try await CBORLD.encode(
        ["a": 1], options: .init(registryEntryID: id, registryEntryLoader: loader))
      let decoded = try await CBORLD.decode(bytes, options: .init(registryEntryLoader: loader))
      XCTAssertEqual(decoded, ["a": 1])
    }
    XCTAssertEqual(calls.value, 0)

    let mismatched: CBORLDRegistryEntryLoader = { _ in CBORLDRegistryEntry(id: 9) }
    await assertCBORLDError(.invalidRegistryEntry) {
      _ = try await CBORLD.encode(
        ["a": 1], options: .init(registryEntryID: 8, registryEntryLoader: mismatched))
    }
    await assertCBORLDError(.invalidInput) {
      _ = try await CBORLD.encode(
        ["a": 1],
        options: .init(
          registryEntryID: 8, typeTableLoader: { _ in [:] }, registryEntryLoader: mismatched))
    }
  }

  func testDictionaryFingerprintBindsOnlyTheEffectiveProcessingModel() throws {
    let base = CBORLDDocumentDictionary(code: 42, contexts: ["urn:a": 32_768])
    let explicitDefault = CBORLDDocumentDictionary(
      code: 42, contexts: ["urn:a": 32_768], processingModel: .default)
    let provisional = CBORLDDocumentDictionary(
      code: 42, contexts: ["urn:a": 32_768], provisional: true)
    let custom = CBORLDDocumentDictionary(
      code: 42, contexts: ["urn:a": 32_768], processingModel: .uncompressed)
    let fingerprint = try base.fingerprint()
    XCTAssertEqual(try explicitDefault.fingerprint(), fingerprint)
    XCTAssertEqual(try provisional.fingerprint(), fingerprint)
    XCTAssertNotEqual(try custom.fingerprint(), fingerprint)
    XCTAssertThrowsError(try custom.verifyFingerprint(fingerprint))

    let persisted = try JSONEncoder().encode(custom)
    XCTAssertEqual(try JSONDecoder().decode(CBORLDDocumentDictionary.self, from: persisted), custom)
    let legacyShape = Data(#"{"code": 42, "contexts": {"urn:a": 32768}}"#.utf8)
    XCTAssertEqual(try JSONDecoder().decode(CBORLDDocumentDictionary.self, from: legacyShape), base)
  }

  // MARK: Errors

  func testErrorsKeepJavaScriptCodesAndReportDraftNames() async throws {
    let cases: [(String, CBORLDErrorCode)] = [
      ("c1f6", .nonCBORLDTag),
      ("a0", .nonCBORLDTag),
      ("d9cb1d8100", .invalidPayloadStructure),
      ("d9cb1d8260a0", .invalidPayloadStructure),
    ]
    for (hex, specificationCode) in cases {
      assertCBORLDErrorSync(.notCBORLD) { _ = try CBORLD.inspect(Data(hexString: hex)) }
      do {
        _ = try CBORLD.inspect(Data(hexString: hex))
      } catch let error as CBORLDError {
        XCTAssertEqual(error.specificationCode, specificationCode, hex)
      }
    }

    do {
      _ = try await CBORLD.decode(Data(hexString: "d9cb1d8201a1186401"))
      XCTFail("Expected an unknown term identifier.")
    } catch let error as CBORLDError {
      XCTAssertEqual(error.code, .unknownCBORLDTermID)
      XCTAssertEqual(error.specificationCode, .unknownCBORLDTermID)
      XCTAssertEqual(error.errorDescription, error.message)
    }

    let limited = CBORLDError(
      code: .resourceLimit, message: "Too deep.",
      diagnostic: .init(byteOffset: 7, majorType: 4, additionalInformation: 1))
    XCTAssertNil(limited.specificationCode)
    XCTAssertEqual(limited.failureReason, "byte offset 7; major type 4, additional information 1")
    XCTAssertEqual(limited.localizedDescription, "Too deep.")

    let custom: CBORLDErrorCode = "ERR_FUTURE_DRAFT_NAME"
    let round = try JSONDecoder().decode(
      CBORLDErrorCode.self, from: try JSONEncoder().encode(custom))
    XCTAssertEqual(round, custom)
    XCTAssertEqual(try JSONEncoder().encode(custom), Data(#""ERR_FUTURE_DRAFT_NAME""#.utf8))
  }

  func testDataItemsRoundTripThroughTheInternalRepresentation() {
    let item = CBORLDDataItem.map([
      .init(key: .text("k"), value: .array([.unsigned(1), .negative(-2), .bool(true), .null])),
      .init(key: .unsigned(3), value: .tagged(24, .bytes(Data([1, 2])))),
      .init(key: .simple(16), value: .float(1.5)),
    ])
    XCTAssertEqual(CBORLDDataItem(item.cborValue), item)
  }
}

// MARK: - Test codecs

private struct IPv4Codec: CBORLDTypedValueCodec {
  static let id: CBORLDCodecIdentifier = "https://example.org/codecs#ipv4"
  let expectedRegistryEntryID: UInt64?
  var identifier: CBORLDCodecIdentifier { Self.id }

  func encode(_ value: JSONValue, context: CBORLDCodecContext) throws -> CBORLDDataItem? {
    try check(context)
    guard case .string(let text) = value else { return nil }
    let parts = text.split(separator: ".", omittingEmptySubsequences: false)
    guard parts.count == 4 else { return nil }
    var bytes: [UInt8] = []
    for part in parts {
      guard let byte = UInt8(part), String(byte) == part else { return nil }
      bytes.append(byte)
    }
    return .bytes(Data(bytes))
  }

  func decode(_ item: CBORLDDataItem, context: CBORLDCodecContext) throws -> JSONValue? {
    try check(context)
    guard case .bytes(let data) = item, data.count == 4 else { return nil }
    return .string(data.map(String.init).joined(separator: "."))
  }

  private func check(_ context: CBORLDCodecContext) throws {
    guard context.type == "https://example.org/vocab#ipv4", context.term == "address",
      expectedRegistryEntryID == nil || context.registryEntryID == expectedRegistryEntryID
    else {
      throw CBORLDError.invalidInput("Unexpected codec context \(context).")
    }
  }
}

/// Decodes to a different value than it encoded.
private struct LossyCodec: CBORLDTypedValueCodec {
  static let id: CBORLDCodecIdentifier = "https://example.org/codecs#lossy"
  var identifier: CBORLDCodecIdentifier { Self.id }

  func encode(_ value: JSONValue, context: CBORLDCodecContext) throws -> CBORLDDataItem? {
    .bytes(Data([1]))
  }

  func decode(_ item: CBORLDDataItem, context: CBORLDCodecContext) throws -> JSONValue? {
    .string("0.0.0.0")
  }
}

/// Emits an integer that a registry dictionary for the same type claims first.
private struct CollidingCodec: CBORLDTypedValueCodec {
  static let id: CBORLDCodecIdentifier = "https://example.org/codecs#colliding"
  var identifier: CBORLDCodecIdentifier { Self.id }

  func encode(_ value: JSONValue, context: CBORLDCodecContext) throws -> CBORLDDataItem? {
    .unsigned(1)
  }

  func decode(_ item: CBORLDDataItem, context: CBORLDCodecContext) throws -> JSONValue? {
    guard case .unsigned(1) = item else { return nil }
    return "192.168.0.1"
  }
}

/// Tries to replace a codec defined by the specification.
private struct BuiltInImpostor: CBORLDTypedValueCodec {
  var identifier: CBORLDCodecIdentifier { .url }

  func encode(_ value: JSONValue, context: CBORLDCodecContext) throws -> CBORLDDataItem? { nil }
  func decode(_ item: CBORLDDataItem, context: CBORLDCodecContext) throws -> JSONValue? { nil }
}

private final class CallCounter: @unchecked Sendable {
  private let lock = NSLock()
  private var count = 0

  func increment() {
    lock.lock()
    count += 1
    lock.unlock()
  }

  var value: Int {
    lock.lock()
    defer { lock.unlock() }
    return count
  }
}
