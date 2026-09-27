import Foundation

/// One context-document request made while a document is encoded or decoded.
///
/// The request carries the operation's remaining budgets so that an
/// application-owned loader can stop reading an oversized response or a long
/// redirect chain early. The processor enforces the same bounds again on the
/// returned ``CBORLDLoadedDocument``.
public struct CBORLDContextRequest: Sendable, Hashable {
  /// The context URL as it appears in the document or an `@import`.
  public let url: String
  /// The remaining aggregate context-byte budget for the operation.
  public let maximumByteCount: Int
  /// The maximum number of redirects the loader may follow.
  public let maximumRedirects: Int
  /// `0` for a context a document references directly; `n` for a context
  /// reached through `n` successive `@import` hops.
  public let importDepth: Int

  public init(url: String, maximumByteCount: Int, maximumRedirects: Int, importDepth: Int) {
    self.url = url
    self.maximumByteCount = maximumByteCount
    self.maximumRedirects = maximumRedirects
    self.importDepth = importDepth
  }
}

/// A loaded context document together with the transport facts the processor
/// needs to enforce its resource and integrity contracts. The package never
/// performs network access itself; the application's loader reports these
/// facts.
public struct CBORLDLoadedDocument: Sendable, Hashable, Codable {
  public var document: JSONValue
  /// The URL that was requested.
  public var requestedURL: String
  /// The URL the document was finally retrieved from, after redirects.
  public var canonicalURL: String
  /// The response media type, such as `application/ld+json`, if known.
  public var mediaType: String?
  /// The response size in bytes. When the loader cannot report it, this is
  /// the document's ``CBORLDStructuralCost/encodedByteCount``.
  public var byteCount: Int
  /// Whether ``byteCount`` was reported by the loader rather than estimated.
  public var byteCountIsMeasured: Bool
  /// Every URL that answered with a redirect, in order.
  public var redirectChain: [String]
  /// A context fingerprint the document must match before it is used.
  public var expectedFingerprint: CBORLDDigest?
  /// Set only by package code that has already verified the pin.
  var verifiedFingerprint: CBORLDDigest?

  public init(
    document: JSONValue,
    requestedURL: String,
    canonicalURL: String? = nil,
    mediaType: String? = nil,
    byteCount: Int? = nil,
    redirectChain: [String] = [],
    expectedFingerprint: CBORLDDigest? = nil
  ) {
    self.document = document
    self.requestedURL = requestedURL
    self.canonicalURL = canonicalURL ?? requestedURL
    self.mediaType = mediaType
    self.byteCount = byteCount ?? document.structuralCost.encodedByteCount
    self.byteCountIsMeasured = byteCount != nil
    self.redirectChain = redirectChain
    self.expectedFingerprint = expectedFingerprint
    self.verifiedFingerprint = nil
  }

  private enum CodingKeys: String, CodingKey {
    case document
    case requestedURL
    case canonicalURL
    case mediaType
    case byteCount
    case byteCountIsMeasured
    case redirectChain
    case expectedFingerprint
  }
}

/// Resolves a context request to a loaded document and its transport facts.
public typealias CBORLDContextDocumentLoader =
  @Sendable (CBORLDContextRequest) async throws -> CBORLDLoadedDocument

