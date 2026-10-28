import Foundation

/// Bounds for a ``CBORLDResourceCache``.
public struct CBORLDResourceCacheLimits: Sendable, Hashable, Codable {
  /// Maximum number of cached context documents.
  public var maximumEntries: Int
  /// Maximum aggregate ``CBORLDLoadedDocument/byteCount`` of cached documents.
  /// A single document larger than this is returned but not cached.
  public var maximumBytes: Int
  /// How long a cached document stays fresh. `nil` keeps documents until
  /// they are evicted.
  public var timeToLive: Duration?

  public init(
    maximumEntries: Int = 256,
    maximumBytes: Int = 64 * 1_024 * 1_024,
    timeToLive: Duration? = nil
  ) {
    self.maximumEntries = maximumEntries
    self.maximumBytes = maximumBytes
    self.timeToLive = timeToLive
  }
}

/// Counters describing a ``CBORLDResourceCache``'s behavior so far.
public struct CBORLDResourceCacheStatistics: Sendable, Hashable, Codable {
  public var entryCount: Int
  public var byteCount: Int
  public var hits: Int
  public var misses: Int
  /// Loads performed on behalf of one or more concurrent requests.
  public var loads: Int
  public var evictions: Int
  public var expirations: Int
}

/// Deduplicates completed and in-flight context loads within entry, byte, and
/// freshness bounds. Pins configured on the registry are verified before a
/// document enters the cache, and failed loads are never cached. A request
/// that is cancelled while it waits for a shared load returns immediately; the
/// shared load is cancelled once nobody is waiting for it. Individual term
/// lookups remain local to a codec operation and never cross this actor
/// boundary.
public actor CBORLDResourceCache {
  private struct Entry {
    var document: CBORLDLoadedDocument
    var storedAt: Duration
    var lastUse: UInt64
  }

  private struct Flight {
    var generation: UInt64
    var task: Task<Void, Never>
    var waiters: [UInt64: CheckedContinuation<CBORLDLoadedDocument, Error>]
  }

  private let registry: CBORLDContextRegistry
  public nonisolated let limits: CBORLDResourceCacheLimits
  private let now: @Sendable () -> Duration
  private var entries: [String: Entry] = [:]
  private var totalBytes = 0
  private var useCounter: UInt64 = 0
  private var flights: [String: Flight] = [:]
  private var nextIdentifier: UInt64 = 0
  private var counters = CBORLDResourceCacheStatistics(
    entryCount: 0, byteCount: 0, hits: 0, misses: 0, loads: 0, evictions: 0, expirations: 0)

  public init(
    registry: CBORLDContextRegistry,
    limits: CBORLDResourceCacheLimits = .init()
  ) {
    let clock = ContinuousClock()
    let start = clock.now
    self.init(registry: registry, limits: limits, now: { clock.now - start })
  }

  /// Creates a cache with an injected time source, for deterministic tests.
  init(
    registry: CBORLDContextRegistry,
    limits: CBORLDResourceCacheLimits,
    now: @escaping @Sendable () -> Duration
  ) {
    self.registry = registry
    self.limits = limits
    self.now = now
  }

  public var statistics: CBORLDResourceCacheStatistics {
    var result = counters
    result.entryCount = entries.count
    result.byteCount = totalBytes
    return result
  }

  public func load(_ url: String) async throws -> JSONValue {
    try await resolve(
      .init(url: url, maximumByteCount: .max, maximumRedirects: .max, importDepth: 0)
    ).document
  }

  public func resolve(_ request: CBORLDContextRequest) async throws -> CBORLDLoadedDocument {
    if let cached = freshDocument(for: request.url) {
      counters.hits += 1
      return cached
    }
    counters.misses += 1
    let waiter = identifier()
    return try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { continuation in
        register(waiter, continuation: continuation, for: request)
      }
    } onCancel: {
      Task { await self.cancel(waiter, url: request.url) }
    }
  }

  public func removeAll() {
    for (_, flight) in flights {
      flight.task.cancel()
      for continuation in flight.waiters.values {
        continuation.resume(throwing: CancellationError())
      }
    }
    flights.removeAll(keepingCapacity: false)
    entries.removeAll(keepingCapacity: false)
    totalBytes = 0
  }

  public nonisolated var documentLoader: CBORLDDocumentLoader {
    { url in try await self.load(url) }
  }

  /// A metadata-reporting loader backed by this cache.
  public nonisolated var contextDocumentLoader: CBORLDContextDocumentLoader {
    { request in try await self.resolve(request) }
  }

  // MARK: Waiters and shared loads

  private func register(
    _ waiter: UInt64,
    continuation: CheckedContinuation<CBORLDLoadedDocument, Error>,
    for request: CBORLDContextRequest
  ) {
    if Task.isCancelled {
      continuation.resume(throwing: CancellationError())
      return
    }
    if let cached = freshDocument(for: request.url) {
      continuation.resume(returning: cached)
      return
    }
    if flights[request.url] == nil { startLoad(request) }
    flights[request.url]?.waiters[waiter] = continuation
  }

  private func startLoad(_ request: CBORLDContextRequest) {
    let generation = identifier()
    let registry = self.registry
    counters.loads += 1
    let task = Task {
      let result: Result<CBORLDLoadedDocument, Error>
      do {
        result = .success(try await registry.resolve(request))
      } catch {
        result = .failure(error)
      }
      // The task inherits the actor's isolation, so completion is recorded
      // synchronously once the registry load returns.
      self.finish(url: request.url, generation: generation, result: result)
    }
    flights[request.url] = Flight(generation: generation, task: task, waiters: [:])
  }

  private func finish(
    url: String,
    generation: UInt64,
    result: Result<CBORLDLoadedDocument, Error>
  ) {
    guard let flight = flights[url], flight.generation == generation else { return }
    flights[url] = nil
    if case .success(let document) = result { store(document, for: url) }
    for continuation in flight.waiters.values { continuation.resume(with: result) }
  }

  private func cancel(_ waiter: UInt64, url: String) {
    guard var flight = flights[url],
      let continuation = flight.waiters.removeValue(forKey: waiter)
    else { return }
    continuation.resume(throwing: CancellationError())
    if flight.waiters.isEmpty {
      flight.task.cancel()
      flights[url] = nil
    } else {
      flights[url] = flight
    }
  }

  private func identifier() -> UInt64 {
    nextIdentifier &+= 1
    return nextIdentifier
  }

  // MARK: Storage

  private func freshDocument(for url: String) -> CBORLDLoadedDocument? {
    guard var entry = entries[url] else { return nil }
    if let timeToLive = limits.timeToLive, now() - entry.storedAt >= timeToLive {
      remove(url)
      counters.expirations += 1
      return nil
    }
    useCounter &+= 1
    entry.lastUse = useCounter
    entries[url] = entry
    return entry.document
  }

  private func store(_ document: CBORLDLoadedDocument, for url: String) {
    guard limits.maximumEntries > 0, document.byteCount <= limits.maximumBytes else { return }
    remove(url)
    useCounter &+= 1
    entries[url] = Entry(document: document, storedAt: now(), lastUse: useCounter)
    totalBytes += document.byteCount
    while entries.count > limits.maximumEntries || totalBytes > limits.maximumBytes,
      let leastRecent = entries.min(by: { $0.value.lastUse < $1.value.lastUse })?.key
    {
      remove(leastRecent)
      counters.evictions += 1
    }
  }

  private func remove(_ url: String) {
    guard let entry = entries.removeValue(forKey: url) else { return }
    totalBytes -= entry.document.byteCount
  }
}

