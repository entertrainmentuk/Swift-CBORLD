import Foundation

// MARK: - Public streaming types

/// Receives encoded bytes incrementally from a streaming encoder.
public protocol CBORLDByteSink {
  mutating func write(_ chunk: Data) async throws
}

/// Collects streamed bytes in memory.
public struct CBORLDDataSink: CBORLDByteSink, Sendable {
  public private(set) var data = Data()
  /// The size of every chunk received, in order.
  public private(set) var chunkSizes: [Int] = []

  public init() {}

  public mutating func write(_ chunk: Data) async throws {
    data.append(chunk)
    chunkSizes.append(chunk.count)
  }
}

/// Writes streamed bytes to a file, replacing any existing contents.
public final class CBORLDFileSink: CBORLDByteSink {
  private let handle: FileHandle
  private var isClosed = false

  public init(url: URL) throws {
    guard FileManager.default.createFile(atPath: url.path(percentEncoded: false), contents: nil)
    else {
      throw CBORLDError.invalidInput("Cannot create a file at \(url.absoluteString).")
    }
    handle = try FileHandle(forWritingTo: url)
  }

  public func write(_ chunk: Data) async throws {
    try handle.write(contentsOf: chunk)
  }

  /// Flushes and closes the file. The sink cannot be written afterwards.
  public func close() throws {
    guard !isClosed else { return }
    isClosed = true
    try handle.close()
  }

  deinit {
    if !isClosed { try? handle.close() }
  }
}

/// Reads a file as a sequence of chunks without loading it into memory.
public struct CBORLDFileChunks: AsyncSequence, Sendable {
  public typealias Element = Data

  public let url: URL
  public let chunkSize: Int

  public init(url: URL, chunkSize: Int = 65_536) {
    self.url = url
    self.chunkSize = chunkSize
  }

  public func makeAsyncIterator() -> AsyncIterator {
    AsyncIterator(url: url, chunkSize: chunkSize)
  }

  public final class AsyncIterator: AsyncIteratorProtocol {
    private let url: URL
    private let chunkSize: Int
    private var handle: FileHandle?
    private var isFinished = false

    init(url: URL, chunkSize: Int) {
      self.url = url
      self.chunkSize = chunkSize
    }

    public func next() async throws -> Data? {
      guard !isFinished else { return nil }
      guard chunkSize > 0 else {
        throw CBORLDError.invalidInput("File chunkSize must be greater than zero.")
      }
      if handle == nil { handle = try FileHandle(forReadingFrom: url) }
      guard let chunk = try handle?.read(upToCount: chunkSize), !chunk.isEmpty else {
        isFinished = true
        try handle?.close()
        handle = nil
        return nil
      }
      return chunk
    }

    deinit {
      try? handle?.close()
    }
  }
}

/// The outcome of a streaming encode.
public struct CBORLDStreamingResult: Sendable, Hashable, Codable {
  public let byteCount: Int
  public let chunkCount: Int
  /// The transport digest of every emitted byte, computed while streaming.
  public let transportDigest: CBORLDDigest
}

/// Envelope and transport facts established by a complete streaming parse.
public struct CBORLDStreamValidation: Sendable, Hashable, Codable {
  public let format: CBORLDFormat
  public let registryEntryID: UInt64?
  /// Has the meaning of ``CBORLDInspection/payloadIsCompressed``.
  public let payloadIsCompressed: Bool
  public let byteCount: Int
  public let transportDigest: CBORLDDigest
  /// Complete data items, counting a tag and its content separately.
  public let itemCount: Int
  /// Deepest data item; the root has depth `0`.
  public let maximumDepth: Int
}

/// A registry-entry-zero document decoded from streamed input.
public struct CBORLDStreamedDocument: Sendable {
  public let document: JSONValue
  public let validation: CBORLDStreamValidation
}

/// One structural event of a registry-entry-zero payload, in document order.
public enum CBORLDJSONEvent: Sendable, Hashable {
  /// `count` is `nil` for an indefinite-length array.
  case beginArray(count: Int?)
  case endArray
  /// `count` is `nil` for an indefinite-length map.
  case beginObject(count: Int?)
  case endObject
  case key(String)
  case string(String)
  case integer(Int64)
  case number(Double)
  case bool(Bool)
  case null
}

// MARK: - Public streaming operations

extension CBORLD {
  /// Encodes a registry-entry-zero document straight into `sink`.
  ///
  /// The bytes equal ``encodeUncompressed(_:serializationMode:limits:)``, but no
  /// complete output buffer exists: the encoder walks the document with an
  /// explicit stack and hands the sink chunks of at most `max(chunkSize, 9)`
  /// bytes, sending strings longer than a chunk as chunk-sized slices. The
  /// transport digest is computed as bytes are emitted, and
  /// ``CBORLDEncodingLimits`` apply to the whole stream.
  public static func encodeUncompressed<Sink: CBORLDByteSink>(
    _ document: JSONValue,
    to sink: inout Sink,
    serializationMode: CBORLDSerializationMode = .compatibility,
    limits: CBORLDEncodingLimits = .init(),
    chunkSize: Int = 65_536,
    digestAlgorithm: CBORLDHashAlgorithm = .sha256
  ) async throws -> CBORLDStreamingResult {
    try limits.validate()
    guard chunkSize > 0 else {
      throw CBORLDError.invalidInput("Streaming chunkSize must be greater than zero.")
    }
    var emitter = StreamingJSONEmitter(
      mode: serializationMode, limits: limits, chunkSize: chunkSize, algorithm: digestAlgorithm)
    try emitter.begin(document)
    while let action = try emitter.step() {
      switch action {
      case .flush:
        try await sink.write(emitter.drain())
      case .writeDirect(let bytes):
        try await sink.write(bytes)
      }
    }
    if let last = emitter.finish() { try await sink.write(last) }
    return emitter.result
  }

