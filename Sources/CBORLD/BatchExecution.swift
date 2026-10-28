import Foundation

/// Production execution policy for independent documents. The deterministic
/// CPU compute provider remains serial; this policy is used only by the
/// prepared application-facing batch APIs.
public struct CBORLDExecutionPolicy: Sendable {
  public var maximumConcurrentTasks: Int
  public var minimumParallelDocumentCount: Int
  public var minimumParallelBytes: Int
  public var cancellationCheckStride: Int
  public var maximumDocumentCount: Int
  /// Budget for the sum of every document's input measure: exact bytes for
  /// decoding, and ``encodeInputCost`` for encoding.
  public var maximumTotalInputBytes: Int
  /// `nil` inherits the caller task's priority and task-local values.
  public var taskPriority: TaskPriority?
  /// Prevents nested CPU parallelism when an injected backend already owns a
  /// parallel dispatch.
  public var backendAlreadyParallel: Bool
  public var recordsTiming: Bool
  /// Optional monotonic byte counter supplied by an allocator profiler. The
  /// package does not fabricate a portable allocation count when none exists.
  public var allocationByteCounter: (@Sendable () -> UInt64?)?
  /// Measures one in-memory document for encoding budgets and observations.
  /// `nil` uses ``CBORLDStructuralCost/encodedByteCount``, which is exact and
  /// requires no serialization.
  public var encodeInputCost: (@Sendable (JSONValue) -> Int)?
  /// Serializes each decoded document to JSON text to report its size in
  /// observations. This costs a complete serialization per document, so it is
  /// off by default and reported with ``CBORLDBatchOutputMeasure/jsonText``.
  public var measuresDecodedJSONTextSize: Bool

  public init(
    maximumConcurrentTasks: Int = min(ProcessInfo.processInfo.activeProcessorCount, 4),
    minimumParallelDocumentCount: Int = 4,
    minimumParallelBytes: Int = 8 * 1_024,
    cancellationCheckStride: Int = 1,
    maximumDocumentCount: Int = 100_000,
    maximumTotalInputBytes: Int = 256 * 1_024 * 1_024,
    taskPriority: TaskPriority? = nil,
    backendAlreadyParallel: Bool = false,
    recordsTiming: Bool = false,
    allocationByteCounter: (@Sendable () -> UInt64?)? = nil,
    encodeInputCost: (@Sendable (JSONValue) -> Int)? = nil,
    measuresDecodedJSONTextSize: Bool = false
  ) {
    self.maximumConcurrentTasks = maximumConcurrentTasks
    self.minimumParallelDocumentCount = minimumParallelDocumentCount
    self.minimumParallelBytes = minimumParallelBytes
    self.cancellationCheckStride = cancellationCheckStride
    self.maximumDocumentCount = maximumDocumentCount
    self.maximumTotalInputBytes = maximumTotalInputBytes
    self.taskPriority = taskPriority
    self.backendAlreadyParallel = backendAlreadyParallel
    self.recordsTiming = recordsTiming
    self.allocationByteCounter = allocationByteCounter
    self.encodeInputCost = encodeInputCost
    self.measuresDecodedJSONTextSize = measuresDecodedJSONTextSize
  }

  var recordsObservations: Bool {
    recordsTiming || allocationByteCounter != nil || measuresDecodedJSONTextSize
  }
}

/// What an observation's input size measures.
public enum CBORLDBatchInputMeasure: String, Sendable, Hashable, Codable, CaseIterable {
  /// The exact encoded CBOR-LD input bytes.
  case encodedBytes = "encoded-bytes"
  /// ``CBORLDStructuralCost/encodedByteCount`` of an in-memory document.
  case structuralCost = "structural-cost"
  /// The policy's ``CBORLDExecutionPolicy/encodeInputCost`` function.
  case callerDefined = "caller-defined"
}