/// Per-operation bounds and integrity requirements for context loading.
///
/// Every encode or decode operation counts the distinct context documents it
/// loads, their aggregate bytes, `@import` depth, redirects, and the term
/// definitions they contribute. Limits apply whether the documents come from a
/// registry, a cache, or the network.
public struct CBORLDContextLoadingPolicy: Sendable, Hashable, Codable {
  /// Maximum distinct context documents loaded by URL in one operation.
  public var maximumContextDocuments: Int
  /// Maximum aggregate ``CBORLDLoadedDocument/byteCount`` in one operation.
  public var maximumContextBytes: Int
  /// Maximum chain of `@import` hops.
  public var maximumImportDepth: Int
  /// Maximum redirects a loader may report for one document.
  public var maximumRedirects: Int
  /// Maximum distinct terms the loaded contexts may define, which bounds the
  /// generated term-identifier map.
  public var maximumTermDefinitions: Int
  /// Reject every context loaded by URL that has no expected fingerprint.
  /// Pins come from ``CBORLDContextRegistry/expectedFingerprints`` or a
  /// loader's ``CBORLDLoadedDocument/expectedFingerprint``, so this requires a
  /// metadata-reporting loader such as
  /// ``CBORLDContextRegistry/contextDocumentLoader``.
  public var requiresPinnedContexts: Bool
  /// Permitted URL schemes, compared case-insensitively. `nil` allows any.
  /// Checked for the requested URL, every redirect, and the canonical URL.
  public var allowedURLSchemes: Set<String>?
  /// Permitted hosts, compared case-insensitively. `nil` allows any. A URL
  /// without a host is rejected when this is set.
  public var allowedHosts: Set<String>?
  /// Permitted media types, ignoring parameters. `nil` allows any; when set,
  /// a loader must report an allowed media type.
  public var allowedMediaTypes: Set<String>?

  public init(
    maximumContextDocuments: Int = 128,
    maximumContextBytes: Int = 16 * 1_024 * 1_024,
    maximumImportDepth: Int = 8,
    maximumRedirects: Int = 8,
    maximumTermDefinitions: Int = 100_000,
    requiresPinnedContexts: Bool = false,
    allowedURLSchemes: Set<String>? = nil,
    allowedHosts: Set<String>? = nil,
    allowedMediaTypes: Set<String>? = nil
  ) {
    self.maximumContextDocuments = maximumContextDocuments
    self.maximumContextBytes = maximumContextBytes
    self.maximumImportDepth = maximumImportDepth
    self.maximumRedirects = maximumRedirects
    self.maximumTermDefinitions = maximumTermDefinitions
    self.requiresPinnedContexts = requiresPinnedContexts
    self.allowedURLSchemes = allowedURLSchemes
    self.allowedHosts = allowedHosts
    self.allowedMediaTypes = allowedMediaTypes
  }

  /// Tighter bounds for untrusted input, with every context required to match
  /// a pinned fingerprint. Schemes and hosts remain application choices.
  public static let strict = Self(
    maximumContextDocuments: 32,
    maximumContextBytes: 4 * 1_024 * 1_024,
    maximumImportDepth: 2,
    maximumRedirects: 3,
    maximumTermDefinitions: 20_000,
    requiresPinnedContexts: true)

  func validate() throws {
    guard maximumContextDocuments >= 0, maximumContextBytes >= 0,
      maximumImportDepth >= 0, maximumRedirects >= 0, maximumTermDefinitions >= 0
    else {
      throw CBORLDError.resourceLimit("Context loading limits must not be negative.")
    }
  }

  func requireAllowed(url: String) throws {
    guard allowedURLSchemes != nil || allowedHosts != nil else { return }
    guard let components = URLComponents(string: url),
      let scheme = components.scheme?.lowercased()
    else {
      throw notAllowed("Context URL \"\(url)\" cannot be checked against the URL policy.")
    }
    if let allowedURLSchemes,
      !allowedURLSchemes.contains(where: { $0.lowercased() == scheme })
    {
      throw notAllowed("Context URL scheme \"\(scheme)\" is not allowed for \"\(url)\".")
    }
    if let allowedHosts {
      guard let host = components.host?.lowercased(), !host.isEmpty,
        allowedHosts.contains(where: { $0.lowercased() == host })
      else {
        throw notAllowed("Context URL host is not allowed for \"\(url)\".")
      }
    }
  }