  /// Validates a complete CBOR-LD envelope from asynchronous chunks while
  /// computing its transport digest.
  ///
  /// This applies the same limits and representation policy as
  /// ``inspect(_:limits:policy:)`` without retaining the document: memory
  /// grows with nesting depth, the longest string, and, when duplicate keys
  /// or a deterministic profile are checked, the keys of open maps. Because
  /// the total size is unknown in advance, an oversized input fails when the
  /// limit is crossed rather than before parsing starts.
  public static func validateStream<Chunks: AsyncSequence>(
    _ chunks: Chunks,
    limits: CBORLDDecodingLimits = .init(),
    policy: CBORLDDecodingPolicy = .init(),
    digestAlgorithm: CBORLDHashAlgorithm = .sha256
  ) async throws -> CBORLDStreamValidation where Chunks.Element == Data {
    var reader = try IncrementalCBORReader(limits: limits, policy: policy)
    var envelope = ShallowEnvelopeBuilder()
    var hasher = CBORLDSHA2Hasher(algorithm: digestAlgorithm)
    for try await chunk in chunks {
      hasher.update(data: chunk)
      try reader.consume(chunk) { event, _, depth in envelope.handle(event, depth: depth) }
    }
    try reader.finish()
    let parsed = try envelope.parsed()
    return validation(of: parsed, reader: reader, digest: hasher, algorithm: digestAlgorithm)
  }

  /// Decodes a registry-entry-zero document from asynchronous chunks without
  /// holding the encoded input. Errors match the whole-buffer parser: CBOR
  /// errors first, then envelope errors, then JSON conversion errors.
  public static func decodeUncompressedStream<Chunks: AsyncSequence>(
    _ chunks: Chunks,
    limits: CBORLDDecodingLimits = .init(),
    policy: CBORLDDecodingPolicy = .init(),
    digestAlgorithm: CBORLDHashAlgorithm = .sha256
  ) async throws -> CBORLDStreamedDocument where Chunks.Element == Data {
    var reader = try IncrementalCBORReader(limits: limits, policy: policy)
    var envelope = ShallowEnvelopeBuilder()
    var payload = RegistryZeroPayloadTracker()
    var tree = JSONTreeBuilder()
    var hasher = CBORLDSHA2Hasher(algorithm: digestAlgorithm)
    for try await chunk in chunks {
      hasher.update(data: chunk)
      try reader.consume(chunk) { event, _, depth in
        envelope.handle(event, depth: depth)
        if payload.observe(event, depth: depth) { tree.handle(event) }
      }
    }
    try reader.finish()
    let parsed = try envelope.parsed()
    try requireRegistryZero(parsed)
    let document = try tree.document()
    return CBORLDStreamedDocument(
      document: document,
      validation: validation(of: parsed, reader: reader, digest: hasher, algorithm: digestAlgorithm)
    )
  }

  /// Delivers a registry-entry-zero payload as JSON events in document order
  /// without building a tree, so memory stays proportional to nesting depth
  /// and the keys of open objects. Events are delivered as soon as they are
  /// parsed; if the input turns out to be invalid, the call throws after the
  /// events that preceded the failure, and those events should be discarded.
  public static func decodeUncompressedEvents<Chunks: AsyncSequence>(
    _ chunks: Chunks,
    limits: CBORLDDecodingLimits = .init(),
    policy: CBORLDDecodingPolicy = .init(),
    digestAlgorithm: CBORLDHashAlgorithm = .sha256,
    handler: (CBORLDJSONEvent) throws -> Void
  ) async throws -> CBORLDStreamValidation where Chunks.Element == Data {
    var reader = try IncrementalCBORReader(limits: limits, policy: policy)
    var envelope = ShallowEnvelopeBuilder()
    var payload = RegistryZeroPayloadTracker()
    var converter = JSONEventConverter()
    var hasher = CBORLDSHA2Hasher(algorithm: digestAlgorithm)
    for try await chunk in chunks {
      hasher.update(data: chunk)
      try reader.consume(chunk) { event, _, depth in
        envelope.handle(event, depth: depth)
        if payload.observe(event, depth: depth) {
          try handler(try converter.convert(event))
        } else if payload.isNotRegistryZero {
          throw CBORLDError.invalidInput(
            "Uncompressed streaming decoding requires CBOR-LD 1.0 registry entry zero.")
        }
      }
    }
    try reader.finish()
    let parsed = try envelope.parsed()
    try requireRegistryZero(parsed)
    return validation(of: parsed, reader: reader, digest: hasher, algorithm: digestAlgorithm)
  }

  private static func requireRegistryZero(_ parsed: ParsedCBORLD) throws {
    guard parsed.format == .cborLD1, parsed.registryEntryID == 0 else {
      throw CBORLDError.invalidInput(
        "Uncompressed streaming decoding requires CBOR-LD 1.0 registry entry zero.")
    }
  }

  private static func validation(
    of parsed: ParsedCBORLD,
    reader: IncrementalCBORReader,
    digest: CBORLDSHA2Hasher,
    algorithm: CBORLDHashAlgorithm
  ) -> CBORLDStreamValidation {
    CBORLDStreamValidation(
      format: parsed.format,
      registryEntryID: parsed.registryEntryID,
      payloadIsCompressed: parsed.payloadIsCompressed,
      byteCount: reader.byteCount,
      transportDigest: CBORLDDigest(
        uncheckedAlgorithm: algorithm,
        domain: .encodedBytes,
        version: 1,
        bytes: digest.finalize()),
      itemCount: reader.itemCount,
      maximumDepth: reader.maximumDepth)
  }
}

// MARK: - Streaming encoder

/// Walks a JSON tree with an explicit stack so that a suspension point can
/// follow any value, which lets the caller flush to an asynchronous sink.
///
/// Before an item is written, the emitter flushes when the item would not
/// fit in the current chunk, so buffered chunks never exceed
/// `max(chunkSize, 9)` bytes. Strings longer than a chunk are written as a
/// head followed by chunk-sized slices sent directly to the sink.
struct StreamingJSONEmitter {
  enum Action {
    /// Write ``drain()`` to the sink.
    case flush
    /// Write these bytes, a slice of a long string, directly to the sink.
    case writeDirect(Data)
  }

  private enum Frame {
    case array(values: [JSONValue], next: Int, depth: Int)
    case object(
      keys: [String], values: [String: JSONValue], next: Int, depth: Int, keyWritten: Bool)
    /// The body of a long string, streamed in chunk-sized slices.
    case string(bytes: String.UTF8View, next: String.UTF8View.Index)
  }