/// What an observation's output size measures.
public enum CBORLDBatchOutputMeasure: String, Sendable, Hashable, Codable, CaseIterable {
  /// The exact encoded CBOR-LD output bytes.
  case encodedBytes = "encoded-bytes"
  /// The length of the decoded document serialized as JSON text.
  case jsonText = "json-text"
}

public struct CBORLDBatchObservation: Sendable, Hashable, Codable {
  public let durationNanoseconds: UInt64?
  public let inputByteCount: Int
  public let inputMeasure: CBORLDBatchInputMeasure
  public let outputByteCount: Int?
  public let outputMeasure: CBORLDBatchOutputMeasure?
  public let allocatedByteCount: UInt64?
}

public struct CBORLDBatchFailure: Error, Sendable, Hashable, Codable {
  public let code: CBORLDErrorCode
  public let message: String
  public let diagnostic: CBORLDSourceDiagnostic?
}

public enum CBORLDBatchOutcome<Value: Sendable>: Sendable {
  case success(value: Value, observation: CBORLDBatchObservation?)
  case failure(CBORLDBatchFailure)

  public var value: Value? {
    guard case .success(let value, _) = self else { return nil }
    return value
  }

  public var failure: CBORLDBatchFailure? {
    guard case .failure(let failure) = self else { return nil }
    return failure
  }

  public var observation: CBORLDBatchObservation? {
    guard case .success(_, let observation) = self else { return nil }
    return observation
  }
}

/// One outcome of a streaming batch together with its input position.
public struct CBORLDIndexedOutcome<Value: Sendable>: Sendable {
  public let index: Int
  public let outcome: CBORLDBatchOutcome<Value>

  public init(index: Int, outcome: CBORLDBatchOutcome<Value>) {
    self.index = index
    self.outcome = outcome
  }
}

/// The order in which a streaming batch yields outcomes.
public enum CBORLDBatchResultOrder: Sendable, Hashable {
  /// Yield each outcome as soon as it completes. At most
  /// ``CBORLDExecutionPolicy/maximumConcurrentTasks`` documents are in flight.
  case completionOrder
  /// Yield outcomes in input order. Completed outcomes waiting for an earlier
  /// document occupy the reorder buffer, and new documents are not started
  /// while it is full, so at most `maximumReorderBuffer` plus the concurrency
  /// limit outcomes are retained.
  case inputOrder(maximumReorderBuffer: Int)
}

/// A pull-driven stream of batch outcomes. Work is admitted only as the
/// consumer iterates, which gives natural backpressure: a slow consumer stops
/// new documents from being read or started. Ending iteration early, or
/// cancelling the consuming task, cancels the documents still in flight.
public struct CBORLDBatchOutcomeStream<Value: Sendable>: AsyncSequence, Sendable {
  public typealias Element = CBORLDIndexedOutcome<Value>

  private let makeEngine: @Sendable () -> BatchStreamEngine<Value>

  init(makeEngine: @escaping @Sendable () -> BatchStreamEngine<Value>) {
    self.makeEngine = makeEngine
  }

  public func makeAsyncIterator() -> Iterator {
    Iterator(engine: makeEngine())
  }

  public struct Iterator: AsyncIteratorProtocol {
    private let engine: BatchStreamEngine<Value>

    init(engine: BatchStreamEngine<Value>) {
      self.engine = engine
    }

    public mutating func next() async throws -> CBORLDIndexedOutcome<Value>? {
      try await engine.next()
    }
  }
}

extension CBORLDPreparedEncoder {
  /// Encodes independent documents with bounded concurrency and stable output
  /// ordering. One failed document does not discard successful siblings.
  /// Documents are measured by ``CBORLDExecutionPolicy/encodeInputCost`` or,
  /// by default, their exact ``CBORLDStructuralCost``; nothing is serialized
  /// to JSON for accounting.
  public func encodeBatch(
    _ documents: [JSONValue],
    policy: CBORLDExecutionPolicy = .init()
  ) async throws -> [CBORLDBatchOutcome<Data>] {
    let measure = CBORLDBatchExecutor.encodeMeasure(policy)
    return try await CBORLDBatchExecutor.execute(
      inputs: documents,
      byteCounts: documents.map(measure.cost),
      inputMeasure: measure.kind,
      policy: policy,
      outputByteCount: { ($0.count, .encodedBytes) },
      operation: { try await self.encode($0) })
  }