  /// Checks one loaded document against the request that produced it.
  func validate(_ loaded: CBORLDLoadedDocument, for request: CBORLDContextRequest) throws {
    guard loaded.requestedURL == request.url else {
      throw CBORLDError(
        code: .invalidContext,
        message:
          "Context loader returned \"\(loaded.requestedURL)\" for request \"\(request.url)\".")
    }
    guard loaded.redirectChain.count <= maximumRedirects else {
      throw CBORLDError.resourceLimit(
        "Context \"\(request.url)\" followed \(loaded.redirectChain.count) redirects; the limit is \(maximumRedirects)."
      )
    }
    for url in loaded.redirectChain { try requireAllowed(url: url) }
    try requireAllowed(url: loaded.canonicalURL)
    if let allowedMediaTypes {
      let baseType = loaded.mediaType?
        .split(separator: ";", maxSplits: 1).first
        .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
      guard let baseType,
        allowedMediaTypes.contains(where: { $0.lowercased() == baseType })
      else {
        throw notAllowed(
          "Context \"\(request.url)\" has media type \"\(loaded.mediaType ?? "unknown")\", which is not allowed."
        )
      }
    }
    guard loaded.byteCount >= 0, loaded.byteCount <= request.maximumByteCount else {
      throw CBORLDError.resourceLimit(
        "Context \"\(request.url)\" contains \(loaded.byteCount) bytes; \(request.maximumByteCount) bytes remain in the context budget."
      )
    }
    if let expected = loaded.expectedFingerprint {
      if loaded.verifiedFingerprint != expected {
        try CBORLD.verifyContext(loaded.document, against: expected)
      }
    } else if requiresPinnedContexts {
      throw CBORLDError(
        code: .unpinnedContext,
        message: "Context \"\(request.url)\" has no pinned fingerprint.")
    }
  }

  private func notAllowed(_ message: String) -> CBORLDError {
    CBORLDError(code: .contextNotAllowed, message: message)
  }

  private enum CodingKeys: String, CodingKey {
    case maximumContextDocuments
    case maximumContextBytes
    case maximumImportDepth
    case maximumRedirects
    case maximumTermDefinitions
    case requiresPinnedContexts
    case allowedURLSchemes
    case allowedHosts
    case allowedMediaTypes
  }

  public init(from decoder: Decoder) throws {
    let defaults = Self()
    let container = try decoder.container(keyedBy: CodingKeys.self)
    maximumContextDocuments =
      try container.decodeIfPresent(Int.self, forKey: .maximumContextDocuments)
      ?? defaults.maximumContextDocuments
    maximumContextBytes =
      try container.decodeIfPresent(Int.self, forKey: .maximumContextBytes)
      ?? defaults.maximumContextBytes
    maximumImportDepth =
      try container.decodeIfPresent(Int.self, forKey: .maximumImportDepth)
      ?? defaults.maximumImportDepth
    maximumRedirects =
      try container.decodeIfPresent(Int.self, forKey: .maximumRedirects)
      ?? defaults.maximumRedirects
    maximumTermDefinitions =
      try container.decodeIfPresent(Int.self, forKey: .maximumTermDefinitions)
      ?? defaults.maximumTermDefinitions
    requiresPinnedContexts =
      try container.decodeIfPresent(Bool.self, forKey: .requiresPinnedContexts)
      ?? defaults.requiresPinnedContexts
    allowedURLSchemes = try container.decodeIfPresent(Set<String>.self, forKey: .allowedURLSchemes)
    allowedHosts = try container.decodeIfPresent(Set<String>.self, forKey: .allowedHosts)
    allowedMediaTypes = try container.decodeIfPresent(Set<String>.self, forKey: .allowedMediaTypes)
  }
}

/// An application-controlled context cache that can optionally delegate misses.
public struct CBORLDContextRegistry: Sendable {
  public let documents: [String: JSONValue]
  public let expectedFingerprints: [String: CBORLDDigest]
  public let fallback: CBORLDDocumentLoader?
  /// A metadata-reporting loader for URLs that are not registered.
  public let contextFallback: CBORLDContextDocumentLoader?
  /// Registered documents and their pins are immutable, so each pin is
  /// verified once rather than on every load.
  private let registeredVerification = VerificationMemo<String>()