/// Immutable, concurrency-safe encoder setup. Dictionary validation and
/// reverse-table construction happen once; each operation receives isolated
/// mutable context state while sharing only the resource cache.
public struct CBORLDPreparedEncoder: Sendable {
  public let format: CBORLDFormat
  public let serializationMode: CBORLDSerializationMode
  public let dictionary: CBORLDDocumentDictionary
  public let provenance: CBORLDResourceProvenance
  public let limits: CBORLDEncodingLimits
  public let contextPolicy: CBORLDContextLoadingPolicy
  private let preparation: SemanticCodecPreparation
  private let resolver: CBORLDContextDocumentLoader?
  private let diagnostic: (@Sendable (String) -> Void)?

  /// Validates the dictionary, its pin, the limits, and the context policy,
  /// and prepares the dictionary's registry entry and codecs once.
  ///
  /// Contexts come from at most one source: `contextRegistry`, which gets a
  /// private ``CBORLDResourceCache``; `resourceCache`, to share one cache
  /// with other prepared sessions; `documentLoader`; or
  /// `contextDocumentLoader`.
  public init(
    format: CBORLDFormat = .cborLD1,
    serializationMode: CBORLDSerializationMode = .compatibility,
    dictionary: CBORLDDocumentDictionary = .unregistered,
    contextRegistry: CBORLDContextRegistry? = nil,
    documentLoader: CBORLDDocumentLoader? = nil,
    requiredDictionaryFingerprint: CBORLDDigest? = nil,
    diagnostic: (@Sendable (String) -> Void)? = nil,
    codecs: [any CBORLDTypedValueCodec] = [],
    limits: CBORLDEncodingLimits = .init(),
    contextPolicy: CBORLDContextLoadingPolicy = .init(),
    contextDocumentLoader: CBORLDContextDocumentLoader? = nil,
    resourceCache: CBORLDResourceCache? = nil
  ) throws {
    try dictionary.validate()
    if let requiredDictionaryFingerprint {
      try dictionary.verifyFingerprint(requiredDictionaryFingerprint)
    }
    try limits.validate()
    try contextPolicy.validate()
    self.format = format
    self.serializationMode = serializationMode
    self.dictionary = dictionary
    self.limits = limits
    self.contextPolicy = contextPolicy
    self.diagnostic = diagnostic
    let entry: ResolvedRegistryEntry
    if format == .legacySingleton {
      guard dictionary.processingModel == nil else {
        throw CBORLDError.invalidInput(
          "legacy-singleton always uses the default processing model.")
      }
      entry = .legacySingleton(applicationContextMap: dictionary.contexts)
    } else {
      entry = try ResolvedRegistryEntry.make(
        entry: dictionary.registryEntry, format: format, forEncoding: true)
    }
    self.preparation = try SemanticCodecPreparation(entry: entry, codecs: codecs)
    self.resolver = try PreparedContextResolution.resolver(
      contextRegistry: contextRegistry,
      documentLoader: documentLoader,
      contextDocumentLoader: contextDocumentLoader,
      resourceCache: resourceCache)
    self.provenance = CBORLDResourceProvenance(
      dictionaryFingerprint: try dictionary.fingerprint(),
      contextFingerprints: contextRegistry?.expectedFingerprints ?? [:])
  }

