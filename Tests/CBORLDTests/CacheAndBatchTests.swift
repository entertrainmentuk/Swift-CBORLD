import Foundation
import XCTest

@testable import CBORLD

/// The bounded resource cache, batch accounting, and streaming batches.
final class CacheAndBatchTests: XCTestCase {
  private let context: JSONValue = ["@context": ["name": "ex:name"]]

  // MARK: Resource cache

  func testConcurrentRequestsShareOneLoad() async throws {
    let gate = Gate()
    let calls = Counter()
    let context = self.context
    let registry = CBORLDContextRegistry(fallback: { _ in
      calls.increment()
      await gate.wait()
      return context
    })
    let cache = CBORLDResourceCache(registry: registry)
    try await withThrowingTaskGroup(of: JSONValue.self) { group in
      for _ in 0..<10 { group.addTask { try await cache.load("urn:shared") } }
      await waitUntil { await cache.statistics.misses == 10 }
      await gate.open()
      for try await document in group { XCTAssertEqual(document, context) }
    }
    XCTAssertEqual(calls.value, 1)
    _ = try await cache.load("urn:shared")
    let statistics = await cache.statistics
    XCTAssertEqual(statistics.loads, 1)
    XCTAssertEqual(statistics.misses, 10)
    XCTAssertEqual(statistics.hits, 1)
    XCTAssertEqual(statistics.entryCount, 1)
  }

  func testCancelledWaiterReturnsWhileTheSharedLoadContinues() async throws {
    let gate = Gate()
    let context = self.context
    let registry = CBORLDContextRegistry(fallback: { _ in
      await gate.wait()
      return context
    })
    let cache = CBORLDResourceCache(registry: registry)
    let cancelled = Task { try await cache.load("urn:slow") }
    let patient = Task { try await cache.load("urn:slow") }
    await waitUntil { await cache.statistics.misses == 2 }
    cancelled.cancel()
    do {
      _ = try await cancelled.value
      XCTFail("Expected cancellation while the load is still blocked.")
    } catch is CancellationError {
    }
    await gate.open()
    let document = try await patient.value
    XCTAssertEqual(document, context)
  }

  func testAbandonedLoadIsCancelledAndFailuresAreNotCached() async throws {
    let observedCancellation = Counter()
    let attempts = Counter()
    let context = self.context
    let registry = CBORLDContextRegistry(fallback: { url in
      attempts.increment()
      if url == "urn:abandoned" {
        do {
          try await Task.sleep(for: .seconds(30))
        } catch {
          observedCancellation.increment()
          throw error
        }
      }
      if url == "urn:flaky", attempts.value == 2 {
        throw CBORLDError(code: .unknownContext, message: "Transient failure.")
      }
      return context
    })
    let cache = CBORLDResourceCache(registry: registry)
    let abandoned = Task { try await cache.load("urn:abandoned") }
    await waitUntil { await cache.statistics.loads == 1 }
    abandoned.cancel()
    _ = try? await abandoned.value
    await waitUntil { observedCancellation.value == 1 }

    await assertCBORLDError(.unknownContext) { _ = try await cache.load("urn:flaky") }
    let retried = try await cache.load("urn:flaky")
    XCTAssertEqual(retried, context)
    XCTAssertEqual(attempts.value, 3)
  }

  func testPinIsVerifiedBeforeADocumentEntersTheCache() async throws {
    let pin = try CBORLD.contextFingerprint(of: context)
    let registry = CBORLDContextRegistry(
      expectedFingerprints: ["urn:pinned": pin],
      fallback: { _ in ["@context": ["name": "ex:tampered"]] })
    let cache = CBORLDResourceCache(registry: registry)
    await assertCBORLDError(.integrityMismatch) { _ = try await cache.load("urn:pinned") }
    let entries = await cache.statistics.entryCount
    XCTAssertEqual(entries, 0)

    let good = CBORLDResourceCache(
      registry: .init(documents: ["urn:pinned": context], expectedFingerprints: ["urn:pinned": pin])
    )
    let loaded = try await good.resolve(
      .init(url: "urn:pinned", maximumByteCount: .max, maximumRedirects: 0, importDepth: 0))
    XCTAssertEqual(loaded.expectedFingerprint, pin)
    XCTAssertEqual(loaded.verifiedFingerprint, pin)
  }