  /// Streams encode outcomes for an asynchronous document source.
  public func encodeBatchStream<Documents: AsyncSequence & Sendable>(
    _ documents: Documents,
    policy: CBORLDExecutionPolicy = .init(),
    order: CBORLDBatchResultOrder = .completionOrder
  ) -> CBORLDBatchOutcomeStream<Data> where Documents.Element == JSONValue {
    let measure = CBORLDBatchExecutor.encodeMeasure(policy)
    return CBORLDBatchOutcomeStream {
      BatchStreamEngine(
        source: documents,
        measure: measure.cost,
        inputMeasure: measure.kind,
        policy: policy,
        order: order,
        outputByteCount: { ($0.count, .encodedBytes) },
        operation: { try await self.encode($0) })
    }
  }
}

extension CBORLDPreparedDecoder {
  /// Decodes independent documents with bounded concurrency and stable output
  /// ordering. Cancellation propagates to all in-flight work.
  public func decodeBatch(
    _ documents: [Data],
    policy: CBORLDExecutionPolicy = .init()
  ) async throws -> [CBORLDBatchOutcome<JSONValue>] {
    try await CBORLDBatchExecutor.execute(
      inputs: documents,
      byteCounts: documents.map(\.count),
      inputMeasure: .encodedBytes,
      policy: policy,
      outputByteCount: CBORLDBatchExecutor.decodedOutputMeasure(policy),
      operation: { try await self.decode($0) })
  }

  /// Consumes an asynchronous document source with bounded in-flight work.
  /// The iterator is advanced only when a task slot becomes available, which
  /// provides backpressure to upstream producers. Results are restored to input
  /// order and retain per-document failures.
  public func decodeBatch<Documents: AsyncSequence & Sendable>(
    _ documents: Documents,
    policy: CBORLDExecutionPolicy = .init()
  ) async throws -> [CBORLDBatchOutcome<JSONValue>]
  where Documents.Element == Data {
    var ordered: [Int: CBORLDBatchOutcome<JSONValue>] = [:]
    for try await indexed in decodeBatchStream(documents, policy: policy) {
      ordered[indexed.index] = indexed.outcome
    }
    return (0..<ordered.count).compactMap { ordered[$0] }
  }

  /// Streams decode outcomes for an asynchronous document source without
  /// retaining the whole batch. Use ``CBORLDBatchResultOrder/completionOrder``
  /// for minimum latency and memory, or
  /// ``CBORLDBatchResultOrder/inputOrder(maximumReorderBuffer:)`` when
  /// callers need stable ordering.
  public func decodeBatchStream<Documents: AsyncSequence & Sendable>(
    _ documents: Documents,
    policy: CBORLDExecutionPolicy = .init(),
    order: CBORLDBatchResultOrder = .completionOrder
  ) -> CBORLDBatchOutcomeStream<JSONValue> where Documents.Element == Data {
    CBORLDBatchOutcomeStream {
      BatchStreamEngine(
        source: documents,
        measure: \.count,
        inputMeasure: .encodedBytes,
        policy: policy,
        order: order,
        outputByteCount: CBORLDBatchExecutor.decodedOutputMeasure(policy),
        operation: { try await self.decode($0) })
    }
  }
}

/// The pull-driven state machine behind ``CBORLDBatchOutcomeStream``. It is
/// owned by one iterator and used only by the consuming task.
final class BatchStreamEngine<Value: Sendable> {
  private typealias Completion = (index: Int, result: Result<CBORLDBatchOutcome<Value>, Error>)

  /// A document read from the source, measured, and ready to start.
  private struct PendingDocument {
    let cost: Int
    let start:
      (_ index: Int, _ completions: AsyncStream<Completion>.Continuation) -> Task<
        Void, Never
      >
  }