  public func encode(_ document: JSONValue) async throws -> Data {
    if format == .cborLD1, dictionary.code == 0 {
      let bytes = try CBOREncoder.encodeUncompressedCBORLD1(
        document, mode: serializationMode, limits: limits)
      diagnostic?("CBOR-LD cbor-ld-1.0, prepared uncompressed registry entry 0.")
      return bytes
    }
    let registryEntryID = format == .legacySingleton ? nil : dictionary.code
    let payload = try await CBORLD.payload(
      for: document,
      preparation: preparation,
      resolver: resolver,
      contextPolicy: contextPolicy,
      limits: limits,
      payloadDepth: CBORLD.payloadDepth(format: format, registryEntryID: registryEntryID))
    let envelope = try CBORLD.makeEnvelope(
      payload: payload,
      format: format,
      registryEntryID: registryEntryID,
      compressionMode: format == .legacySingleton ? 1 : nil)
    let bytes = try CBOREncoder.encode(envelope, mode: serializationMode, limits: limits)
    diagnostic?("Encoded prepared \(format.rawValue) CBOR-LD payload.")
    return bytes
  }

  public func encode<T: Encodable & Sendable>(
    _ document: T,
    valueEncoder: CBORLDValueEncoder = .init()
  ) async throws -> Data {
    try await encode(valueEncoder.encode(document))
  }
}