  func testLeastRecentlyUsedEvictionWithinEntryAndByteLimits() async throws {
    let documents: [String: JSONValue] = [
      "urn:a": ["@context": ["a": "ex:a"]],
      "urn:b": ["@context": ["b": "ex:b"]],
      "urn:c": ["@context": ["c": "ex:c"]],
      "urn:big": ["@context": ["big": .string(String(repeating: "x", count: 4_096))]],
    ]
    let calls = Counter()
    let registry = CBORLDContextRegistry(fallback: { url in
      calls.increment()
      return documents[url]!
    })
    let cache = CBORLDResourceCache(
      registry: registry, limits: .init(maximumEntries: 2, maximumBytes: 1_024))
    _ = try await cache.load("urn:a")
    _ = try await cache.load("urn:b")
    _ = try await cache.load("urn:a")
    _ = try await cache.load("urn:c")
    var statistics = await cache.statistics
    XCTAssertEqual(statistics.entryCount, 2)
    XCTAssertEqual(statistics.evictions, 1)
    _ = try await cache.load("urn:a")
    XCTAssertEqual(calls.value, 3, "urn:a stayed cached; urn:b was least recently used.")
    _ = try await cache.load("urn:b")
    XCTAssertEqual(calls.value, 4)

    // A document larger than the byte budget is returned but never cached.
    _ = try await cache.load("urn:big")
    _ = try await cache.load("urn:big")
    XCTAssertEqual(calls.value, 6)
    statistics = await cache.statistics
    XCTAssertLessThanOrEqual(statistics.byteCount, 1_024)

    await cache.removeAll()
    let cleared = await cache.statistics
    XCTAssertEqual(cleared.entryCount, 0)
    XCTAssertEqual(cleared.byteCount, 0)
  }

  func testCachedDocumentsExpireAfterTheirTimeToLive() async throws {
    let clock = ManualClock()
    let calls = Counter()
    let context = self.context
    let registry = CBORLDContextRegistry(fallback: { _ in
      calls.increment()
      return context
    })
    let cache = CBORLDResourceCache(
      registry: registry, limits: .init(timeToLive: .seconds(60)), now: { clock.now })
    _ = try await cache.load("urn:ttl")
    clock.advance(by: .seconds(59))
    _ = try await cache.load("urn:ttl")
    XCTAssertEqual(calls.value, 1)
    clock.advance(by: .seconds(1))
    _ = try await cache.load("urn:ttl")
    XCTAssertEqual(calls.value, 2)
    let expirations = await cache.statistics.expirations
    XCTAssertEqual(expirations, 1)
  }

  func testPreparedSessionsShareOneBoundedCache() async throws {
    let calls = Counter()
    let context = self.context
    let registry = CBORLDContextRegistry(fallback: { _ in
      calls.increment()
      return context
    })
    let cache = CBORLDResourceCache(registry: registry)
    let encoder = try CBORLDPreparedEncoder(resourceCache: cache)
    let decoder = try CBORLDPreparedDecoder(resourceCache: cache)
    let document: JSONValue = ["@context": "urn:shared", "name": "x"]
    for _ in 0..<5 {
      let decoded = try await decoder.decode(try await encoder.encode(document))
      XCTAssertEqual(decoded, document)
    }
    XCTAssertEqual(calls.value, 1)
    XCTAssertThrowsError(
      try CBORLDPreparedDecoder(contextRegistry: registry, resourceCache: cache))
  }

  // MARK: Batch accounting

  func testStructuralCostIsTheExactUncompressedPayloadSize() throws {
    let documents: [JSONValue] = [
      .null, true, 0, 23, 24, 255, 256, -1, -25, 65_536, .integer(.max), .integer(.min),
      1.5, 0.1, 1e300, 3.0, .number(-0.0), 9_007_199_254_740_993, "", "é",
      .string(String(repeating: "z", count: 300)), [], [:], [[1, [2, [3]]]],
      ["key": ["nested": [1, 2, "three"]], "other": .null],
    ]
    for document in documents {
      let payload = try CBORLD.encodeUncompressed(document).count - 5
      XCTAssertEqual(document.structuralCost.encodedByteCount, payload, "\(document)")
    }
    let sample: JSONValue = ["a": ["bb", 1], "c": [:]]
    let cost = sample.structuralCost
    XCTAssertEqual(cost.nodeCount, 5)
    XCTAssertEqual(cost.stringByteCount, 4)
    XCTAssertEqual(cost.maximumDepth, 2)
  }