  private let pullSource: () async throws -> PendingDocument?
  private let policy: CBORLDExecutionPolicy
  private let order: CBORLDBatchResultOrder
  private var completionIterator: AsyncStream<Completion>.Iterator
  private let continuation: AsyncStream<Completion>.Continuation
  private var inFlight: [Int: Task<Void, Never>] = [:]
  private var reorderBuffer: [Int: CBORLDBatchOutcome<Value>] = [:]
  private var sourceExhausted = false
  private var admitted = 0
  private var nextToYield = 0
  private var totalBytes = 0
  private var terminalError: Error?
  private var finished = false
  private var validated = false

  init<Source: AsyncSequence, Input: Sendable>(
    source: Source,
    measure: @escaping (Input) -> Int,
    inputMeasure: CBORLDBatchInputMeasure,
    policy: CBORLDExecutionPolicy,
    order: CBORLDBatchResultOrder,
    outputByteCount: @escaping @Sendable (Value) -> (Int, CBORLDBatchOutputMeasure)?,
    operation: @escaping @Sendable (Input) async throws -> Value
  ) where Source.Element == Input {
    var iterator = source.makeAsyncIterator()
    self.pullSource = {
      guard let input = try await iterator.next() else { return nil }
      let cost = measure(input)
      return PendingDocument(cost: cost) { index, completions in
        Task(priority: policy.taskPriority) {
          let result: Result<CBORLDBatchOutcome<Value>, Error>
          do {
            result = .success(
              try await CBORLDBatchExecutor.perform(
                input,
                inputByteCount: cost,
                inputMeasure: inputMeasure,
                policy: policy,
                outputByteCount: outputByteCount,
                operation: operation))
          } catch {
            result = .failure(error)
          }
          completions.yield((index, result))
        }
      }
    }
    self.policy = policy
    self.order = order
    var captured: AsyncStream<Completion>.Continuation?
    let completions = AsyncStream<Completion> { captured = $0 }
    self.continuation = captured!
    self.completionIterator = completions.makeAsyncIterator()
  }

  deinit {
    for task in inFlight.values { task.cancel() }
    continuation.finish()
  }

  func next() async throws -> CBORLDIndexedOutcome<Value>? {
    if let terminalError { throw terminalError }
    if finished { return nil }
    do {
      if !validated {
        try CBORLDBatchExecutor.validate(policy)
        if case .inputOrder(let maximumReorderBuffer) = order, maximumReorderBuffer < 0 {
          throw CBORLDError(
            code: .invalidExecutionPolicy,
            message: "maximumReorderBuffer must not be negative.")
        }
        validated = true
      }
      while true {
        if case .inputOrder = order, let outcome = reorderBuffer.removeValue(forKey: nextToYield) {
          let index = nextToYield
          nextToYield += 1
          return .init(index: index, outcome: outcome)
        }
        try await admit()
        if inFlight.isEmpty {
          finished = true
          continuation.finish()
          return nil
        }
        guard let completion = await completionIterator.next() else {
          try Task.checkCancellation()
          throw CancellationError()
        }
        inFlight[completion.index] = nil
        let outcome = try completion.result.get()
        switch order {
        case .completionOrder:
          return .init(index: completion.index, outcome: outcome)
        case .inputOrder:
          reorderBuffer[completion.index] = outcome
        }
      }
    } catch {
      terminalError = error
      for task in inFlight.values { task.cancel() }
      inFlight.removeAll()
      continuation.finish()
      throw error
    }
  }

  /// Starts documents while a task slot and reorder space are available.
  private func admit() async throws {
    let capacity = policy.backendAlreadyParallel ? 1 : policy.maximumConcurrentTasks
    while !sourceExhausted, inFlight.count < capacity, hasReorderRoom {
      if admitted.isMultiple(of: policy.cancellationCheckStride) {
        try Task.checkCancellation()
      }
      guard let document = try await pullSource() else {
        sourceExhausted = true
        return
      }
      try CBORLDBatchExecutor.account(
        inputByteCount: document.cost,
        nextDocumentCount: admitted + 1,
        totalBytes: &totalBytes,
        policy: policy)
      inFlight[admitted] = document.start(admitted, continuation)
      admitted += 1
    }
  }