/// Immutable, concurrency-safe decoder setup. Every dictionary and pin is
/// validated once, and configured decode parses each input exactly once.
public struct CBORLDPreparedDecoder: Sendable {
  public let supportedFormats: Set<CBORLDFormat>
  public let limits: CBORLDDecodingLimits
  public let policy: CBORLDDecodingPolicy
  public let provenance: [UInt64: CBORLDResourceProvenance]
  public let allowsProvisionalRegistryEntries: Bool
  public let contextPolicy: CBORLDContextLoadingPolicy
  private let preparations: [UInt64: SemanticCodecPreparation]
  private let legacyPreparation: SemanticCodecPreparation
  private let resolver: CBORLDContextDocumentLoader?
  private let diagnostic: (@Sendable (String) -> Void)?

  public init(
    supportedFormats: Set<CBORLDFormat> = Set(CBORLDFormat.allCases),
    dictionaries: [CBORLDDocumentDictionary] = [.unregistered],
    requiredDictionaryFingerprints: [UInt64: CBORLDDigest] = [:],
    legacyApplicationContextMap: [String: UInt64]? = nil,
    contextRegistry: CBORLDContextRegistry? = nil,
    documentLoader: CBORLDDocumentLoader? = nil,
    limits: CBORLDDecodingLimits = .init(),
    policy: CBORLDDecodingPolicy = .init(),
    diagnostic: (@Sendable (String) -> Void)? = nil,
    codecs: [any CBORLDTypedValueCodec] = [],
    allowsProvisionalRegistryEntries: Bool = true,
    contextPolicy: CBORLDContextLoadingPolicy = .init(),
    contextDocumentLoader: CBORLDContextDocumentLoader? = nil,
    resourceCache: CBORLDResourceCache? = nil
  ) throws {
    var dictionariesByCode: [UInt64: CBORLDDocumentDictionary] = [:]
    for dictionary in dictionaries {
      guard dictionariesByCode[dictionary.code] == nil else {
        throw CBORLDError(
          code: .invalidDictionary,
          message: "Decoder received more than one dictionary with code \(dictionary.code).")
      }
      try dictionary.validate()
      dictionariesByCode[dictionary.code] = dictionary
    }
    for (code, fingerprint) in requiredDictionaryFingerprints {
      guard let dictionary = dictionariesByCode[code] else {
        throw CBORLDError(
          code: .invalidDictionary,
          message: "No dictionary was configured for required registry entry \(code).")
      }
      try dictionary.verifyFingerprint(fingerprint)
    }
    try contextPolicy.validate()

    var prepared: [UInt64: SemanticCodecPreparation] = [:]
    for entry in [CBORLDRegistryEntry.uncompressed, .compressed] {
      prepared[entry.id] = try SemanticCodecPreparation(
        entry: .make(entry: entry, format: .cborLD1, forEncoding: false), codecs: codecs)
    }
    var provenance: [UInt64: CBORLDResourceProvenance] = [:]
    for (code, dictionary) in dictionariesByCode {
      prepared[code] = try SemanticCodecPreparation(
        entry: .make(entry: dictionary.registryEntry, format: .cborLD1, forEncoding: false),
        codecs: codecs)
      provenance[code] = CBORLDResourceProvenance(
        dictionaryFingerprint: try dictionary.fingerprint(),
        contextFingerprints: contextRegistry?.expectedFingerprints ?? [:])
    }
    self.supportedFormats = supportedFormats
    self.limits = limits
    self.policy = policy
    self.preparations = prepared
    self.provenance = provenance
    self.allowsProvisionalRegistryEntries = allowsProvisionalRegistryEntries
    self.contextPolicy = contextPolicy
    self.legacyPreparation = try SemanticCodecPreparation(
      entry: .legacySingleton(applicationContextMap: legacyApplicationContextMap),
      codecs: codecs)
    self.resolver = try PreparedContextResolution.resolver(
      contextRegistry: contextRegistry,
      documentLoader: documentLoader,
      contextDocumentLoader: contextDocumentLoader,
      resourceCache: resourceCache)
    self.diagnostic = diagnostic
  }

