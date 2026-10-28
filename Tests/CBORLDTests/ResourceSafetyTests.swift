import CBORLDCompute
import Foundation
import XCTest

@testable import CBORLD

/// Encoding limits, context-loading bounds, and untrusted-input presets.
final class ResourceSafetyTests: XCTestCase {
  // MARK: Encoding limits

  func testWriterNeverAllocatesPastItsLimit() throws {
    let writer = CBORByteWriter(capacity: 4, limit: 100)
    for byte in 0..<100 { try writer.append(UInt8(byte)) }
    XCTAssertEqual(writer.count, 100)
    XCTAssertLessThanOrEqual(writer.allocatedCapacity, 100)
    XCTAssertThrowsError(try writer.append(0)) { error in
      XCTAssertEqual((error as? CBORLDError)?.code, .resourceLimit)
    }
    // Overflowing arithmetic is rejected without attempting an allocation.
    let unbounded = CBORByteWriter()
    try unbounded.append(1)
    XCTAssertThrowsError(try unbounded.reserve(.max))
    XCTAssertLessThan(unbounded.allocatedCapacity, 1_024)

    let empty = CBORByteWriter(limit: 0)
    XCTAssertThrowsError(try empty.append(1))
    XCTAssertEqual(empty.finish(), Data())
  }

  func testOutputLimitIsExactAndAppliesToEveryEncodePath() async throws {
    let document: JSONValue = ["text": .string(String(repeating: "x", count: 2_000))]
    let exact = try CBORLD.encodeUncompressed(document).count
    XCTAssertNoThrow(
      try CBORLD.encodeUncompressed(document, limits: .init(maximumOutputBytes: exact)))
    assertCBORLDErrorSync(.resourceLimit) {
      _ = try CBORLD.encodeUncompressed(document, limits: .init(maximumOutputBytes: exact - 1))
    }

    let compressedSize = try await CBORLD.encode(document, options: .init(registryEntryID: 1)).count
    let fits = try await CBORLD.encode(
      document,
      options: .init(registryEntryID: 1, limits: .init(maximumOutputBytes: compressedSize)))
    XCTAssertEqual(fits.count, compressedSize)
    await assertCBORLDError(.resourceLimit) {
      _ = try await CBORLD.encode(
        document,
        options: .init(registryEntryID: 1, limits: .init(maximumOutputBytes: compressedSize - 1)))
    }
    await assertCBORLDError(.resourceLimit) {
      _ = try await CBORLDEncoder(limits: .init(maximumOutputBytes: 64)).encode(document)
    }
    // Called directly rather than through assertCBORLDError: in release
    // builds, Swift 6.0.3 on x86_64 Linux miscompiles that helper's
    // specialization for a closure capturing this prepared encoder and
    // crashes the test process. The direct call works on every toolchain.
    let prepared = try CBORLDPreparedEncoder(limits: .init(maximumOutputBytes: 64))
    do {
      _ = try await prepared.encode(document)
      XCTFail("Expected ERR_RESOURCE_LIMIT from the prepared encoder.")
    } catch let error as CBORLDError {
      XCTAssertEqual(error.code, .resourceLimit, error.message)
    }
    await assertCBORLDError(.resourceLimit) {
      _ = try await CBORLD.encode(
        document, options: .init(registryEntryID: 1, limits: .init(maximumOutputBytes: -1)))
    }
  }

  func testEncodingDepthIsCountedExactlyLikeDecodingDepth() async throws {
    func nested(_ depth: Int) -> JSONValue {
      var value: JSONValue = 1
      for _ in 0..<depth { value = .array([value]) }
      return value
    }
    // Registry zero places the payload at depth 2 inside tag and envelope.
    let limit = 10
    let deepest = nested(limit - 2)
    let bytes = try CBORLD.encodeUncompressed(deepest, limits: .init(maximumNestingDepth: limit))
    XCTAssertEqual(
      try CBORLD.decodeUncompressed(bytes, limits: .init(maximumNestingDepth: limit)), deepest)
    assertCBORLDErrorSync(.resourceLimit) {
      _ = try CBORLD.encodeUncompressed(
        nested(limit - 1), limits: .init(maximumNestingDepth: limit))
    }
    let tooDeep = try CBORLD.encodeUncompressed(nested(limit - 1))
    assertCBORLDErrorSync(.resourceLimit) {
      _ = try CBORLD.decodeUncompressed(tooDeep, limits: .init(maximumNestingDepth: limit))
    }

    // The semantic path applies the same bound to compressed objects.
    var object: JSONValue = ["leaf": 1]
    for _ in 0..<20 { object = ["child": object] }
    await assertCBORLDError(.resourceLimit) {
      _ = try await CBORLD.encode(
        object, options: .init(registryEntryID: 1, limits: .init(maximumNestingDepth: 12)))
    }
    let accepted = try await CBORLD.encode(object, options: .init(registryEntryID: 1))
    let restored = try await CBORLD.decode(accepted)
    XCTAssertEqual(restored, object)
  }