  private let mode: CBORLDSerializationMode
  private let limits: CBORLDEncodingLimits
  private let chunkSize: Int
  private let algorithm: CBORLDHashAlgorithm
  private let writer: CBORByteWriter
  private var hasher: CBORLDSHA2Hasher
  private var frames: [Frame] = []
  private var chunkCount = 0

  init(
    mode: CBORLDSerializationMode,
    limits: CBORLDEncodingLimits,
    chunkSize: Int,
    algorithm: CBORLDHashAlgorithm
  ) {
    self.mode = mode
    self.limits = limits
    self.chunkSize = chunkSize
    self.algorithm = algorithm
    self.writer = CBORByteWriter(
      capacity: Swift.min(Swift.max(chunkSize, 9), 1 << 20), limit: limits.maximumOutputBytes)
    self.hasher = CBORLDSHA2Hasher(algorithm: algorithm)
  }

  mutating func begin(_ document: JSONValue) throws {
    for byte in CBOREncoder.uncompressedCBORLD1Prefix { try writer.append(byte) }
    // The payload is the envelope array's second element; treating it as a
    // pending element gives the root the same flush check as any other item.
    frames.append(.array(values: [document], next: 0, depth: 1))
  }

  /// Advances until the next suspension point, returning `nil` when done.
  mutating func step() throws -> Action? {
    while let index = frames.indices.last {
      switch frames[index] {
      case .array(let values, let next, let depth):
        guard next < values.count else {
          frames.removeLast()
          continue
        }
        if needsFlush(before: immediateSize(values[next])) { return .flush }
        try CBOREncoder.checkCancellation(at: next, limits: limits)
        frames[index] = .array(values: values, next: next + 1, depth: depth)
        try beginValue(values[next], depth: depth + 1)
      case .object(let keys, let values, let next, let depth, let keyWritten):
        guard next < keys.count else {
          frames.removeLast()
          continue
        }
        let key = keys[next]
        guard let value = values[key] else {
          throw CBORLDError.invalidInput("JSON object changed while it was being encoded.")
        }
        if !keyWritten {
          if needsFlush(before: immediateSize(.string(key))) { return .flush }
          try CBOREncoder.checkCancellation(at: next, limits: limits)
          frames[index] = .object(
            keys: keys, values: values, next: next, depth: depth, keyWritten: true)
          try beginString(key)
        } else {
          if needsFlush(before: immediateSize(value)) { return .flush }
          frames[index] = .object(
            keys: keys, values: values, next: next + 1, depth: depth, keyWritten: false)
          try beginValue(value, depth: depth + 1)
        }
      case .string(let bytes, let next):
        if writer.count > 0 { return .flush }
        guard next < bytes.endIndex else {
          frames.removeLast()
          continue
        }
        let end =
          bytes.index(next, offsetBy: chunkSize, limitedBy: bytes.endIndex) ?? bytes.endIndex
        frames[index] = .string(bytes: bytes, next: end)
        let slice = Data(bytes[next..<end])
        try writer.reserveExternal(slice.count)
        hasher.update(data: slice)
        chunkCount += 1
        return .writeDirect(slice)
      }
    }
    return nil
  }

  mutating func drain() -> Data {
    let chunk = writer.drain()
    hasher.update(data: chunk)
    chunkCount += 1
    return chunk
  }

  mutating func finish() -> Data? {
    writer.count > 0 ? drain() : nil
  }

  var result: CBORLDStreamingResult {
    CBORLDStreamingResult(
      byteCount: writer.drainedCount + writer.count,
      chunkCount: chunkCount,
      transportDigest: CBORLDDigest(
        uncheckedAlgorithm: algorithm,
        domain: .encodedBytes,
        version: 1,
        bytes: hasher.finalize()))
  }

  private func needsFlush(before size: Int) -> Bool {
    writer.count > 0 && writer.count + size > chunkSize
  }

  /// Bytes an item writes into the buffer before any nested item: a short
  /// string's head and body, or at most nine bytes for anything else.
  private func immediateSize(_ value: JSONValue) -> Int {
    guard case .string(let string) = value else { return 9 }
    let encoded = CBOREncoder.encodedStringByteCount(string)
    return encoded > chunkSize ? 9 : encoded
  }

  private mutating func beginValue(_ value: JSONValue, depth: Int) throws {
    guard depth <= limits.maximumNestingDepth else { throw CBOREncoder.nestingLimit(limits) }
    switch value {
    case .array(let values):
      try CBOREncoder.checkContainer(values.count, limits: limits)
      try CBOREncoder.appendHeader(major: 4, argument: UInt64(values.count), to: writer)
      if !values.isEmpty { frames.append(.array(values: values, next: 0, depth: depth)) }
    case .object(let object):
      try CBOREncoder.checkContainer(object.count, limits: limits)
      try CBOREncoder.appendHeader(major: 5, argument: UInt64(object.count), to: writer)
      if !object.isEmpty {
        frames.append(
          .object(
            keys: CBOREncoder.sortedKeys(object, mode: mode), values: object, next: 0,
            depth: depth, keyWritten: false))
      }
    case .string(let string):
      try beginString(string)
    default:
      try CBOREncoder.appendJSON(value, depth: depth, mode: mode, limits: limits, to: writer)
    }
  }

  private mutating func beginString(_ string: String) throws {
    let byteCount = string.utf8.count
    guard CBOREncoder.encodedStringByteCount(string) > chunkSize else {
      try CBOREncoder.appendString(string, to: writer)
      return
    }
    try CBOREncoder.appendHeader(major: 3, argument: UInt64(byteCount), to: writer)
    frames.append(.string(bytes: string.utf8, next: string.utf8.startIndex))
  }
}

// MARK: - Incremental reader

/// A resumable CBOR parser for chunked input. It applies the same limits and
/// representation policy as the whole-buffer decoder and reports structure
/// as events. A departure from a required deterministic profile, which the
/// whole-buffer decoder only detects after parsing, is reported by
/// ``finish()`` so that both paths report errors in the same order.
struct IncrementalCBORReader {
  enum Event {
    case scalar(CBORValue)
    case startArray(Int?)
    case startMap(Int?)
    case startTag(UInt64)
    /// Closes the innermost array, map, or tag.
    case end
  }

  typealias Handler = (_ event: Event, _ offset: Int, _ depth: Int) throws -> Void

  private enum ArgumentKind {
    case integer
    case length
  }