  /// Admission never blocks when nothing is in flight, so the next document to
  /// yield is always either buffered or running.
  private var hasReorderRoom: Bool {
    guard case .inputOrder(let maximumReorderBuffer) = order else { return true }
    return inFlight.isEmpty || reorderBuffer.count < maximumReorderBuffer
  }
}

enum CBORLDBatchExecutor {
  static func encodeMeasure(
    _ policy: CBORLDExecutionPolicy
  ) -> (cost: @Sendable (JSONValue) -> Int, kind: CBORLDBatchInputMeasure) {
    if let cost = policy.encodeInputCost { return (cost, .callerDefined) }
    return ({ $0.structuralCost.encodedByteCount }, .structuralCost)
  }

  static func decodedOutputMeasure(
    _ policy: CBORLDExecutionPolicy
  ) -> @Sendable (JSONValue) -> (Int, CBORLDBatchOutputMeasure)? {
    guard policy.measuresDecodedJSONTextSize else { return { _ in nil } }
    return { value in (try? value.data().count).map { ($0, .jsonText) } }
  }

  static func execute<Input: Sendable, Output: Sendable>(
    inputs: [Input],
    byteCounts: [Int],
    inputMeasure: CBORLDBatchInputMeasure,
    policy: CBORLDExecutionPolicy,
    outputByteCount: @escaping @Sendable (Output) -> (Int, CBORLDBatchOutputMeasure)?,
    operation: @escaping @Sendable (Input) async throws -> Output
  ) async throws -> [CBORLDBatchOutcome<Output>] {
    try validate(policy)
    guard inputs.count == byteCounts.count else {
      throw CBORLDError.invalidInput("Batch inputs and byte counts have different cardinality.")
    }
    guard inputs.count <= policy.maximumDocumentCount else {
      throw batchLimit(
        "Batch contains \(inputs.count) documents; limit is \(policy.maximumDocumentCount).")
    }
    let totalBytes = try byteCounts.reduce(0) { partial, count in
      guard count >= 0, partial <= policy.maximumTotalInputBytes - count else {
        throw batchLimit("Batch input exceeds \(policy.maximumTotalInputBytes) bytes.")
      }
      return partial + count
    }
    guard totalBytes <= policy.maximumTotalInputBytes else {
      throw batchLimit("Batch input exceeds \(policy.maximumTotalInputBytes) bytes.")
    }
    guard !inputs.isEmpty else { return [] }

    let parallel =
      !policy.backendAlreadyParallel
      && inputs.count >= policy.minimumParallelDocumentCount
      && totalBytes >= policy.minimumParallelBytes
      && policy.maximumConcurrentTasks > 1
    if !parallel {
      var results: [CBORLDBatchOutcome<Output>] = []
      results.reserveCapacity(inputs.count)
      for index in inputs.indices {
        if index.isMultiple(of: policy.cancellationCheckStride) {
          try Task.checkCancellation()
        }
        results.append(
          try await perform(
            inputs[index],
            inputByteCount: byteCounts[index],
            inputMeasure: inputMeasure,
            policy: policy,
            outputByteCount: outputByteCount,
            operation: operation))
      }
      return results
    }

    var ordered = [CBORLDBatchOutcome<Output>?](repeating: nil, count: inputs.count)
    let cap = min(policy.maximumConcurrentTasks, inputs.count)
    try await withThrowingTaskGroup(
      of: (Int, CBORLDBatchOutcome<Output>).self
    ) { group in
      var next = 0
      func submit(_ index: Int) {
        group.addTask(priority: policy.taskPriority) {
          try Task.checkCancellation()
          return (
            index,
            try await perform(
              inputs[index],
              inputByteCount: byteCounts[index],
              inputMeasure: inputMeasure,
              policy: policy,
              outputByteCount: outputByteCount,
              operation: operation)
          )
        }
      }
      while next < cap {
        submit(next)
        next += 1
      }
      while let (index, result) = try await group.next() {
        ordered[index] = result
        if next < inputs.count {
          submit(next)
          next += 1
        }
      }
    }
    return ordered.map { $0! }
  }