  func testEncodingContainerLimitAndCancellation() async throws {
    let array = JSONValue.array((0..<11).map { .integer(Int64($0)) })
    let object = JSONValue.object(Dictionary(uniqueKeysWithValues: (0..<11).map { ("k\($0)", 1) }))
    for value in [array, object] {
      assertCBORLDErrorSync(.resourceLimit) {
        _ = try CBORLD.encodeUncompressed(value, limits: .init(maximumContainerItems: 10))
      }
      await assertCBORLDError(.resourceLimit) {
        _ = try await CBORLD.encode(
          value, options: .init(registryEntryID: 1, limits: .init(maximumContainerItems: 10)))
      }
    }

    let large = JSONValue.array((0..<5_000).map { .integer(Int64($0)) })
    let task = Task<Data, Error> {
      while !Task.isCancelled { await Task.yield() }
      return try CBORLD.encodeUncompressed(large, limits: .init(cancellationCheckStride: 1))
    }
    task.cancel()
    do {
      _ = try await task.value
      XCTFail("Expected cancellation.")
    } catch is CancellationError {
    }
  }

  func testWholeDocumentOutputBoundIsEnforcedWhileEncoding() async throws {
    let request = CBORLDWholeDocumentTransformRequest.encoding(
      ["text": .string(String(repeating: "y", count: 500))],
      configuration: .init(maximumOutputBytes: 100))
    await assertCBORLDError(.resourceLimit) {
      _ = try await CBORLDCPUComputeProvider().batchedWholeDocumentTransform([request])
    }
  }

  // MARK: Context budgets

  func testContextDocumentCountBytesImportDepthAndTermsAreBounded() async throws {
    let contexts: [String: JSONValue] = [
      "urn:a": ["@context": ["a": "ex:a"]],
      "urn:b": ["@context": ["b": "ex:b"]],
      "urn:c": ["@context": ["c": "ex:c"]],
    ]
    let document: JSONValue = ["@context": ["urn:a", "urn:b", "urn:c"], "a": 1, "b": 2, "c": 3]
    let loader = fixedLoader(contexts)
    let decoded = try await roundTrip(document, loader: loader)
    XCTAssertEqual(decoded, document)
    await assertCBORLDError(.resourceLimit) {
      _ = try await self.roundTrip(
        document, loader: loader, policy: .init(maximumContextDocuments: 2))
    }
    await assertCBORLDError(.resourceLimit) {
      _ = try await self.roundTrip(
        document, loader: loader, policy: .init(maximumTermDefinitions: 2))
    }

    // Loaders see the remaining byte budget and report exact sizes.
    let requests = RequestLog()
    let sized: CBORLDContextDocumentLoader = { request in
      requests.append(request)
      return CBORLDLoadedDocument(
        document: contexts[request.url]!, requestedURL: request.url, byteCount: 1_000)
    }
    _ = try await CBORLD.encode(
      document,
      options: .init(
        registryEntryID: 1, contextPolicy: .init(maximumContextBytes: 3_000),
        contextDocumentLoader: sized))
    XCTAssertEqual(requests.all.map(\.maximumByteCount), [3_000, 2_000, 1_000])
    await assertCBORLDError(.resourceLimit) {
      _ = try await CBORLD.encode(
        document,
        options: .init(
          registryEntryID: 1, contextPolicy: .init(maximumContextBytes: 2_999),
          contextDocumentLoader: sized))
    }

    let chained: [String: JSONValue] = [
      "urn:top": ["@context": ["@import": "urn:middle", "top": "ex:top"]],
      "urn:middle": ["@context": ["@import": "urn:bottom", "middle": "ex:middle"]],
      "urn:bottom": ["@context": ["bottom": "ex:bottom"]],
    ]
    let importing: JSONValue = ["@context": "urn:top", "top": 1, "bottom": 2]
    let chainedDecoded = try await roundTrip(
      importing, loader: fixedLoader(chained), policy: .init(maximumImportDepth: 2))
    XCTAssertEqual(chainedDecoded, importing)
    await assertCBORLDError(.resourceLimit) {
      _ = try await self.roundTrip(
        importing, loader: fixedLoader(chained), policy: .init(maximumImportDepth: 1))
    }
  }