  private struct Frame {
    enum Kind {
      case array
      case map
      case tag
      case bytes
      case text
    }

    let kind: Kind
    /// Items still expected; `nil` for indefinite containers and strings.
    var remaining: Int?
    /// Elements of an array, or complete pairs of a map.
    var entries = 0
    var expectingKey = true
    let depth: Int
    let offset: Int
    var chunks: [UInt8] = []
    var keyOffsets: [Data: Int] = [:]
    var pendingKey: (identity: Data, offset: Int)?
    var previousKeyBytes: Data?
  }

  private struct KeyCapture {
    let frameIndex: Int
    let offset: Int
    var builder = CBORValueBuilder()
  }

  let limits: CBORLDDecodingLimits
  let policy: CBORLDDecodingPolicy
  private let capturesKeys: Bool
  private var buffer: [UInt8] = []
  private var cursor = 0
  private var bufferOffset = 0
  private(set) var byteCount = 0
  private var frames: [Frame] = []
  private var captures: [KeyCapture] = []
  private(set) var isComplete = false
  private(set) var itemCount = 0
  private(set) var maximumDepth = 0
  private var deferredViolation: CBORLDError?

  init(limits: CBORLDDecodingLimits, policy: CBORLDDecodingPolicy) throws {
    guard limits.maximumInputBytes >= 0,
      limits.maximumNestingDepth >= 0,
      limits.maximumContainerItems >= 0,
      limits.maximumDiagnosticNodes >= 0,
      limits.cancellationCheckStride > 0
    else {
      throw CBORLDError.resourceLimit("CBOR-LD decoding limits must not be negative.")
    }
    self.limits = limits
    self.policy = policy
    self.capturesKeys = limits.rejectDuplicateMapKeys || policy.requiredSerializationMode != nil
  }

  mutating func consume(_ chunk: Data, _ handler: Handler) throws {
    guard !chunk.isEmpty else { return }
    let (total, overflow) = byteCount.addingReportingOverflow(chunk.count)
    guard !overflow, total <= limits.maximumInputBytes else {
      throw CBORLDError(
        code: .resourceLimit,
        message:
          "CBOR-LD input contains more than \(limits.maximumInputBytes) bytes; the configured limit is \(limits.maximumInputBytes).",
        diagnostic: .init(byteOffset: byteCount))
    }
    // Compact consumed bytes only when they dominate the buffer, so a long
    // string that arrives in many chunks is not copied repeatedly.
    if cursor > 4_096, cursor * 2 >= buffer.count {
      buffer.removeSubrange(0..<cursor)
      bufferOffset += cursor
      cursor = 0
    }
    buffer.append(contentsOf: chunk)
    byteCount = total
    try parse(handler)
  }

  mutating func finish() throws {
    guard isComplete else {
      let unterminated = frames.contains { $0.remaining == nil && $0.kind != .tag }
      throw malformed(
        unterminated ? "Unterminated indefinite value." : "Unexpected end of CBOR data.",
        at: byteCount)
    }
    if let deferredViolation { throw deferredViolation }
  }

  // MARK: Parsing

  private mutating func parse(_ handler: Handler) throws {
    while cursor < buffer.count {
      guard !isComplete else {
        throw malformed("Unexpected trailing bytes after the CBOR value.", at: offset(cursor))
      }
      if let top = frames.last, top.remaining == nil, top.kind != .tag, buffer[cursor] == 0xff {
        if top.kind == .map, !top.expectingKey {
          throw malformed("Unsupported CBOR simple value 31.", at: offset(cursor))
        }
        cursor += 1
        try closeIndefinite(handler)
        continue
      }
      guard try readItem(handler) else { return }
    }
  }