  static func perform<Input: Sendable, Output: Sendable>(
    _ input: Input,
    inputByteCount: Int,
    inputMeasure: CBORLDBatchInputMeasure,
    policy: CBORLDExecutionPolicy,
    outputByteCount: @escaping @Sendable (Output) -> (Int, CBORLDBatchOutputMeasure)?,
    operation: @escaping @Sendable (Input) async throws -> Output
  ) async throws -> CBORLDBatchOutcome<Output> {
    let clock = ContinuousClock()
    let started = policy.recordsTiming ? clock.now : nil
    let allocatedBefore = policy.allocationByteCounter?()
    do {
      let value = try await operation(input)
      try Task.checkCancellation()
      let allocatedAfter = policy.allocationByteCounter?()
      let allocated = allocationDelta(before: allocatedBefore, after: allocatedAfter)
      let duration = started.map { nanoseconds(clock.now - $0) }
      let observation: CBORLDBatchObservation?
      if policy.recordsObservations {
        let output = outputByteCount(value)
        observation = CBORLDBatchObservation(
          durationNanoseconds: duration,
          inputByteCount: inputByteCount,
          inputMeasure: inputMeasure,
          outputByteCount: output?.0,
          outputMeasure: output?.1,
          allocatedByteCount: allocated)
      } else {
        observation = nil
      }
      return .success(value: value, observation: observation)
    } catch is CancellationError {
      throw CancellationError()
    } catch let error as CBORLDError {
      return .failure(
        .init(code: error.code, message: error.message, diagnostic: error.diagnostic))
    } catch {
      return .failure(
        .init(code: .batchItem, message: String(describing: error), diagnostic: nil))
    }
  }

  static func validate(_ policy: CBORLDExecutionPolicy) throws {
    guard policy.maximumConcurrentTasks > 0,
      policy.minimumParallelDocumentCount >= 0,
      policy.minimumParallelBytes >= 0,
      policy.cancellationCheckStride > 0,
      policy.maximumDocumentCount >= 0,
      policy.maximumTotalInputBytes >= 0
    else {
      throw CBORLDError(
        code: .invalidExecutionPolicy,
        message:
          "Batch execution counts, limits, and stride must be positive or zero as documented.")
    }
  }

  static func account(
    inputByteCount: Int,
    nextDocumentCount: Int,
    totalBytes: inout Int,
    policy: CBORLDExecutionPolicy
  ) throws {
    guard nextDocumentCount <= policy.maximumDocumentCount else {
      throw batchLimit("Batch exceeds \(policy.maximumDocumentCount) documents.")
    }
    guard inputByteCount >= 0,
      totalBytes <= policy.maximumTotalInputBytes - inputByteCount
    else {
      throw batchLimit("Batch input exceeds \(policy.maximumTotalInputBytes) bytes.")
    }
    totalBytes += inputByteCount
  }

  private static func allocationDelta(before: UInt64?, after: UInt64?) -> UInt64? {
    guard let before, let after, after >= before else { return nil }
    return after - before
  }

  private static func nanoseconds(_ duration: Duration) -> UInt64 {
    let components = duration.components
    let seconds = UInt64(max(0, components.seconds))
    let attoseconds = UInt64(max(0, components.attoseconds))
    let whole = seconds.multipliedReportingOverflow(by: 1_000_000_000)
    guard !whole.overflow else { return .max }
    return whole.partialValue &+ attoseconds / 1_000_000_000
  }

  private static func batchLimit(_ message: String) -> CBORLDError {
    .init(code: .batchLimit, message: message)
  }
}