  func testURLRedirectAndMediaTypePolicy() async throws {
    let context: JSONValue = ["@context": ["name": "ex:name"]]
    func load(
      _ url: String,
      policy: CBORLDContextLoadingPolicy,
      canonicalURL: String? = nil,
      mediaType: String? = "application/ld+json",
      redirects: [String] = [],
      reportedURL: String? = nil
    ) async throws {
      let loader: CBORLDContextDocumentLoader = { request in
        CBORLDLoadedDocument(
          document: context,
          requestedURL: reportedURL ?? request.url,
          canonicalURL: canonicalURL,
          mediaType: mediaType,
          redirectChain: redirects)
      }
      _ = try await CBORLD.encode(
        ["@context": .string(url), "name": "x"],
        options: .init(registryEntryID: 1, contextPolicy: policy, contextDocumentLoader: loader))
    }

    let httpsOnly = CBORLDContextLoadingPolicy(allowedURLSchemes: ["HTTPS"])
    try await load("https://example.com/c", policy: httpsOnly)
    await assertCBORLDError(.contextNotAllowed) {
      try await load("http://example.com/c", policy: httpsOnly)
    }
    let hosts = CBORLDContextLoadingPolicy(allowedHosts: ["example.com"])
    try await load("https://EXAMPLE.com/c", policy: hosts)
    await assertCBORLDError(.contextNotAllowed) {
      try await load("urn:no-host", policy: hosts)
    }
    await assertCBORLDError(.contextNotAllowed) {
      try await load(
        "https://example.com/c", policy: hosts,
        redirects: ["https://example.com/c", "https://evil.test/c"])
    }
    await assertCBORLDError(.contextNotAllowed) {
      try await load("https://example.com/c", policy: hosts, canonicalURL: "https://evil.test/c")
    }
    await assertCBORLDError(.resourceLimit) {
      try await load(
        "https://example.com/c", policy: .init(maximumRedirects: 1),
        redirects: ["https://example.com/1", "https://example.com/2"])
    }
    let jsonLD = CBORLDContextLoadingPolicy(allowedMediaTypes: ["application/ld+json"])
    try await load(
      "https://example.com/c", policy: jsonLD, mediaType: "Application/LD+JSON; profile=x")
    await assertCBORLDError(.contextNotAllowed) {
      try await load("https://example.com/c", policy: jsonLD, mediaType: "text/html")
    }
    await assertCBORLDError(.contextNotAllowed) {
      try await load("https://example.com/c", policy: jsonLD, mediaType: nil)
    }
    await assertCBORLDError(.invalidContext) {
      try await load(
        "https://example.com/c", policy: .init(), reportedURL: "https://example.com/other")
    }
  }

  func testStrictPinningRequiresAndVerifiesFingerprints() async throws {
    let url = "https://example.com/pinned"
    let context: JSONValue = ["@context": ["name": "ex:name"]]
    let pin = try CBORLD.contextFingerprint(of: context)
    let document: JSONValue = ["@context": .string(url), "name": "x"]

    await assertCBORLDError(.unpinnedContext) {
      _ = try await CBORLD.encode(
        document,
        options: .init(
          registryEntryID: 1, documentLoader: fixedLoader([url: context]), contextPolicy: .strict))
    }
    let registry = CBORLDContextRegistry(
      documents: [url: context], expectedFingerprints: [url: pin])
    let bytes = try await CBORLD.encode(
      document,
      options: .init(
        registryEntryID: 1, contextPolicy: .strict,
        contextDocumentLoader: registry.contextDocumentLoader))
    let decoded = try await CBORLD.decode(
      bytes,
      options: .init(contextPolicy: .strict, contextDocumentLoader: registry.contextDocumentLoader))
    XCTAssertEqual(decoded, document)

    // A pin reported by an application loader is verified by the processor.
    let tampered: CBORLDContextDocumentLoader = { request in
      CBORLDLoadedDocument(
        document: ["@context": ["name": "ex:changed"]], requestedURL: request.url,
        expectedFingerprint: pin)
    }
    await assertCBORLDError(.integrityMismatch) {
      _ = try await CBORLD.encode(
        document, options: .init(registryEntryID: 1, contextDocumentLoader: tampered))
    }
    // A registered document with a wrong pin fails every time it is used.
    let wrong = CBORLDContextRegistry(
      documents: [url: ["@context": ["name": "ex:other"]]], expectedFingerprints: [url: pin])
    for _ in 0..<2 {
      await assertCBORLDError(.integrityMismatch) { _ = try await wrong.load(url) }
    }
    await assertCBORLDError(.invalidInput) {
      _ = try await CBORLD.encode(
        document,
        options: .init(
          registryEntryID: 1, documentLoader: fixedLoader([url: context]),
          contextDocumentLoader: registry.contextDocumentLoader))
    }
    await assertCBORLDError(.resourceLimit) {
      _ = try await CBORLD.encode(
        document,
        options: .init(
          registryEntryID: 1, contextPolicy: .init(maximumContextDocuments: -1),
          contextDocumentLoader: registry.contextDocumentLoader))
    }
  }