  /// Reads one item head, and a definite string's payload. Returns `false`
  /// when more input is needed; nothing is consumed in that case.
  private mutating func readItem(_ handler: Handler) throws -> Bool {
    let start = cursor
    let itemOffset = offset(start)
    let initial = buffer[start]
    let major = initial >> 5
    let info = initial & 0x1f
    let inString = frames.last.map { $0.kind == .bytes || $0.kind == .text } ?? false
    let depth = frames.last.map { inString ? $0.depth : $0.depth + 1 } ?? 0

    if !inString {
      guard depth <= limits.maximumNestingDepth else {
        throw resourceLimit(
          "CBOR nesting exceeds the configured depth of \(limits.maximumNestingDepth).",
          at: itemOffset)
      }
      if let top = frames.last, top.remaining == nil, top.kind == .array || top.expectingKey {
        guard top.entries < limits.maximumContainerItems else {
          throw resourceLimit(
            "CBOR container contains more than \(limits.maximumContainerItems) items.",
            at: itemOffset)
        }
      }
      if itemCount.isMultiple(of: limits.cancellationCheckStride), Task<Never, Never>.isCancelled {
        throw CancellationError()
      }
    }

    let argumentLength: Int
    switch info {
    case 0...23, 31: argumentLength = 0
    case 24: argumentLength = 1
    case 25: argumentLength = 2
    case 26: argumentLength = 4
    case 27: argumentLength = 8
    default:
      if major == 7, !inString {
        throw malformed("Unsupported CBOR simple value \(info).", at: itemOffset)
      }
      throw malformed("Invalid CBOR additional information \(info).", at: itemOffset)
    }
    guard buffer.count - start > argumentLength else { return false }
    var argument = UInt64(info)
    if argumentLength > 0 {
      argument = 0
      for index in 1...argumentLength { argument = argument << 8 | UInt64(buffer[start + index]) }
    }
    let payloadStart = start + 1 + argumentLength

    if inString {
      return try readStringChunk(
        major: major, info: info, argument: argument, offset: itemOffset,
        payloadStart: payloadStart)
    }

    switch major {
    case 0:
      if info == 31 { throw malformed("Invalid CBOR additional information 31.", at: itemOffset) }
      try checkWidth(argument, info: info, kind: .integer, offset: itemOffset)
      cursor = payloadStart
      try emitScalar(.unsigned(argument), offset: itemOffset, depth: depth, handler)
    case 1:
      if info == 31 { throw malformed("Invalid CBOR additional information 31.", at: itemOffset) }
      try checkWidth(argument, info: info, kind: .integer, offset: itemOffset)
      guard argument <= UInt64(Int64.max) else {
        throw malformed("Negative integer is outside the supported Int64 range.", at: itemOffset)
      }
      cursor = payloadStart
      try emitScalar(.negative(-1 - Int64(argument)), offset: itemOffset, depth: depth, handler)
    case 2, 3:
      if info == 31 {
        try requireIndefiniteLengths(at: itemOffset)
        noteRequiredModeViolation(at: itemOffset)
        cursor = payloadStart
        startKeyCaptureIfNeeded(offset: itemOffset)
        frames.append(
          Frame(kind: major == 2 ? .bytes : .text, remaining: nil, depth: depth, offset: itemOffset)
        )
        return true
      }
      try checkWidth(argument, info: info, kind: .length, offset: itemOffset)
      let length = try count(argument, at: itemOffset)
      guard buffer.count - payloadStart >= length else { return false }
      let value: CBORValue
      if major == 2 {
        value = .bytes(Data(buffer[payloadStart..<(payloadStart + length)]))
      } else {
        guard let string = Self.utf8String(buffer[payloadStart..<(payloadStart + length)]) else {
          throw malformed("CBOR text string is not valid UTF-8.", at: itemOffset)
        }
        value = .string(string)
      }
      cursor = payloadStart + length
      try emitScalar(value, offset: itemOffset, depth: depth, handler)
    case 4, 5:
      let kind: Frame.Kind = major == 4 ? .array : .map
      let count: Int?
      if info == 31 {
        try requireIndefiniteLengths(at: itemOffset)
        noteRequiredModeViolation(at: itemOffset)
        count = nil
      } else {
        try checkWidth(argument, info: info, kind: .length, offset: itemOffset)
        let definite = try self.count(argument, at: itemOffset)
        guard definite <= limits.maximumContainerItems else {
          throw resourceLimit(
            "CBOR container contains more than \(limits.maximumContainerItems) items.",
            at: itemOffset)
        }
        count = definite
      }
      cursor = payloadStart
      try startContainer(kind, count: count, offset: itemOffset, depth: depth, handler)
    case 6:
      if info == 31 { throw malformed("Invalid CBOR additional information 31.", at: itemOffset) }
      try checkWidth(argument, info: info, kind: .integer, offset: itemOffset)
      cursor = payloadStart
      startKeyCaptureIfNeeded(offset: itemOffset)
      maximumDepth = Swift.max(maximumDepth, depth)
      try dispatch(.startTag(argument), offset: itemOffset, depth: depth, handler)
      frames.append(Frame(kind: .tag, remaining: 1, depth: depth, offset: itemOffset))
      try requireChildDepth(depth, at: itemOffset)
    default:
      cursor = payloadStart
      try readSimple(info: info, argument: argument, offset: itemOffset, depth: depth, handler)
    }
    return true
  }

  private mutating func readStringChunk(
    major: UInt8,
    info: UInt8,
    argument: UInt64,
    offset: Int,
    payloadStart: Int
  ) throws -> Bool {
    let index = frames.count - 1
    let expected: UInt8 = frames[index].kind == .bytes ? 2 : 3
    guard major == expected, info != 31 else {
      throw malformed(
        "Invalid chunk in indefinite-length \(expected == 2 ? "byte" : "text") string.",
        at: offset)
    }
    try checkWidth(argument, info: info, kind: .length, offset: offset)
    let length = try count(argument, at: offset)
    guard buffer.count - payloadStart >= length else { return false }
    let bytes = buffer[payloadStart..<(payloadStart + length)]
    if expected == 3, Self.utf8String(bytes) == nil {
      throw malformed("CBOR text string is not valid UTF-8.", at: offset)
    }
    frames[index].chunks.append(contentsOf: bytes)
    cursor = payloadStart + length
    return true
  }

  private mutating func readSimple(
    info: UInt8,
    argument: UInt64,
    offset: Int,
    depth: Int,
    _ handler: Handler
  ) throws {
    let value: CBORValue
    switch info {
    case 20: value = .bool(false)
    case 21: value = .bool(true)
    case 22: value = .null
    case 0...19, 23:
      try requireReservedSimpleValues(info, offset: offset)
      value = .simple(info)
    case 24:
      let simple = UInt8(argument)
      try requireReservedSimpleValues(simple, offset: offset)
      if simple < 24 { noteRequiredModeViolation(at: offset) }
      value = .simple(simple)
    case 25:
      value = .double(Double(Float16(bitPattern: UInt16(argument))))
      try checkFloat(info: info, bits: argument, offset: offset)
    case 26:
      value = .double(Double(Float(bitPattern: UInt32(argument))))
      try checkFloat(info: info, bits: argument, offset: offset)
    case 27:
      value = .double(Double(bitPattern: argument))
      try checkFloat(info: info, bits: argument, offset: offset)
    default:
      throw malformed("Unsupported CBOR simple value \(info).", at: offset)
    }
    try emitScalar(value, offset: offset, depth: depth, handler)
  }

  // MARK: Structure

  private mutating func emitScalar(
    _ value: CBORValue,
    offset: Int,
    depth: Int,
    _ handler: Handler
  ) throws {
    startKeyCaptureIfNeeded(offset: offset)
    maximumDepth = Swift.max(maximumDepth, depth)
    try dispatch(.scalar(value), offset: offset, depth: depth, handler)
    try completeItem(handler)
  }

  private mutating func startContainer(
    _ kind: Frame.Kind,
    count: Int?,
    offset: Int,
    depth: Int,
    _ handler: Handler
  ) throws {
    startKeyCaptureIfNeeded(offset: offset)
    maximumDepth = Swift.max(maximumDepth, depth)
    try dispatch(
      kind == .array ? .startArray(count) : .startMap(count),
      offset: offset, depth: depth, handler)
    var remaining = count
    if kind == .map, let count {
      let (doubled, overflow) = count.multipliedReportingOverflow(by: 2)
      guard !overflow else {
        throw malformed("CBOR map length exceeds the remaining input.", at: offset)
      }
      remaining = doubled
    }
    frames.append(Frame(kind: kind, remaining: remaining, depth: depth, offset: offset))
    if remaining == 0 {
      frames.removeLast()
      try dispatch(.end, offset: offset, depth: depth, handler)
      try completeItem(handler)
    } else if remaining != nil {
      try requireChildDepth(depth, at: offset)
    }
  }