  public init(
    documents: [String: JSONValue] = [:],
    expectedFingerprints: [String: CBORLDDigest] = [:],
    fallback: CBORLDDocumentLoader? = nil
  ) {
    self.init(
      documents: documents,
      expectedFingerprints: expectedFingerprints,
      fallback: fallback,
      contextFallback: nil)
  }

  /// Creates a registry whose misses are resolved by a metadata-reporting
  /// loader, so redirects, media types, and response sizes reach the
  /// processor's ``CBORLDContextLoadingPolicy``.
  public init(
    documents: [String: JSONValue] = [:],
    expectedFingerprints: [String: CBORLDDigest] = [:],
    contextFallback: @escaping CBORLDContextDocumentLoader
  ) {
    self.init(
      documents: documents,
      expectedFingerprints: expectedFingerprints,
      fallback: nil,
      contextFallback: contextFallback)
  }

  init(
    documents: [String: JSONValue],
    expectedFingerprints: [String: CBORLDDigest],
    fallback: CBORLDDocumentLoader?,
    contextFallback: CBORLDContextDocumentLoader?
  ) {
    self.documents = documents
    self.expectedFingerprints = expectedFingerprints
    self.fallback = fallback
    self.contextFallback = contextFallback
  }

  /// Whether a URL can be resolved without a registered document.
  var hasFallback: Bool { fallback != nil || contextFallback != nil }

  public func load(_ url: String) async throws -> JSONValue {
    try await resolve(
      .init(url: url, maximumByteCount: .max, maximumRedirects: .max, importDepth: 0)
    ).document
  }

  /// Resolves a request and verifies the registry's pin, when one exists,
  /// before returning the document. The returned document carries the pin as
  /// ``CBORLDLoadedDocument/expectedFingerprint``.
  public func resolve(_ request: CBORLDContextRequest) async throws -> CBORLDLoadedDocument {
    var loaded: CBORLDLoadedDocument
    if let registered = documents[request.url] {
      loaded = CBORLDLoadedDocument(document: registered, requestedURL: request.url)
      if let expected = expectedFingerprints[request.url] {
        try registeredVerification.require(request.url) {
          try CBORLD.verifyContext(registered, against: expected)
        }
        loaded.expectedFingerprint = expected
        loaded.verifiedFingerprint = expected
        return loaded
      }
    } else if let contextFallback {
      loaded = try await contextFallback(request)
    } else if let fallback {
      loaded = CBORLDLoadedDocument(
        document: try await fallback(request.url),
        requestedURL: request.url)
    } else {
      throw CBORLDError(
        code: .unknownContext,
        message: "No JSON-LD context is registered for \"\(request.url)\".")
    }

    if let expected = expectedFingerprints[request.url] {
      try CBORLD.verifyContext(loaded.document, against: expected)
      loaded.expectedFingerprint = expected
      loaded.verifiedFingerprint = expected
    }
    return loaded
  }

  public var documentLoader: CBORLDDocumentLoader {
    { url in try await self.load(url) }
  }

  /// A metadata-reporting loader that carries this registry's pins.
  public var contextDocumentLoader: CBORLDContextDocumentLoader {
    { request in try await self.resolve(request) }
  }
}

/// Converts the public loader configurations into the one internal shape.
enum ContextResolverFactory {
  static func make(
    documentLoader: CBORLDDocumentLoader?,
    contextDocumentLoader: CBORLDContextDocumentLoader?
  ) throws -> CBORLDContextDocumentLoader? {
    guard documentLoader == nil || contextDocumentLoader == nil else {
      throw CBORLDError.invalidInput(
        "Configure either documentLoader or contextDocumentLoader, not both.")
    }
    if let contextDocumentLoader { return contextDocumentLoader }
    guard let documentLoader else { return nil }
    return { request in
      CBORLDLoadedDocument(
        document: try await documentLoader(request.url), requestedURL: request.url)
    }
  }
}