  // MARK: Untrusted input presets

  func testUntrustedPresetsSeparateSafeInputFromDeterministicTransport() async throws {
    // {"a": 1.0} with the float in a non-preferred 64-bit width.
    let widened = Data(hexString: "d9cb1d8200a16161fb3ff0000000000000")
    let compatible = try CBORLD.inspect(widened, configuration: .untrustedCompatible)
    XCTAssertEqual(compatible.registryEntryID, 0)
    let decoded = try await CBORLD.decode(
      widened, options: .init(configuration: .untrustedCompatible))
    XCTAssertEqual(decoded, ["a": 1])
    assertCBORLDErrorSync(.nonPreferredFloat) {
      _ = try CBORLD.inspect(widened, configuration: .untrustedDeterministic)
    }
    await assertCBORLDError(.nonPreferredFloat) {
      _ = try await CBORLDDecoder(configuration: .untrustedDeterministic).decode(widened)
    }
    await assertCBORLDError(.nonPreferredFloat) {
      _ = try await CBORLDPreparedDecoder(configuration: .untrustedDeterministic).decode(widened)
    }

    // Duplicate keys and indefinite lengths are refused by both presets.
    let duplicate = Data(hexString: "d9cb1d8200a2616101616102")
    let indefinite = Data(hexString: "d9cb1d82009f01ff")
    for configuration in [CBORLDDecodingConfiguration.untrustedCompatible, .untrustedDeterministic]
    {
      XCTAssertThrowsError(try CBORLD.inspect(duplicate, configuration: configuration))
      XCTAssertThrowsError(try CBORLD.inspect(indefinite, configuration: configuration))
      XCTAssertTrue(configuration.limits.rejectDuplicateMapKeys)
      XCTAssertFalse(configuration.limits.allowsIndefiniteLengthItems)
    }
    XCTAssertNoThrow(try CBORLD.inspect(indefinite, configuration: .permissive))

    var options = CBORLDDecodingOptions()
    options.configuration = .untrustedDeterministic
    XCTAssertEqual(options.policy, .strict)
    XCTAssertEqual(options.configuration, .untrustedDeterministic)
    XCTAssertEqual(
      CBORLDDecoder(configuration: .untrustedCompatible).configuration, .untrustedCompatible)
    let persisted = try JSONEncoder().encode(CBORLDDecodingConfiguration.untrustedCompatible)
    XCTAssertEqual(
      try JSONDecoder().decode(CBORLDDecodingConfiguration.self, from: persisted),
      .untrustedCompatible)
  }

  // MARK: Helpers

  private func roundTrip(
    _ document: JSONValue,
    loader: @escaping CBORLDDocumentLoader,
    policy: CBORLDContextLoadingPolicy = .init()
  ) async throws -> JSONValue {
    let bytes = try await CBORLD.encode(
      document,
      options: .init(registryEntryID: 1, documentLoader: loader, contextPolicy: policy))
    return try await CBORLD.decode(
      bytes, options: .init(documentLoader: loader, contextPolicy: policy))
  }
}

private final class RequestLog: @unchecked Sendable {
  private let lock = NSLock()
  private var requests: [CBORLDContextRequest] = []

  func append(_ request: CBORLDContextRequest) {
    lock.lock()
    requests.append(request)
    lock.unlock()
  }

  var all: [CBORLDContextRequest] {
    lock.lock()
    defer { lock.unlock() }
    return requests
  }
}