  private mutating func closeIndefinite(_ handler: Handler) throws {
    let frame = frames.removeLast()
    switch frame.kind {
    case .bytes, .text:
      let value: CBORValue =
        frame.kind == .bytes
        ? .bytes(Data(frame.chunks)) : .string(String(decoding: frame.chunks, as: UTF8.self))
      maximumDepth = Swift.max(maximumDepth, frame.depth)
      try dispatch(.scalar(value), offset: frame.offset, depth: frame.depth, handler)
    case .array, .map, .tag:
      try dispatch(.end, offset: frame.offset, depth: frame.depth, handler)
    }
    try completeItem(handler)
  }

  /// Records that the innermost pending item finished, and completes every
  /// enclosing tag and definite container that it finishes in turn.
  private mutating func completeItem(_ handler: Handler) throws {
    while true {
      itemCount += 1
      try finishKeyCaptures()
      guard let index = frames.indices.last else {
        isComplete = true
        return
      }
      switch frames[index].kind {
      case .tag:
        let frame = frames.removeLast()
        try dispatch(.end, offset: frame.offset, depth: frame.depth, handler)
        continue
      case .array, .map:
        if frames[index].kind == .map {
          frames[index].expectingKey.toggle()
          if frames[index].expectingKey {
            frames[index].entries += 1
            try checkPendingKey(frameIndex: index)
          }
        } else {
          frames[index].entries += 1
        }
        guard let remaining = frames[index].remaining else { return }
        frames[index].remaining = remaining - 1
        guard remaining == 1 else { return }
        let frame = frames.removeLast()
        try dispatch(.end, offset: frame.offset, depth: frame.depth, handler)
      case .bytes, .text:
        return
      }
    }
  }

  private mutating func dispatch(
    _ event: Event,
    offset: Int,
    depth: Int,
    _ handler: Handler
  ) throws {
    for index in captures.indices { captures[index].builder.handle(event) }
    try handler(event, offset, depth)
  }

  // MARK: Map keys

  private mutating func startKeyCaptureIfNeeded(offset: Int) {
    guard capturesKeys, let index = frames.indices.last, frames[index].kind == .map,
      frames[index].expectingKey
    else { return }
    captures.append(KeyCapture(frameIndex: index, offset: offset))
  }

  private mutating func finishKeyCaptures() throws {
    while let capture = captures.last, let key = capture.builder.result {
      captures.removeLast()
      if limits.rejectDuplicateMapKeys {
        // Preferred re-encoding identifies differently encoded equal keys.
        let identity = try CBOREncoder.encode(key, mode: .lengthFirstDeterministic)
        frames[capture.frameIndex].pendingKey = (identity, capture.offset)
      }
      if let mode = policy.requiredSerializationMode {
        let bytes = try CBOREncoder.encode(key, mode: mode)
        if let previous = frames[capture.frameIndex].previousKeyBytes,
          Self.precedes(bytes, previous, lengthFirst: mode.usesLengthFirstMapOrdering)
        {
          noteRequiredModeViolation(at: capture.offset)
        }
        frames[capture.frameIndex].previousKeyBytes = bytes
      }
    }
  }

  /// Duplicate keys are reported once the pair's value is complete, as the
  /// whole-buffer decoder does.
  private mutating func checkPendingKey(frameIndex: Int) throws {
    guard let (identity, keyOffset) = frames[frameIndex].pendingKey else { return }
    frames[frameIndex].pendingKey = nil
    if let first = frames[frameIndex].keyOffsets[identity] {
      throw policyViolation(
        .notCBORLD, "CBOR map contains a duplicate key.", offset: keyOffset,
        violation: "duplicate-map-key", relatedOffset: first)
    }
    frames[frameIndex].keyOffsets[identity] = keyOffset
  }

  private static func precedes(_ lhs: Data, _ rhs: Data, lengthFirst: Bool) -> Bool {
    if lengthFirst, lhs.count != rhs.count { return lhs.count < rhs.count }
    return lhs.lexicographicallyPrecedes(rhs)
  }

  // MARK: Policy

  private mutating func checkWidth(
    _ argument: UInt64,
    info: UInt8,
    kind: ArgumentKind,
    offset: Int
  ) throws {
    guard !Self.isPreferred(argument, info: info) else { return }
    let rejects =
      kind == .integer
      ? policy.rejectNonPreferredIntegerWidths : policy.rejectNonPreferredLengthWidths
    if rejects {
      let name = kind == .integer ? "integer" : "length"
      throw policyViolation(
        kind == .integer ? .nonPreferredInteger : .nonPreferredLength,
        "CBOR \(name) argument uses a wider representation than required.",
        offset: offset, violation: "non-preferred-\(name)")
    }
    noteRequiredModeViolation(at: offset)
  }

  private mutating func checkFloat(info: UInt8, bits: UInt64, offset: Int) throws {
    let value: Double
    switch info {
    case 25: value = Double(Float16(bitPattern: UInt16(bits)))
    case 26: value = Double(Float(bitPattern: UInt32(bits)))
    default: value = Double(bitPattern: bits)
    }
    let preferred: Bool
    if value.isNaN {
      preferred = info == 25 && bits == 0x7e00
    } else if Double(Float16(value)).bitPattern == value.bitPattern {
      preferred = info == 25
    } else if Double(Float(value)).bitPattern == value.bitPattern {
      preferred = info == 26
    } else {
      preferred = info == 27
    }
    guard !preferred else { return }
    if policy.rejectNonPreferredFloatingPoint {
      throw policyViolation(
        .nonPreferredFloat,
        value.isNaN
          ? "CBOR NaN does not use the preferred half-precision representation."
          : "CBOR floating-point value uses a wider representation than required.",
        offset: offset, violation: "non-preferred-float")
    }
    noteRequiredModeViolation(at: offset)
  }

  private func requireReservedSimpleValues(_ value: UInt8, offset: Int) throws {
    guard policy.allowsReservedSimpleValuesInLosslessMode else {
      throw policyViolation(
        .reservedSimpleValue,
        "CBOR simple value \(value) is not allowed by the decoding policy.",
        offset: offset, violation: "reserved-simple-value")
    }
  }