  func testBatchObservationsLabelTheirMeasures() async throws {
    let documents: [JSONValue] = [["a": 1], ["b": "two"]]
    let encoder = try CBORLDPreparedEncoder(dictionary: .init(code: 0))
    let encoded = try await encoder.encodeBatch(documents, policy: .init(recordsTiming: true))
    for (document, outcome) in zip(documents, encoded) {
      let observation = try XCTUnwrap(outcome.observation)
      XCTAssertEqual(observation.inputMeasure, .structuralCost)
      XCTAssertEqual(observation.inputByteCount, document.structuralCost.encodedByteCount)
      XCTAssertEqual(observation.outputMeasure, .encodedBytes)
      XCTAssertEqual(observation.outputByteCount, outcome.value?.count)
    }

    let custom = try await encoder.encodeBatch(
      documents, policy: .init(recordsTiming: true, encodeInputCost: { _ in 7 }))
    XCTAssertEqual(custom.first?.observation?.inputMeasure, .callerDefined)
    XCTAssertEqual(custom.first?.observation?.inputByteCount, 7)
    await assertCBORLDError(.batchLimit) {
      _ = try await encoder.encodeBatch(
        documents, policy: .init(maximumTotalInputBytes: 13, encodeInputCost: { _ in 7 }))
    }

    let bytes = encoded.compactMap(\.value)
    let decoder = try CBORLDPreparedDecoder()
    let decoded = try await decoder.decodeBatch(bytes, policy: .init(recordsTiming: true))
    XCTAssertEqual(decoded.first?.observation?.inputMeasure, .encodedBytes)
    XCTAssertEqual(decoded.first?.observation?.inputByteCount, bytes.first?.count)
    XCTAssertNil(
      decoded.first?.observation?.outputByteCount, "JSON text is not measured by default.")
    let measured = try await decoder.decodeBatch(
      bytes, policy: .init(measuresDecodedJSONTextSize: true))
    XCTAssertEqual(measured.first?.observation?.outputMeasure, .jsonText)
    XCTAssertEqual(measured.first?.observation?.outputByteCount, try documents[0].data().count)
  }

  // MARK: Streaming batches

  func testStreamingBatchYieldsInCompletionOrInputOrder() async throws {
    let gates = (0..<3).map { _ in Gate() }
    @Sendable func engine(_ order: CBORLDBatchResultOrder) -> BatchStreamEngine<Int> {
      BatchStreamEngine(
        source: [0, 1, 2].async,
        measure: { _ in 1 },
        inputMeasure: .callerDefined,
        policy: .init(maximumConcurrentTasks: 3),
        order: order,
        outputByteCount: { _ in nil },
        operation: { index in
          await gates[index].wait()
          return index * 10
        })
    }
    // Complete in reverse order: each gate opens only after the previous
    // outcome has been received, so the order is deterministic.
    let completion = CBORLDBatchOutcomeStream { engine(.completionOrder) }
    await gates[2].open()
    var completionIndices: [Int] = []
    for try await outcome in completion {
      completionIndices.append(outcome.index)
      XCTAssertEqual(outcome.outcome.value, outcome.index * 10)
      if outcome.index > 0 { await gates[outcome.index - 1].open() }
    }
    XCTAssertEqual(completionIndices, [2, 1, 0])

    let ordered = CBORLDBatchOutcomeStream { engine(.inputOrder(maximumReorderBuffer: 3)) }
    var inputIndices: [Int] = []
    for try await outcome in ordered { inputIndices.append(outcome.index) }
    XCTAssertEqual(inputIndices, [0, 1, 2])
  }

  func testStreamingBatchAdmitsWorkOnlyAsTheConsumerPulls() async throws {
    let pulled = Counter()
    let source = CountingSequence(count: 100, pulled: pulled)
    let stream = CBORLDBatchOutcomeStream {
      BatchStreamEngine(
        source: source,
        measure: { _ in 1 },
        inputMeasure: .callerDefined,
        policy: .init(maximumConcurrentTasks: 2),
        order: .completionOrder,
        outputByteCount: { _ in nil },
        operation: { $0 })
    }
    var iterator = stream.makeAsyncIterator()
    _ = try await iterator.next()
    XCTAssertLessThanOrEqual(pulled.value, 2)
    _ = try await iterator.next()
    XCTAssertLessThanOrEqual(pulled.value, 4)
  }