  /// Creates a prepared decoder from a complete parser configuration.
  public init(
    configuration: CBORLDDecodingConfiguration,
    supportedFormats: Set<CBORLDFormat> = Set(CBORLDFormat.allCases),
    dictionaries: [CBORLDDocumentDictionary] = [.unregistered],
    requiredDictionaryFingerprints: [UInt64: CBORLDDigest] = [:],
    legacyApplicationContextMap: [String: UInt64]? = nil,
    contextRegistry: CBORLDContextRegistry? = nil,
    documentLoader: CBORLDDocumentLoader? = nil,
    diagnostic: (@Sendable (String) -> Void)? = nil,
    codecs: [any CBORLDTypedValueCodec] = [],
    allowsProvisionalRegistryEntries: Bool = true,
    contextPolicy: CBORLDContextLoadingPolicy = .init(),
    contextDocumentLoader: CBORLDContextDocumentLoader? = nil,
    resourceCache: CBORLDResourceCache? = nil
  ) throws {
    try self.init(
      supportedFormats: supportedFormats,
      dictionaries: dictionaries,
      requiredDictionaryFingerprints: requiredDictionaryFingerprints,
      legacyApplicationContextMap: legacyApplicationContextMap,
      contextRegistry: contextRegistry,
      documentLoader: documentLoader,
      limits: configuration.limits,
      policy: configuration.policy,
      diagnostic: diagnostic,
      codecs: codecs,
      allowsProvisionalRegistryEntries: allowsProvisionalRegistryEntries,
      contextPolicy: contextPolicy,
      contextDocumentLoader: contextDocumentLoader,
      resourceCache: resourceCache)
  }

  /// The parser limits and representation policy as one value.
  public var configuration: CBORLDDecodingConfiguration {
    .init(limits: limits, policy: policy)
  }

  public func decode(_ data: Data) async throws -> JSONValue {
    let parsed = try CBORLD.parse(data, limits: limits, policy: policy)
    return try await decode(parsed)
  }

  public func decode(_ document: CBORLDValidatedDocument) async throws -> JSONValue {
    guard document.validationPolicy == policy else {
      throw CBORLDError(
        code: .policyMismatch,
        message: "Prepared decoder policy differs from the validated document policy.")
    }
    return try await decode(document.parsed)
  }

  public func decode<T: Decodable & Sendable>(
    _ type: T.Type,
    from data: Data,
    valueDecoder: CBORLDValueDecoder = .init()
  ) async throws -> T {
    try valueDecoder.decode(type, from: await decode(data))
  }