  private func requireIndefiniteLengths(at offset: Int) throws {
    guard limits.allowsIndefiniteLengthItems else {
      throw malformed(
        "Indefinite-length CBOR items are disabled by the decoding policy.", at: offset)
    }
  }

  private func requireChildDepth(_ depth: Int, at offset: Int) throws {
    guard depth + 1 <= limits.maximumNestingDepth else {
      throw resourceLimit(
        "CBOR nesting exceeds the configured depth of \(limits.maximumNestingDepth).",
        at: offset)
    }
  }

  /// Records the first departure from a required deterministic profile. The
  /// whole-buffer decoder detects it only after parsing, so it is reported
  /// by ``finish()``, after any parse error.
  private mutating func noteRequiredModeViolation(at offset: Int) {
    guard deferredViolation == nil, let mode = policy.requiredSerializationMode else { return }
    deferredViolation = policyViolation(
      .nonPreferredCBOR,
      "CBOR input does not match the required \(mode.rawValue) serialization.",
      offset: offset, violation: "required-serialization-mode")
  }

  // MARK: Helpers

  private func offset(_ index: Int) -> Int { bufferOffset + index }

  private func count(_ value: UInt64, at offset: Int) throws -> Int {
    guard value <= UInt64(Int.max) else {
      throw malformed("CBOR collection is too large for this platform.", at: offset)
    }
    return Int(value)
  }

  private static func isPreferred(_ value: UInt64, info: UInt8) -> Bool {
    switch value {
    case 0...23: return info == UInt8(value)
    case 24...UInt64(UInt8.max): return info == 24
    case 256...UInt64(UInt16.max): return info == 25
    case 65_536...UInt64(UInt32.max): return info == 26
    default: return info == 27
    }
  }

  private static func utf8String(_ bytes: ArraySlice<UInt8>) -> String? {
    if #available(macOS 15.0, iOS 18.0, tvOS 18.0, watchOS 11.0, visionOS 2.0, *) {
      return String(validating: bytes, as: UTF8.self)
    }
    return String(bytes: bytes, encoding: .utf8)
  }

  private func malformed(_ message: String, at offset: Int) -> CBORLDError {
    CBORLDError(code: .notCBORLD, message: message, diagnostic: .init(byteOffset: offset))
  }

  private func resourceLimit(_ message: String, at offset: Int) -> CBORLDError {
    CBORLDError(code: .resourceLimit, message: message, diagnostic: .init(byteOffset: offset))
  }

  private func policyViolation(
    _ code: CBORLDErrorCode,
    _ message: String,
    offset: Int,
    violation: String,
    relatedOffset: Int? = nil
  ) -> CBORLDError {
    let index = offset - bufferOffset
    let initial = index >= 0 && index < buffer.count ? buffer[index] : 0
    return CBORLDError(
      code: code,
      message: message,
      diagnostic: .init(
        byteOffset: offset,
        majorType: initial >> 5,
        additionalInformation: initial & 0x1f,
        violation: violation,
        relatedByteOffset: relatedOffset))
  }
}

// MARK: - Event consumers

/// Rebuilds a `CBORValue` from reader events.
struct CBORValueBuilder {
  private enum Partial {
    case array([CBORValue])
    case map([CBORMapEntry], key: CBORValue?)
    case tag(UInt64, CBORValue?)
  }

  private var stack: [Partial] = []
  private(set) var result: CBORValue?

  mutating func handle(_ event: IncrementalCBORReader.Event) {
    switch event {
    case .scalar(let value): add(value)
    case .startArray: stack.append(.array([]))
    case .startMap: stack.append(.map([], key: nil))
    case .startTag(let tag): stack.append(.tag(tag, nil))
    case .end:
      guard let partial = stack.popLast() else { return }
      switch partial {
      case .array(let values): add(.array(values))
      case .map(let entries, _): add(.map(entries))
      case .tag(let tag, let value): add(.tagged(tag, value ?? .null))
      }
    }
  }

  private mutating func add(_ value: CBORValue) {
    guard let top = stack.popLast() else {
      result = value
      return
    }
    switch top {
    case .array(var values):
      values.append(value)
      stack.append(.array(values))
    case .map(var entries, let key):
      if let key {
        entries.append(CBORMapEntry(key: key, value: value))
        stack.append(.map(entries, key: nil))
      } else {
        stack.append(.map(entries, key: value))
      }
    case .tag(let tag, _):
      stack.append(.tag(tag, value))
    }
  }
}

/// Keeps only the envelope: the root tag, the envelope array, and its
/// scalar elements. Every other container is replaced by a placeholder, so
/// memory does not grow with the payload.
struct ShallowEnvelopeBuilder {
  private var builder = CBORValueBuilder()
  private var rootTag: UInt64?
  /// A container replaced by one placeholder value.
  private var skippedDepth: Int?
  /// A container dropped entirely.
  private var ignoredDepth: Int?
  private var envelopeElements = 0

  /// Whether the tagged value is an array whose first element the envelope
  /// interpretation inspects.
  private var keepsEnvelopeArray: Bool {
    guard let rootTag else { return false }
    return rootTag == 51_997 || (1_664...1_791).contains(rootTag)
  }

  mutating func handle(_ event: IncrementalCBORReader.Event, depth: Int) {
    if let ignoredDepth {
      if depth == ignoredDepth, case .end = event { self.ignoredDepth = nil }
      return
    }
    if let skippedDepth {
      if depth == skippedDepth, case .end = event {
        self.skippedDepth = nil
        builder.handle(.scalar(.null))
      }
      return
    }
    let isContainerStart: Bool
    let startsItem: Bool
    switch event {
    case .startArray, .startMap, .startTag:
      isContainerStart = true
      startsItem = true
    case .scalar:
      isContainerStart = false
      startsItem = true
    case .end:
      isContainerStart = false
      startsItem = false
    }
    if depth == 0, case .startTag(let tag) = event {
      rootTag = tag
      builder.handle(event)
      return
    }
    if depth == 2, startsItem {
      envelopeElements += 1
      // A third element already makes the envelope invalid; keep no more.
      if envelopeElements > 3 {
        if isContainerStart { ignoredDepth = depth }
        return
      }
    }
    if isContainerStart, depth == 0 || depth >= 2 || !keepsEnvelopeArray {
      skippedDepth = depth
      return
    }
    builder.handle(event)
  }