  func testEndingIterationCancelsWorkStillInFlight() async throws {
    let cancelled = Counter()
    let stream = CBORLDBatchOutcomeStream {
      BatchStreamEngine(
        source: Array(0..<4).async,
        measure: { _ in 1 },
        inputMeasure: .callerDefined,
        policy: .init(maximumConcurrentTasks: 4),
        order: .completionOrder,
        outputByteCount: { _ in nil },
        operation: { index in
          if index == 0 { return 0 }
          do {
            try await Task.sleep(for: .seconds(30))
          } catch {
            cancelled.increment()
            throw error
          }
          return index
        })
    }
    for try await outcome in stream {
      XCTAssertEqual(outcome.index, 0)
      break
    }
    await waitUntil { cancelled.value == 3 }
  }

  func testDecodeBatchStreamEnforcesBatchLimitsAndKeepsPerDocumentFailures() async throws {
    let good = try CBORLD.encodeUncompressed(["ok": true])
    let bad = Data([0x00])
    let decoder = try CBORLDPreparedDecoder()
    var failures = 0
    var successes = 0
    for try await outcome in decoder.decodeBatchStream(
      [good, bad, good].async, order: .inputOrder(maximumReorderBuffer: 1))
    {
      if outcome.outcome.failure != nil { failures += 1 } else { successes += 1 }
    }
    XCTAssertEqual(failures, 1)
    XCTAssertEqual(successes, 2)

    await assertCBORLDError(.batchLimit) {
      for try await _ in decoder.decodeBatchStream(
        [good, good, good].async, policy: .init(maximumDocumentCount: 2))
      {}
    }
    await assertCBORLDError(.invalidExecutionPolicy) {
      for try await _ in decoder.decodeBatchStream(
        [good].async, order: .inputOrder(maximumReorderBuffer: -1))
      {}
    }

    let encoder = try CBORLDPreparedEncoder(dictionary: .init(code: 0))
    var encoded: [Int: Data] = [:]
    for try await outcome in encoder.encodeBatchStream([["a": 1], ["b": 2]].async) {
      encoded[outcome.index] = outcome.outcome.value
    }
    XCTAssertEqual(encoded[1], try CBORLD.encodeUncompressed(["b": 2]))
  }
}

// MARK: - Test utilities

/// A one-shot gate that suspends callers until it is opened.
actor Gate {
  private var isOpen = false
  private var waiters: [CheckedContinuation<Void, Never>] = []

  func wait() async {
    if isOpen { return }
    await withCheckedContinuation { waiters.append($0) }
  }

  func open() {
    isOpen = true
    for waiter in waiters { waiter.resume() }
    waiters.removeAll()
  }
}

final class Counter: @unchecked Sendable {
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

/// A controllable time source for cache expiry.
final class ManualClock: @unchecked Sendable {
  private let lock = NSLock()
  private var elapsed = Duration.zero

  var now: Duration {
    lock.lock()
    defer { lock.unlock() }
    return elapsed
  }

  func advance(by duration: Duration) {
    lock.lock()
    elapsed += duration
    lock.unlock()
  }
}

/// Polls a condition with a generous deadline instead of fixed sleeps.
func waitUntil(
  timeout: Duration = .seconds(10),
  file: StaticString = #filePath,
  line: UInt = #line,
  _ condition: @Sendable () async -> Bool
) async {
  let deadline = ContinuousClock.now + timeout
  while ContinuousClock.now < deadline {
    if await condition() { return }
    try? await Task.sleep(for: .milliseconds(5))
  }
  XCTFail("Condition was not met within \(timeout).", file: file, line: line)
}

/// An asynchronous view of an array.
struct AsyncArray<Element: Sendable>: AsyncSequence, Sendable {
  let elements: [Element]

  struct AsyncIterator: AsyncIteratorProtocol {
    var index = 0
    let elements: [Element]

    mutating func next() async -> Element? {
      guard index < elements.count else { return nil }
      defer { index += 1 }
      return elements[index]
    }
  }

  func makeAsyncIterator() -> AsyncIterator { AsyncIterator(elements: elements) }
}

extension Array where Element: Sendable {
  var async: AsyncArray<Element> { AsyncArray(elements: self) }
}

/// Counts how many elements a consumer has pulled.
struct CountingSequence: AsyncSequence, Sendable {
  let count: Int
  let pulled: Counter

  struct AsyncIterator: AsyncIteratorProtocol {
    var index = 0
    let count: Int
    let pulled: Counter

    mutating func next() async -> Int? {
      guard index < count else { return nil }
      pulled.increment()
      defer { index += 1 }
      return index
    }
  }

  func makeAsyncIterator() -> AsyncIterator {
    AsyncIterator(count: count, pulled: pulled)
  }
}
