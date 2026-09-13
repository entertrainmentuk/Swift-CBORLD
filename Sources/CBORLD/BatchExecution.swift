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
    allocationByteCounter: (@Sendable () -> UInt64?)? = nil
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
  }
}

public struct CBORLDBatchObservation: Sendable, Hashable, Codable {
  public let durationNanoseconds: UInt64?
  public let inputByteCount: Int
  public let outputByteCount: Int?
  public let allocatedByteCount: UInt64?
}

public struct CBORLDBatchFailure: Error, Sendable, Hashable, Codable {
  public let code: String
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

extension CBORLDPreparedEncoder {
  /// Encodes independent documents with bounded concurrency and stable output
  /// ordering. One failed document does not discard successful siblings.
  public func encodeBatch(
    _ documents: [JSONValue],
    policy: CBORLDExecutionPolicy = .init()
  ) async throws -> [CBORLDBatchOutcome<Data>] {
    let byteCounts = try documents.map { try $0.data().count }
    return try await CBORLDBatchExecutor.execute(
      inputs: documents,
      byteCounts: byteCounts,
      policy: policy,
      outputByteCount: { $0.count },
      operation: { try await self.encode($0) })
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
      policy: policy,
      outputByteCount: { value in try? value.data().count },
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
    try CBORLDBatchExecutor.validate(policy)
    var iterator = documents.makeAsyncIterator()
    var nextIndex = 0
    var totalBytes = 0
    var ordered: [Int: CBORLDBatchOutcome<JSONValue>] = [:]
    let cap = policy.backendAlreadyParallel ? 1 : policy.maximumConcurrentTasks
    var inFlight = 0

    try await withThrowingTaskGroup(
      of: (Int, CBORLDBatchOutcome<JSONValue>).self
    ) { group in
      func submit(_ input: Data, at index: Int) {
        group.addTask(priority: policy.taskPriority) {
          try Task.checkCancellation()
          return (
            index,
            try await CBORLDBatchExecutor.perform(
              input,
              inputByteCount: input.count,
              policy: policy,
              outputByteCount: { value in try? value.data().count },
              operation: { try await self.decode($0) })
          )
        }
      }

      while inFlight < cap, let input = try await iterator.next() {
        try CBORLDBatchExecutor.account(
          inputByteCount: input.count,
          nextDocumentCount: nextIndex + 1,
          totalBytes: &totalBytes,
          policy: policy)
        submit(input, at: nextIndex)
        nextIndex += 1
        inFlight += 1
      }

      while let (index, result) = try await group.next() {
        inFlight -= 1
        ordered[index] = result
        if nextIndex.isMultiple(of: policy.cancellationCheckStride) {
          try Task.checkCancellation()
        }
        if let input = try await iterator.next() {
          try CBORLDBatchExecutor.account(
            inputByteCount: input.count,
            nextDocumentCount: nextIndex + 1,
            totalBytes: &totalBytes,
            policy: policy)
          submit(input, at: nextIndex)
          nextIndex += 1
          inFlight += 1
        }
      }
    }
    return (0..<nextIndex).compactMap { ordered[$0] }
  }
}

private enum CBORLDBatchExecutor {
  static func execute<Input: Sendable, Output: Sendable>(
    inputs: [Input],
    byteCounts: [Int],
    policy: CBORLDExecutionPolicy,
    outputByteCount: @escaping @Sendable (Output) -> Int?,
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
    policy: CBORLDExecutionPolicy,
    outputByteCount: @escaping @Sendable (Output) -> Int?,
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
      let observation =
        policy.recordsTiming || policy.allocationByteCounter != nil
        ? CBORLDBatchObservation(
          durationNanoseconds: duration,
          inputByteCount: inputByteCount,
          outputByteCount: outputByteCount(value),
          allocatedByteCount: allocated)
        : nil
      return .success(value: value, observation: observation)
    } catch is CancellationError {
      throw CancellationError()
    } catch let error as CBORLDError {
      return .failure(
        .init(code: error.code, message: error.message, diagnostic: error.diagnostic))
    } catch {
      return .failure(
        .init(code: "ERR_BATCH_ITEM", message: String(describing: error), diagnostic: nil))
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
        code: "ERR_INVALID_EXECUTION_POLICY",
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
    .init(code: "ERR_BATCH_LIMIT", message: message)
  }
}