  func parsed() throws -> ParsedCBORLD {
    guard let root = builder.result else {
      throw CBORLDError(code: .notCBORLD, message: "Unexpected end of CBOR data.")
    }
    return try CBORLD.envelope(of: root)
  }
}

/// Identifies the events that belong to a CBOR-LD 1.0 registry-zero payload:
/// the second element of the envelope array when the first is `0`.
struct RegistryZeroPayloadTracker {
  private enum Stage {
    case root
    case envelopeArray
    case registryEntry
    case payload
    case finished
    case invalid
  }

  private var stage = Stage.root
  private var inPayload = false

  /// Whether the envelope is already known not to select registry entry 0.
  var isNotRegistryZero: Bool { stage == .invalid }

  /// Returns whether `event` is part of the payload.
  mutating func observe(_ event: IncrementalCBORReader.Event, depth: Int) -> Bool {
    guard stage != .invalid else { return false }
    if case .end = event, depth < 2 { return false }
    switch depth {
    case 0:
      if case .startTag(51_997) = event, stage == .root {
        stage = .envelopeArray
      } else {
        stage = .invalid
      }
      return false
    case 1:
      if case .startArray = event, stage == .envelopeArray {
        stage = .registryEntry
      } else {
        stage = .invalid
      }
      return false
    case 2:
      switch stage {
      case .registryEntry:
        if case .scalar(.unsigned(0)) = event {
          stage = .payload
        } else {
          stage = .invalid
        }
        return false
      case .payload:
        switch event {
        case .scalar:
          stage = .finished
        case .startArray, .startMap, .startTag:
          inPayload = true
        case .end:
          inPayload = false
          stage = .finished
        }
        return true
      default:
        return false
      }
    default:
      return inPayload
    }
  }
}

/// Builds the payload's `JSONValue`, deferring the first conversion error
/// until the input has been completely parsed.
struct JSONTreeBuilder {
  private enum Partial {
    case array([JSONValue])
    case object([String: JSONValue], key: String?)
  }

  private var stack: [Partial] = []
  private var result: JSONValue?
  private var failure: CBORLDError?

  mutating func handle(_ event: IncrementalCBORReader.Event) {
    guard failure == nil else { return }
    do {
      try apply(event)
    } catch let error as CBORLDError {
      failure = error
      stack.removeAll()
    } catch {
      failure = .invalidInput(String(describing: error))
      stack.removeAll()
    }
  }

  func document() throws -> JSONValue {
    if let failure { throw failure }
    guard let result else {
      throw CBORLDError.invalidInput("The streamed payload was empty.")
    }
    return result
  }

  private var expectsKey: Bool {
    if case .object(_, nil)? = stack.last { return true }
    return false
  }

  private mutating func apply(_ event: IncrementalCBORReader.Event) throws {
    switch event {
    case .scalar(let value):
      if expectsKey {
        guard case .string(let key) = value else { throw Self.nonStringKey }
        guard case .object(let object, _) = stack.removeLast() else { return }
        stack.append(.object(object, key: key))
      } else {
        try add(value.toJSON())
      }
    case .startArray:
      if expectsKey { throw Self.nonStringKey }
      stack.append(.array([]))
    case .startMap:
      if expectsKey { throw Self.nonStringKey }
      stack.append(.object([:], key: nil))
    case .startTag:
      if expectsKey { throw Self.nonStringKey }
      throw CBORLDError.invalidInput("A nested CBOR tag is not a native JSON value.")
    case .end:
      switch stack.popLast() {
      case .array(let values)?: try add(.array(values))
      case .object(let object, _)?: try add(.object(object))
      case nil: break
      }
    }
  }

  private mutating func add(_ value: JSONValue) throws {
    guard let top = stack.popLast() else {
      result = value
      return
    }
    switch top {
    case .array(var values):
      values.append(value)
      stack.append(.array(values))
    case .object(var object, let key?):
      guard object.updateValue(value, forKey: key) == nil else {
        throw CBORLDError.invalidInput("A JSON object cannot contain duplicate key \"\(key)\".")
      }
      stack.append(.object(object, key: nil))
    case .object(let object, nil):
      stack.append(.object(object, key: nil))
    }
  }

  private static let nonStringKey = CBORLDError.invalidInput(
    "A JSON object cannot contain a non-string CBOR map key.")
}

/// Converts payload events to JSON events, rejecting what JSON cannot hold.
struct JSONEventConverter {
  private struct Container {
    let isObject: Bool
    var expectingKey = true
    var keys = Set<String>()
    var pendingKey: String?
  }

  private var stack: [Container] = []

  mutating func convert(_ event: IncrementalCBORReader.Event) throws -> CBORLDJSONEvent {
    if let index = stack.indices.last, stack[index].isObject, stack[index].expectingKey {
      switch event {
      case .scalar(.string(let key)):
        stack[index].expectingKey = false
        stack[index].pendingKey = key
        return .key(key)
      case .end:
        stack.removeLast()
        try completeValue()
        return .endObject
      default:
        throw CBORLDError.invalidInput("A JSON object cannot contain a non-string CBOR map key.")
      }
    }
    switch event {
    case .scalar(let value):
      let converted = try value.toJSON()
      try completeValue()
      switch converted {
      case .bool(let value): return .bool(value)
      case .integer(let value): return .integer(value)
      case .number(let value): return .number(value)
      case .string(let value): return .string(value)
      case .null, .array, .object: return .null
      }
    case .startArray(let count):
      stack.append(Container(isObject: false))
      return .beginArray(count: count)
    case .startMap(let count):
      stack.append(Container(isObject: true))
      return .beginObject(count: count)
    case .startTag:
      throw CBORLDError.invalidInput("A nested CBOR tag is not a native JSON value.")
    case .end:
      stack.removeLast()
      try completeValue()
      return .endArray
    }
  }

  /// Records that a value finished inside the enclosing object, rejecting a
  /// duplicate key.
  private mutating func completeValue() throws {
    guard let index = stack.indices.last, stack[index].isObject,
      let key = stack[index].pendingKey
    else { return }
    guard stack[index].keys.insert(key).inserted else {
      throw CBORLDError.invalidInput("A JSON object cannot contain duplicate key \"\(key)\".")
    }
    stack[index].pendingKey = nil
    stack[index].expectingKey = true
  }
}