  func decode(_ parsed: ParsedCBORLD) async throws -> JSONValue {
    guard supportedFormats.contains(parsed.format) else {
      throw CBORLDError(
        code: .unsupportedFormat,
        message: "Decoder is not configured for \(parsed.format.rawValue).")
    }
    guard parsed.payloadIsCompressed else { return try parsed.payload.toJSON() }
    let preparation: SemanticCodecPreparation
    if parsed.format == .legacySingleton {
      preparation = legacyPreparation
    } else {
      guard let id = parsed.registryEntryID, let configured = preparations[id] else {
        throw CBORLDError(
          code: .noTypeTable,
          message:
            "Type table not found for registryEntryID \"\(parsed.registryEntryID.map(String.init) ?? "nil")\"."
        )
      }
      guard allowsProvisionalRegistryEntries || !configured.provisional else {
        throw CBORLDError(
          code: .provisionalRegistryEntry,
          message: "Registry entry \(id) is provisional and provisional entries are disabled.")
      }
      preparation = configured
    }
    guard preparation.performsConversion else { return try parsed.payload.toJSON() }
    let output = try await SemanticCodec(
      preparation: preparation,
      resolver: resolver,
      contextPolicy: contextPolicy
    ).decompress(parsed.payload)
    diagnostic?("Decoded prepared \(parsed.format.rawValue) CBOR-LD payload.")
    return output
  }
}

/// Chooses the one context source a prepared session uses.
enum PreparedContextResolution {
  static func resolver(
    contextRegistry: CBORLDContextRegistry?,
    documentLoader: CBORLDDocumentLoader?,
    contextDocumentLoader: CBORLDContextDocumentLoader?,
    resourceCache: CBORLDResourceCache?
  ) throws -> CBORLDContextDocumentLoader? {
    let configured = [
      contextRegistry != nil, documentLoader != nil,
      contextDocumentLoader != nil, resourceCache != nil,
    ].filter { $0 }.count
    guard configured <= 1 else {
      throw CBORLDError.invalidInput(
        "Configure one of contextRegistry, documentLoader, contextDocumentLoader, or resourceCache."
      )
    }
    if let resourceCache { return resourceCache.contextDocumentLoader }
    if let contextRegistry {
      return CBORLDResourceCache(registry: contextRegistry).contextDocumentLoader
    }
    return try ContextResolverFactory.make(
      documentLoader: documentLoader,
      contextDocumentLoader: contextDocumentLoader)
  }
}

extension CBORLDEncoder {
  /// Validates and precomputes immutable tables for repeated operations.
  public func prepare(
    contextRegistry: CBORLDContextRegistry? = nil,
    requiredDictionaryFingerprint: CBORLDDigest? = nil
  ) throws -> CBORLDPreparedEncoder {
    try CBORLDPreparedEncoder(
      format: format,
      serializationMode: serializationMode,
      dictionary: dictionary,
      contextRegistry: contextRegistry,
      documentLoader: contextRegistry == nil ? documentLoader : nil,
      requiredDictionaryFingerprint: requiredDictionaryFingerprint,
      diagnostic: diagnostic,
      codecs: codecs,
      limits: limits,
      contextPolicy: contextPolicy,
      contextDocumentLoader: contextRegistry == nil ? contextDocumentLoader : nil)
  }
}

extension CBORLDDecoder {
  /// Validates dictionaries and constructs reverse tables once for repeated or
  /// concurrent operations.
  public func prepare(
    contextRegistry: CBORLDContextRegistry? = nil
  ) throws -> CBORLDPreparedDecoder {
    if let configurationError { throw configurationError }
    return try CBORLDPreparedDecoder(
      supportedFormats: supportedFormats,
      dictionaries: Array(dictionaries.values),
      requiredDictionaryFingerprints: requiredDictionaryFingerprints,
      legacyApplicationContextMap: legacyApplicationContextMap,
      contextRegistry: contextRegistry,
      documentLoader: contextRegistry == nil ? documentLoader : nil,
      limits: limits,
      policy: policy,
      diagnostic: diagnostic,
      codecs: codecs,
      allowsProvisionalRegistryEntries: allowsProvisionalRegistryEntries,
      contextPolicy: contextPolicy,
      contextDocumentLoader: contextRegistry == nil ? contextDocumentLoader : nil)
  }
}
