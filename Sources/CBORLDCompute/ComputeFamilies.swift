import CBORLD
import Foundation

/// Stable identifiers for CBOR-LD-oriented compute families. These identifiers
/// are suitable for catalogue and MCP interchange; they do not claim that a
/// particular accelerator backend implements the family.
public enum CBORLDComputeFamilyID: String, Sendable, Hashable, Codable, CaseIterable {
  case batchedSHA256 = "cborld.batched-sha256.v1"
  case byteDiff = "cborld.byte-diff.v1"
  case structuralScan = "cborld.cbor-structural-scan.v1"
  case prefixScan = "cborld.uint-prefix-scan.v1"
  case byteCompaction = "cborld.byte-compaction.v1"
  case byteStatistics = "cborld.byte-statistics.v1"
  case canonicalKeyOrdering = "cborld.canonical-key-ordering.v1"
  case utf8Validation = "cborld.utf8-validation.v1"
  case multibaseCodec = "cborld.multibase-codec.v1"
  case unsignedVarint = "cborld.unsigned-varint.v1"
  case dictionaryProbe = "cborld.dictionary-probe.v1"
  case wholeDocumentTransform = "cborld.whole-document-transform.v1"
  case cddlValidation = "cborld.cddl-validation.v1"
}

public enum CBORLDComputeFamilyPriority: String, Sendable, Hashable, Codable, CaseIterable {
  case high
  case medium
  case low
}

public enum CBORLDComputeCPUReferenceKind: String, Sendable, Hashable, Codable, CaseIterable {
  /// Implemented directly by `CBORLDCPUComputeProvider`.
  case inPackage = "in-package"
  /// Delegates to the package's existing CBOR-LD processor.
  case existingProcessor = "existing-processor"
  /// Requires an explicitly injected independent CPU oracle.
  case injectedOracle = "injected-oracle"
}

public enum CBORLDComputeFamilyAvailability: String, Sendable, Hashable, Codable, CaseIterable {
  case available
  case unavailable
}

/// Runtime discovery metadata for MCP and backend adapters. Constraints are
/// deliberately string keyed so an adapter can publish backend-specific limits
/// without coupling this package to SemanticCompute implementation types.
public struct CBORLDComputeFamilyCapability: Sendable, Codable {
  public let id: CBORLDComputeFamilyID
  public let availability: CBORLDComputeFamilyAvailability
  public let implementation: String
  public let constraints: [String: String]

  public init(
    id: CBORLDComputeFamilyID,
    availability: CBORLDComputeFamilyAvailability,
    implementation: String,
    constraints: [String: String] = [:]
  ) {
    self.id = id
    self.availability = availability
    self.implementation = implementation
    self.constraints = constraints
  }
}

public protocol CBORLDComputeCapabilityReporting: Sendable {
  var cborldComputeCapabilities: [CBORLDComputeFamilyCapability] { get }
}

/// Backend-neutral catalogue metadata that SC and MCP adapters can expose
/// without importing implementation-specific dispatch types.
public struct CBORLDComputeFamilyContract: Sendable, Hashable, Codable {
  public let id: CBORLDComputeFamilyID
  public let priority: CBORLDComputeFamilyPriority
  public let workItem: String
  public let exactSemantics: String
  public let cpuReference: CBORLDComputeCPUReferenceKind

  public init(
    id: CBORLDComputeFamilyID,
    priority: CBORLDComputeFamilyPriority,
    workItem: String,
    exactSemantics: String,
    cpuReference: CBORLDComputeCPUReferenceKind = .inPackage
  ) {
    self.id = id
    self.priority = priority
    self.workItem = workItem
    self.exactSemantics = exactSemantics
    self.cpuReference = cpuReference
  }
}

extension CBORLDComputeFamilyContract {
  /// The CPU-side semantic catalogue. `cpuReference` distinguishes direct code,
  /// the existing processor, and an injected oracle; none establishes that an
  /// accelerator lowering exists.
  public static let cborldCPUReferences: [Self] = [
    .init(
      id: .batchedSHA256,
      priority: .high,
      workItem: "one independent byte slice",
      exactSemantics: "FIPS 180-4 SHA-256 using UInt32 modular state"),
    .init(
      id: .byteDiff,
      priority: .high,
      workItem: "one pair of independent byte slices",
      exactSemantics:
        "count differing positions plus every excess tail byte and return the lowest offset"),
    .init(
      id: .structuralScan,
      priority: .high,
      workItem: "one independent CBOR document",
      exactSemantics:
        "syntax validity, deterministic first error offset, root-zero depth, and logical item count"
    ),
    .init(
      id: .prefixScan,
      priority: .high,
      workItem: "one UInt32 or UInt64 sequence",
      exactSemantics: "exclusive scan with checked overflow and no wrapping fallback"),
    .init(
      id: .byteCompaction,
      priority: .high,
      workItem: "one ordered batch of byte slices",
      exactSemantics: "stable concatenation with n plus one exact UInt64 boundary offsets"),
    .init(
      id: .byteStatistics,
      priority: .medium,
      workItem: "one independent byte slice",
      exactSemantics: "256 exact UInt64 bins whose sum equals byte count, plus Shannon entropy"),
    .init(
      id: .canonicalKeyOrdering,
      priority: .medium,
      workItem: "one independent segment of encoded CBOR keys",
      exactSemantics: "stable RFC 8949 length-first or bytewise ordering over encoded key bytes"),
    .init(
      id: .utf8Validation,
      priority: .medium,
      workItem: "one independent byte slice",
      exactSemantics:
        "reject invalid continuation, overlong, surrogate, out-of-range, and truncated sequences"),
    .init(
      id: .multibaseCodec,
      priority: .medium,
      workItem: "one bounded independent multibase value",
      exactSemantics:
        "z, u, and M encodings with leading-zero preservation and exact invalid-byte offsets"),
    .init(
      id: .unsignedVarint,
      priority: .low,
      workItem: "one independent UInt64 or encoded legacy varint",
      exactSemantics:
        "unsigned LEB128 with complete-input, termination, and checked UInt64 overflow rules"),
    .init(
      id: .dictionaryProbe,
      priority: .low,
      workItem: "one lookup in one immutable pinned dictionary",
      exactSemantics:
        "exact JSONValue lookup after dictionary validation and fingerprint verification"),
    .init(
      id: .wholeDocumentTransform,
      priority: .low,
      workItem: "one bounded JSON-LD document or CBOR-LD byte string",
      exactSemantics:
        "asynchronous encode or decode with materialized or fingerprint-pinned contexts and dictionaries",
      cpuReference: .existingProcessor
    ),
    .init(
      id: .cddlValidation,
      priority: .low,
      workItem: "one bounded schema and one bounded CBOR or JSON document",
      exactSemantics:
        "grammar and document validity with bounded AST metrics and byte-addressed diagnostics",
      cpuReference: .injectedOracle),
  ]
}

/// UInt32-packed byte spans matching the dense buffer form used by SC kernels.
public struct CBORLDComputeByteSpan: Sendable, Hashable, Codable {
  public let offset: UInt32
  public let length: UInt32

  public init(offset: UInt32, length: UInt32) {
    self.offset = offset
    self.length = length
  }
}

/// A transport-independent bridge from Swift byte slices to SC's exact
/// `UInt32` byte and span buffers. Each word in `bytes` must be in 0...255.
public struct CBORLDComputePackedByteBatch: Sendable, Hashable, Codable {
  public let bytes: [UInt32]
  public let spans: [CBORLDComputeByteSpan]

  public init(bytes: [UInt32], spans: [CBORLDComputeByteSpan]) throws {
    self.bytes = bytes
    self.spans = spans
    try validate()
  }

  public init(slices: [Data]) throws {
    var bytes: [UInt32] = []
    var spans: [CBORLDComputeByteSpan] = []
    var totalByteCount: UInt64 = 0
    for slice in slices {
      let addition = totalByteCount.addingReportingOverflow(UInt64(slice.count))
      guard !addition.overflow else {
        throw CBORLDError(
          code: .resourceLimit,
          message: "Packed byte batch size overflowed UInt64.")
      }
      totalByteCount = addition.partialValue
    }
    guard totalByteCount <= UInt64(UInt32.max), UInt64(slices.count) <= UInt64(UInt32.max) else {
      throw CBORLDError(
        code: .resourceLimit,
        message: "Packed byte batches must fit the UInt32 execution ABI.")
    }
    bytes.reserveCapacity(Int(totalByteCount))
    spans.reserveCapacity(slices.count)
    for slice in slices {
      spans.append(.init(offset: UInt32(bytes.count), length: UInt32(slice.count)))
      bytes.append(contentsOf: slice.map(UInt32.init))
    }
    self.bytes = bytes
    self.spans = spans
  }

  public func validate() throws {
    guard bytes.allSatisfy({ $0 <= UInt32(UInt8.max) }) else {
      throw CBORLDError.invalidInput("Packed byte buffers may contain only values in 0...255.")
    }
    for span in spans {
      let end = UInt64(span.offset) + UInt64(span.length)
      guard end <= UInt64(bytes.count) else {
        throw CBORLDError.invalidInput("Packed byte span is outside its byte buffer.")
      }
    }
  }

  public func slices() throws -> [Data] {
    try validate()
    return spans.map { span in
      let start = Int(span.offset)
      let end = start + Int(span.length)
      return Data(bytes[start..<end].map(UInt8.init))
    }
  }
}

/// A CPU SHA-256 result. `stateWords` contains the eight final SHA-256 state
/// words in digest order; `digest.bytes` is their big-endian serialization.
public struct CBORLDSHA256Result: Sendable, Hashable, Codable {
  public let inputByteCount: Int
  public let stateWords: [UInt32]
  public let digest: CBORLDDigest

  public init(inputByteCount: Int, stateWords: [UInt32], digest: CBORLDDigest) {
    self.inputByteCount = inputByteCount
    self.stateWords = stateWords
    self.digest = digest
  }

  /// Checks the backend-neutral shape of an accelerator result. This does not
  /// recompute SHA-256; exact CPU/backend parity belongs in the SC doctor.
  public func validate(expectedInputByteCount: Int) throws {
    guard inputByteCount == expectedInputByteCount, inputByteCount >= 0 else {
      throw invalidComputeOutput("SHA-256 input byte count does not match its work item.")
    }
    guard stateWords.count == 8 else {
      throw invalidComputeOutput("SHA-256 output must contain exactly eight UInt32 state words.")
    }
    guard digest.algorithm == .sha256,
      digest.domain == .encodedBytes,
      digest.version == 1
    else {
      throw invalidComputeOutput("SHA-256 output contains incompatible digest metadata.")
    }
    var expectedBytes = Data(capacity: 32)
    for word in stateWords {
      var bigEndian = word.bigEndian
      withUnsafeBytes(of: &bigEndian) { expectedBytes.append(contentsOf: $0) }
    }
    guard digest.bytes == expectedBytes else {
      throw invalidComputeOutput("SHA-256 state words and digest bytes disagree.")
    }
  }
}

public struct CBORLDBytePair: Sendable, Hashable, Codable {
  public let left: Data
  public let right: Data

  public init(_ left: Data, _ right: Data) {
    self.left = left
    self.right = right
  }
}

/// Exact byte-comparison result. Every byte beyond the shorter input counts as
/// one mismatch. If equal prefixes have unequal lengths, the first mismatch is
/// the shorter input's byte count.
public struct CBORLDByteDiffResult: Sendable, Hashable, Codable {
  public let leftByteCount: Int
  public let rightByteCount: Int
  public let mismatchCount: UInt64
  public let firstMismatchOffset: Int?

  public init(
    leftByteCount: Int,
    rightByteCount: Int,
    mismatchCount: UInt64,
    firstMismatchOffset: Int?
  ) {
    self.leftByteCount = leftByteCount
    self.rightByteCount = rightByteCount
    self.mismatchCount = mismatchCount
    self.firstMismatchOffset = firstMismatchOffset
  }

  public func validate(expectedLeftByteCount: Int, expectedRightByteCount: Int) throws {
    guard leftByteCount == expectedLeftByteCount, rightByteCount == expectedRightByteCount else {
      throw invalidComputeOutput("Byte-diff input sizes do not match their work item.")
    }
    let maximumCount = max(leftByteCount, rightByteCount)
    guard mismatchCount <= UInt64(maximumCount) else {
      throw invalidComputeOutput("Byte-diff mismatch count exceeds the longest input.")
    }
    if mismatchCount == 0 {
      guard firstMismatchOffset == nil else {
        throw invalidComputeOutput("An equal byte pair must not report a mismatch offset.")
      }
    } else {
      guard let firstMismatchOffset,
        firstMismatchOffset >= 0,
        firstMismatchOffset < maximumCount
      else {
        throw invalidComputeOutput("A differing byte pair must report an in-range first offset.")
      }
    }
  }
}

/// Syntax-only CBOR scan metrics. Root depth is zero; array elements, map keys
/// and values, and tagged values add one level. A tag and its value are both
/// counted as items. Indefinite string chunks and break markers are not.
public struct CBORLDStructuralScanResult: Sendable, Hashable, Codable {
  public let byteCount: Int
  public let isValid: Bool
  public let firstErrorOffset: Int?
  public let maximumDepth: Int
  public let itemCount: UInt64
  public let errorCode: CBORLDErrorCode?
  public let message: String?

  public init(
    byteCount: Int,
    isValid: Bool,
    firstErrorOffset: Int?,
    maximumDepth: Int,
    itemCount: UInt64,
    errorCode: CBORLDErrorCode?,
    message: String?
  ) {
    self.byteCount = byteCount
    self.isValid = isValid
    self.firstErrorOffset = firstErrorOffset
    self.maximumDepth = maximumDepth
    self.itemCount = itemCount
    self.errorCode = errorCode
    self.message = message
  }

  public func validate(expectedByteCount: Int) throws {
    guard byteCount == expectedByteCount, byteCount >= 0, maximumDepth >= 0 else {
      throw invalidComputeOutput("CBOR scan metrics do not match their work item.")
    }
    if isValid {
      guard firstErrorOffset == nil, errorCode == nil, message == nil, itemCount > 0 else {
        throw invalidComputeOutput("A valid CBOR scan contains contradictory error metadata.")
      }
    } else {
      guard let firstErrorOffset,
        firstErrorOffset >= 0,
        firstErrorOffset <= byteCount,
        errorCode != nil,
        message != nil
      else {
        throw invalidComputeOutput("An invalid CBOR scan lacks bounded error metadata.")
      }
    }
  }
}

public struct CBORLDExclusiveScanUInt32Result: Sendable, Hashable, Codable {
  public let offsets: [UInt32]
  public let total: UInt32

  public init(offsets: [UInt32], total: UInt32) {
    self.offsets = offsets
    self.total = total
  }

  public func validate(input: [UInt32]) throws {
    guard offsets.count == input.count else {
      throw invalidComputeOutput("UInt32 scan returned the wrong number of offsets.")
    }
    var expected: UInt32 = 0
    for index in input.indices {
      guard offsets[index] == expected else {
        throw invalidComputeOutput("UInt32 scan offsets are not an exact exclusive prefix sum.")
      }
      let addition = expected.addingReportingOverflow(input[index])
      guard !addition.overflow else {
        throw invalidComputeOutput("UInt32 scan accepted an overflowing input.")
      }
      expected = addition.partialValue
    }
    guard total == expected else {
      throw invalidComputeOutput("UInt32 scan total does not match its offsets.")
    }
  }
}

public struct CBORLDExclusiveScanUInt64Result: Sendable, Hashable, Codable {
  public let offsets: [UInt64]
  public let total: UInt64

  public init(offsets: [UInt64], total: UInt64) {
    self.offsets = offsets
    self.total = total
  }

  public func validate(input: [UInt64]) throws {
    guard offsets.count == input.count else {
      throw invalidComputeOutput("UInt64 scan returned the wrong number of offsets.")
    }
    var expected: UInt64 = 0
    for index in input.indices {
      guard offsets[index] == expected else {
        throw invalidComputeOutput("UInt64 scan offsets are not an exact exclusive prefix sum.")
      }
      let addition = expected.addingReportingOverflow(input[index])
      guard !addition.overflow else {
        throw invalidComputeOutput("UInt64 scan accepted an overflowing input.")
      }
      expected = addition.partialValue
    }
    guard total == expected else {
      throw invalidComputeOutput("UInt64 scan total does not match its offsets.")
    }
  }
}

/// Packed bytes and `n + 1` offsets. Slice `i` occupies
/// `bytes[offsets[i]..<offsets[i + 1]]`.
public struct CBORLDByteCompactionResult: Sendable, Hashable, Codable {
  public let offsets: [UInt64]
  public let bytes: Data

  public init(offsets: [UInt64], bytes: Data) {
    self.offsets = offsets
    self.bytes = bytes
  }

  public func validate(input: [Data]) throws {
    guard offsets.count == input.count + 1, offsets.first == 0,
      offsets.last == UInt64(bytes.count)
    else {
      throw invalidComputeOutput("Byte compaction requires n plus one complete boundary offsets.")
    }
    for index in input.indices {
      let start = offsets[index]
      let end = offsets[index + 1]
      guard start <= end, end <= UInt64(bytes.count), end - start == UInt64(input[index].count)
      else {
        throw invalidComputeOutput("Byte compaction boundaries do not match their input slices.")
      }
      guard Data(bytes[Int(start)..<Int(end)]) == input[index] else {
        throw invalidComputeOutput("Byte compaction changed an input slice.")
      }
    }
  }
}

/// An exact 256-bin byte histogram plus derived Shannon entropy. Counts are
/// integral and always sum to `byteCount`; entropy is measured in bits/byte.
public struct CBORLDByteStatistics: Sendable, Hashable, Codable {
  public let byteCount: UInt64
  public let histogram: [UInt64]
  public let shannonEntropyBitsPerByte: Double

  public init(
    byteCount: UInt64,
    histogram: [UInt64],
    shannonEntropyBitsPerByte: Double
  ) {
    self.byteCount = byteCount
    self.histogram = histogram
    self.shannonEntropyBitsPerByte = shannonEntropyBitsPerByte
  }

  public func validate(expectedByteCount: Int) throws {
    guard expectedByteCount >= 0, byteCount == UInt64(expectedByteCount), histogram.count == 256,
      shannonEntropyBitsPerByte.isFinite,
      (0...8).contains(shannonEntropyBitsPerByte)
    else {
      throw invalidComputeOutput("Byte statistics have incompatible count, bins, or entropy.")
    }
    var total: UInt64 = 0
    for count in histogram {
      let addition = total.addingReportingOverflow(count)
      guard !addition.overflow else {
        throw invalidComputeOutput("Byte histogram count overflowed UInt64.")
      }
      total = addition.partialValue
    }
    guard total == byteCount else {
      throw invalidComputeOutput("Byte histogram bins do not sum to the input byte count.")
    }
    if byteCount == 0, shannonEntropyBitsPerByte != 0 {
      throw invalidComputeOutput("An empty byte slice must have zero entropy.")
    }
  }
}

public enum CBORLDCanonicalKeyOrdering: String, Sendable, Hashable, Codable, CaseIterable {
  /// RFC 8949 section 4.2.3: encoded length, then encoded bytes.
  case lengthFirst
  /// RFC 8949 section 4.2.1: encoded bytes only.
  case bytewise
}

/// Original key indices in canonical order, one result per input segment.
public struct CBORLDCanonicalKeyOrderResult: Sendable, Hashable, Codable {
  public let orderedIndices: [Int]

  public init(orderedIndices: [Int]) {
    self.orderedIndices = orderedIndices
  }

  public func validate(keyCount: Int) throws {
    guard orderedIndices.count == keyCount,
      Set(orderedIndices) == Set(0..<keyCount)
    else {
      throw invalidComputeOutput(
        "Canonical key ordering must return one permutation of all indices.")
    }
  }
}

public struct CBORLDUTF8ValidationResult: Sendable, Hashable, Codable {
  public let byteCount: Int
  public let isValid: Bool
  /// Offset of the invalid byte. A truncated sequence reports its lead byte.
  public let firstInvalidByteOffset: Int?

  public init(byteCount: Int, isValid: Bool, firstInvalidByteOffset: Int?) {
    self.byteCount = byteCount
    self.isValid = isValid
    self.firstInvalidByteOffset = firstInvalidByteOffset
  }

  public func validate(expectedByteCount: Int) throws {
    guard byteCount == expectedByteCount, byteCount >= 0 else {
      throw invalidComputeOutput("UTF-8 validation byte count does not match its input.")
    }
    if isValid {
      guard firstInvalidByteOffset == nil else {
        throw invalidComputeOutput("Valid UTF-8 must not report an invalid byte offset.")
      }
    } else {
      guard let firstInvalidByteOffset,
        firstInvalidByteOffset >= 0,
        firstInvalidByteOffset < byteCount
      else {
        throw invalidComputeOutput("Invalid UTF-8 must report an in-range byte offset.")
      }
    }
  }
}

public enum CBORLDMultibaseEncoding: String, Sendable, Hashable, Codable, CaseIterable {
  case base58BTC = "z"
  case base64URL = "u"
  case base64 = "M"
}

public struct CBORLDMultibaseDecodeResult: Sendable, Hashable, Codable {
  public let input: String
  public let decoded: Data?
  /// UTF-8 byte offset in the ASCII multibase input.
  public let firstInvalidByteOffset: Int?
  public let message: String?

  public init(
    input: String,
    decoded: Data?,
    firstInvalidByteOffset: Int?,
    message: String?
  ) {
    self.input = input
    self.decoded = decoded
    self.firstInvalidByteOffset = firstInvalidByteOffset
    self.message = message
  }

  public func validate(expectedInput: String) throws {
    guard input == expectedInput else {
      throw invalidComputeOutput("Multibase result does not echo its input.")
    }
    if decoded != nil {
      guard firstInvalidByteOffset == nil, message == nil else {
        throw invalidComputeOutput(
          "Decoded multibase output contains contradictory error metadata.")
      }
    } else {
      guard let firstInvalidByteOffset,
        firstInvalidByteOffset >= 0,
        firstInvalidByteOffset <= input.utf8.count,
        let message,
        !message.isEmpty
      else {
        throw invalidComputeOutput("Invalid multibase output lacks bounded error metadata.")
      }
    }
  }
}

public struct CBORLDUnsignedVarintDecodeResult: Sendable, Hashable, Codable {
  public let value: UInt64?
  public let bytesConsumed: Int
  public let firstErrorOffset: Int?
  public let message: String?

  public init(
    value: UInt64?,
    bytesConsumed: Int,
    firstErrorOffset: Int?,
    message: String?
  ) {
    self.value = value
    self.bytesConsumed = bytesConsumed
    self.firstErrorOffset = firstErrorOffset
    self.message = message
  }

  public func validate(expectedByteCount: Int) throws {
    guard bytesConsumed >= 0, bytesConsumed <= expectedByteCount else {
      throw invalidComputeOutput("Unsigned varint consumed an impossible byte count.")
    }
    if value != nil {
      guard bytesConsumed == expectedByteCount, firstErrorOffset == nil, message == nil else {
        throw invalidComputeOutput("Decoded unsigned varint contains contradictory error metadata.")
      }
    } else {
      guard let firstErrorOffset,
        firstErrorOffset >= 0,
        firstErrorOffset <= expectedByteCount,
        let message,
        !message.isEmpty
      else {
        throw invalidComputeOutput("Invalid unsigned varint lacks bounded error metadata.")
      }
    }
  }
}

public struct CBORLDDictionaryProbe: Sendable, Hashable, Codable {
  public let table: String
  public let value: JSONValue

  public init(table: String, value: JSONValue) {
    self.table = table
    self.value = value
  }
}

public struct CBORLDDictionaryProbeResult: Sendable, Hashable, Codable {
  public let table: String
  public let value: JSONValue
  public let identifier: UInt64?

  public init(table: String, value: JSONValue, identifier: UInt64?) {
    self.table = table
    self.value = value
    self.identifier = identifier
  }

  public func validate(expected: CBORLDDictionaryProbe) throws {
    guard table == expected.table, value == expected.value else {
      throw invalidComputeOutput("Dictionary probe result does not echo its work item.")
    }
    if let identifier, identifier > cborldMaximumSafeInteger {
      throw invalidComputeOutput(
        "Dictionary probe identifier exceeds the CBOR-LD safe-integer limit.")
    }
  }
}

// Granular protocols let SemanticCompute adopt families independently instead
// of requiring every backend to implement the whole expansion at once.
public protocol CBORLDBatchedSHA256Computing: Sendable {
  func batchedSHA256(_ slices: [Data]) async throws -> [CBORLDSHA256Result]
}

public protocol CBORLDByteDiffComputing: Sendable {
  func batchedByteDiff(_ pairs: [CBORLDBytePair]) async throws -> [CBORLDByteDiffResult]
}

public protocol CBORLDStructuralScanComputing: Sendable {
  func batchedCBORStructuralScan(
    _ documents: [Data],
    limits: CBORLDDecodingLimits
  ) async throws -> [CBORLDStructuralScanResult]
}

public protocol CBORLDPrefixScanComputing: Sendable {
  func exclusiveScanUInt32(_ values: [UInt32]) async throws -> CBORLDExclusiveScanUInt32Result
  func exclusiveScanUInt64(_ values: [UInt64]) async throws -> CBORLDExclusiveScanUInt64Result
  func compactByteSlices(_ slices: [Data]) async throws -> CBORLDByteCompactionResult
}

public protocol CBORLDByteStatisticsComputing: Sendable {
  func batchedByteStatistics(_ slices: [Data]) async throws -> [CBORLDByteStatistics]
}

public protocol CBORLDCanonicalKeyOrderingComputing: Sendable {
  func segmentedCanonicalKeyOrder(
    _ segments: [[Data]],
    ordering: CBORLDCanonicalKeyOrdering
  ) async throws -> [CBORLDCanonicalKeyOrderResult]
}

public protocol CBORLDUTF8ValidationComputing: Sendable {
  func batchedUTF8Validation(_ slices: [Data]) async throws -> [CBORLDUTF8ValidationResult]
}

public protocol CBORLDMultibaseComputing: Sendable {
  func batchedMultibaseEncode(
    _ values: [Data],
    as encoding: CBORLDMultibaseEncoding,
    maximumInputBytes: Int
  ) async throws -> [String]
  func batchedMultibaseDecode(
    _ values: [String],
    maximumInputBytes: Int
  ) async throws -> [CBORLDMultibaseDecodeResult]
}

public protocol CBORLDUnsignedVarintComputing: Sendable {
  func batchedUnsignedVarintEncode(_ values: [UInt64]) async throws -> [Data]
  func batchedUnsignedVarintDecode(
    _ values: [Data]
  ) async throws -> [CBORLDUnsignedVarintDecodeResult]
}

public protocol CBORLDDictionaryProbeComputing: Sendable {
  func batchedDictionaryProbe(
    _ probes: [CBORLDDictionaryProbe],
    dictionary: CBORLDDocumentDictionary,
    requiredFingerprint: CBORLDDigest
  ) async throws -> [CBORLDDictionaryProbeResult]
}

public protocol CBORLDComputeProvider:
  CBORLDComputeCapabilityReporting,
  CBORLDBatchedSHA256Computing,
  CBORLDByteDiffComputing,
  CBORLDStructuralScanComputing,
  CBORLDPrefixScanComputing,
  CBORLDByteStatisticsComputing,
  CBORLDCanonicalKeyOrderingComputing,
  CBORLDUTF8ValidationComputing,
  CBORLDMultibaseComputing,
  CBORLDUnsignedVarintComputing,
  CBORLDDictionaryProbeComputing,
  CBORLDWholeDocumentTransformComputing,
  CBORLDCDDLValidationComputing
{}

extension CBORLD {
  /// Runs an injected SHA-256 family and rejects structurally inconsistent
  /// backend output before returning transport digests to the caller.
  public static func batchedTransportDigests<Provider: CBORLDBatchedSHA256Computing>(
    of slices: [Data],
    using provider: Provider
  ) async throws -> [CBORLDDigest] {
    let results = try await provider.batchedSHA256(slices)
    guard results.count == slices.count else {
      throw invalidComputeOutput("SHA-256 backend returned the wrong number of work items.")
    }
    for index in slices.indices {
      try results[index].validate(expectedInputByteCount: slices[index].count)
    }
    return results.map(\.digest)
  }

  /// Runs an injected byte-diff family and validates result cardinality and
  /// bounds. Exact CPU/backend parity remains an SC doctor responsibility.
  public static func batchedByteDiff<Provider: CBORLDByteDiffComputing>(
    _ pairs: [CBORLDBytePair],
    using provider: Provider
  ) async throws -> [CBORLDByteDiffResult] {
    let results = try await provider.batchedByteDiff(pairs)
    guard results.count == pairs.count else {
      throw invalidComputeOutput("Byte-diff backend returned the wrong number of work items.")
    }
    for index in pairs.indices {
      try results[index].validate(
        expectedLeftByteCount: pairs[index].left.count,
        expectedRightByteCount: pairs[index].right.count)
    }
    return results
  }

  /// Runs an injected structural scanner and rejects contradictory or
  /// out-of-range result metadata before exposing it to callers.
  public static func batchedCBORStructuralScan<Provider: CBORLDStructuralScanComputing>(
    _ documents: [Data],
    limits: CBORLDDecodingLimits = .init(),
    using provider: Provider
  ) async throws -> [CBORLDStructuralScanResult] {
    let results = try await provider.batchedCBORStructuralScan(documents, limits: limits)
    guard results.count == documents.count else {
      throw invalidComputeOutput("CBOR scanner returned the wrong number of work items.")
    }
    for index in documents.indices {
      try results[index].validate(expectedByteCount: documents[index].count)
    }
    return results
  }

  public static func exclusiveScanUInt32<Provider: CBORLDPrefixScanComputing>(
    _ values: [UInt32],
    using provider: Provider
  ) async throws -> CBORLDExclusiveScanUInt32Result {
    let result = try await provider.exclusiveScanUInt32(values)
    try result.validate(input: values)
    return result
  }

  public static func exclusiveScanUInt64<Provider: CBORLDPrefixScanComputing>(
    _ values: [UInt64],
    using provider: Provider
  ) async throws -> CBORLDExclusiveScanUInt64Result {
    let result = try await provider.exclusiveScanUInt64(values)
    try result.validate(input: values)
    return result
  }

  public static func compactByteSlices<Provider: CBORLDPrefixScanComputing>(
    _ slices: [Data],
    using provider: Provider
  ) async throws -> CBORLDByteCompactionResult {
    let result = try await provider.compactByteSlices(slices)
    try result.validate(input: slices)
    return result
  }

  public static func batchedByteStatistics<Provider: CBORLDByteStatisticsComputing>(
    _ slices: [Data],
    using provider: Provider
  ) async throws -> [CBORLDByteStatistics] {
    let results = try await provider.batchedByteStatistics(slices)
    guard results.count == slices.count else {
      throw invalidComputeOutput("Byte statistics backend returned the wrong number of work items.")
    }
    for index in slices.indices {
      try results[index].validate(expectedByteCount: slices[index].count)
    }
    return results
  }

  public static func segmentedCanonicalKeyOrder<Provider: CBORLDCanonicalKeyOrderingComputing>(
    _ segments: [[Data]],
    ordering: CBORLDCanonicalKeyOrdering,
    using provider: Provider
  ) async throws -> [CBORLDCanonicalKeyOrderResult] {
    let results = try await provider.segmentedCanonicalKeyOrder(segments, ordering: ordering)
    guard results.count == segments.count else {
      throw invalidComputeOutput("Canonical ordering backend returned the wrong segment count.")
    }
    for index in segments.indices { try results[index].validate(keyCount: segments[index].count) }
    return results
  }

  public static func batchedUTF8Validation<Provider: CBORLDUTF8ValidationComputing>(
    _ slices: [Data],
    using provider: Provider
  ) async throws -> [CBORLDUTF8ValidationResult] {
    let results = try await provider.batchedUTF8Validation(slices)
    guard results.count == slices.count else {
      throw invalidComputeOutput("UTF-8 backend returned the wrong number of work items.")
    }
    for index in slices.indices {
      try results[index].validate(expectedByteCount: slices[index].count)
    }
    return results
  }

  public static func batchedMultibaseEncode<Provider: CBORLDMultibaseComputing>(
    _ values: [Data],
    as encoding: CBORLDMultibaseEncoding,
    maximumInputBytes: Int = 1_048_576,
    using provider: Provider
  ) async throws -> [String] {
    guard maximumInputBytes >= 0,
      values.allSatisfy({ $0.count <= maximumInputBytes })
    else {
      throw CBORLDError.invalidInput("Multibase inputs must fit a non-negative byte limit.")
    }
    let results = try await provider.batchedMultibaseEncode(
      values,
      as: encoding,
      maximumInputBytes: maximumInputBytes)
    guard results.count == values.count else {
      throw invalidComputeOutput("Multibase encoder returned the wrong number of work items.")
    }
    for result in results {
      guard result.utf8.first == encoding.rawValue.utf8.first,
        result.utf8.allSatisfy({ $0 < 0x80 })
      else {
        throw invalidComputeOutput("Multibase encoder returned an incompatible prefix or alphabet.")
      }
    }
    return results
  }

  public static func batchedMultibaseDecode<Provider: CBORLDMultibaseComputing>(
    _ values: [String],
    maximumInputBytes: Int = 1_048_576,
    using provider: Provider
  ) async throws -> [CBORLDMultibaseDecodeResult] {
    guard maximumInputBytes >= 0 else {
      throw CBORLDError.invalidInput("maximumInputBytes must not be negative.")
    }
    let results = try await provider.batchedMultibaseDecode(
      values,
      maximumInputBytes: maximumInputBytes)
    guard results.count == values.count else {
      throw invalidComputeOutput("Multibase decoder returned the wrong number of work items.")
    }
    for index in values.indices { try results[index].validate(expectedInput: values[index]) }
    return results
  }

  public static func batchedUnsignedVarintEncode<Provider: CBORLDUnsignedVarintComputing>(
    _ values: [UInt64],
    using provider: Provider
  ) async throws -> [Data] {
    let results = try await provider.batchedUnsignedVarintEncode(values)
    guard results.count == values.count else {
      throw invalidComputeOutput("Unsigned varint encoder returned the wrong number of work items.")
    }
    for result in results {
      guard (1...10).contains(result.count), result.last.map({ $0 & 0x80 == 0 }) == true,
        result.dropLast().allSatisfy({ $0 & 0x80 != 0 })
      else {
        throw invalidComputeOutput("Unsigned varint encoder returned a malformed value.")
      }
    }
    return results
  }

  public static func batchedUnsignedVarintDecode<Provider: CBORLDUnsignedVarintComputing>(
    _ values: [Data],
    using provider: Provider
  ) async throws -> [CBORLDUnsignedVarintDecodeResult] {
    let results = try await provider.batchedUnsignedVarintDecode(values)
    guard results.count == values.count else {
      throw invalidComputeOutput("Unsigned varint decoder returned the wrong number of work items.")
    }
    for index in values.indices {
      try results[index].validate(expectedByteCount: values[index].count)
    }
    return results
  }

  public static func batchedDictionaryProbe<Provider: CBORLDDictionaryProbeComputing>(
    _ probes: [CBORLDDictionaryProbe],
    dictionary: CBORLDDocumentDictionary,
    requiredFingerprint: CBORLDDigest,
    using provider: Provider
  ) async throws -> [CBORLDDictionaryProbeResult] {
    try dictionary.validate()
    try dictionary.verifyFingerprint(requiredFingerprint)
    let results = try await provider.batchedDictionaryProbe(
      probes,
      dictionary: dictionary,
      requiredFingerprint: requiredFingerprint)
    guard results.count == probes.count else {
      throw invalidComputeOutput(
        "Dictionary probe backend returned the wrong number of work items.")
    }
    for index in probes.indices { try results[index].validate(expected: probes[index]) }
    return results
  }
}

/// Deterministic CPU reference implementations for accelerator parity. The
/// implementation is intentionally serial; one array element corresponds to
/// one independent accelerator work item and output order is preserved.
public struct CBORLDCPUComputeProvider: CBORLDComputeProvider {
  let wholeDocumentLoader: CBORLDDocumentLoader?
  let cddlOracle: (any CBORLDCDDLCPUOracle)?

  /// Creates the deterministic CPU provider. A fallback document loader is
  /// optional; any remotely loaded context is still checked against the pin in
  /// its transform request. CDDL is delegated to an explicitly injected CPU
  /// oracle so this dependency-free package does not conceal an unavailable
  /// parser.
  public init(
    documentLoader: CBORLDDocumentLoader? = nil,
    cddlOracle: (any CBORLDCDDLCPUOracle)? = nil
  ) {
    self.wholeDocumentLoader = documentLoader
    self.cddlOracle = cddlOracle
  }

  public var cborldComputeCapabilities: [CBORLDComputeFamilyCapability] {
    CBORLDComputeFamilyContract.cborldCPUReferences.map { contract in
      let availability: CBORLDComputeFamilyAvailability =
        contract.id == .cddlValidation && cddlOracle == nil ? .unavailable : .available
      var constraints: [String: String] = [:]
      if contract.id == .wholeDocumentTransform {
        constraints = [
          "externalResources": "fingerprint-pinned",
          "allocation": "bounded by each request",
          "execution": "asynchronous host orchestration",
        ]
      } else if contract.id == .cddlValidation {
        constraints = [
          "cpuOracle": cddlOracle == nil ? "not configured" : "configured",
          "execution": "bounded schema and document request",
        ]
      }
      return .init(
        id: contract.id,
        availability: availability,
        implementation: contract.cpuReference.rawValue,
        constraints: constraints)
    }
  }

  public func batchedSHA256(_ slices: [Data]) async throws -> [CBORLDSHA256Result] {
    slices.map(Self.sha256)
  }

  public func batchedByteDiff(_ pairs: [CBORLDBytePair]) async throws -> [CBORLDByteDiffResult] {
    pairs.map { Self.byteDiff($0.left, $0.right) }
  }

  public func batchedCBORStructuralScan(
    _ documents: [Data],
    limits: CBORLDDecodingLimits = .init()
  ) async throws -> [CBORLDStructuralScanResult] {
    documents.map {
      var scanner = CBORStructuralScanner(data: $0, limits: limits)
      return scanner.result()
    }
  }

  public func exclusiveScanUInt32(
    _ values: [UInt32]
  ) async throws -> CBORLDExclusiveScanUInt32Result {
    var offsets: [UInt32] = []
    offsets.reserveCapacity(values.count)
    var total: UInt32 = 0
    for value in values {
      offsets.append(total)
      let addition = total.addingReportingOverflow(value)
      guard !addition.overflow else { throw Self.integerOverflow("UInt32 exclusive scan") }
      total = addition.partialValue
    }
    return .init(offsets: offsets, total: total)
  }

  public func exclusiveScanUInt64(
    _ values: [UInt64]
  ) async throws -> CBORLDExclusiveScanUInt64Result {
    var offsets: [UInt64] = []
    offsets.reserveCapacity(values.count)
    var total: UInt64 = 0
    for value in values {
      offsets.append(total)
      let addition = total.addingReportingOverflow(value)
      guard !addition.overflow else { throw Self.integerOverflow("UInt64 exclusive scan") }
      total = addition.partialValue
    }
    return .init(offsets: offsets, total: total)
  }

  public func compactByteSlices(_ slices: [Data]) async throws -> CBORLDByteCompactionResult {
    var offsets: [UInt64] = [0]
    offsets.reserveCapacity(slices.count + 1)
    var total: UInt64 = 0
    for slice in slices {
      let addition = total.addingReportingOverflow(UInt64(slice.count))
      guard !addition.overflow else { throw Self.integerOverflow("byte compaction") }
      total = addition.partialValue
      offsets.append(total)
    }
    guard total <= UInt64(Int.max) else {
      throw Self.integerOverflow("byte compaction allocation")
    }
    var bytes = Data(capacity: Int(total))
    for slice in slices { bytes.append(slice) }
    return .init(offsets: offsets, bytes: bytes)
  }

  public func batchedByteStatistics(_ slices: [Data]) async throws -> [CBORLDByteStatistics] {
    slices.map(Self.byteStatistics)
  }

  public func segmentedCanonicalKeyOrder(
    _ segments: [[Data]],
    ordering: CBORLDCanonicalKeyOrdering
  ) async throws -> [CBORLDCanonicalKeyOrderResult] {
    segments.map { keys in
      let indices = keys.indices.sorted { left, right in
        let lhs = keys[left]
        let rhs = keys[right]
        if ordering == .lengthFirst, lhs.count != rhs.count { return lhs.count < rhs.count }
        if lhs != rhs { return lhs.lexicographicallyPrecedes(rhs) }
        return left < right
      }
      return .init(orderedIndices: indices)
    }
  }

  public func batchedUTF8Validation(
    _ slices: [Data]
  ) async throws -> [CBORLDUTF8ValidationResult] {
    slices.map(Self.validateUTF8)
  }

  public func batchedMultibaseDecode(
    _ values: [String],
    maximumInputBytes: Int = 1_048_576
  ) async throws -> [CBORLDMultibaseDecodeResult] {
    guard maximumInputBytes >= 0 else {
      throw CBORLDError.invalidInput("maximumInputBytes must not be negative.")
    }
    return values.map { Self.decodeMultibase($0, maximumInputBytes: maximumInputBytes) }
  }

  public func batchedMultibaseEncode(
    _ values: [Data],
    as encoding: CBORLDMultibaseEncoding,
    maximumInputBytes: Int = 1_048_576
  ) async throws -> [String] {
    guard maximumInputBytes >= 0 else {
      throw CBORLDError.invalidInput("maximumInputBytes must not be negative.")
    }
    guard values.allSatisfy({ $0.count <= maximumInputBytes }) else {
      throw CBORLDError(
        code: .resourceLimit,
        message: "A multibase input exceeds the configured byte limit.")
    }
    return values.map { Self.encodeMultibase($0, as: encoding) }
  }

  public func batchedUnsignedVarintEncode(_ values: [UInt64]) async throws -> [Data] {
    values.map(Self.encodeUnsignedVarint)
  }

  public func batchedUnsignedVarintDecode(
    _ values: [Data]
  ) async throws -> [CBORLDUnsignedVarintDecodeResult] {
    values.map(Self.decodeUnsignedVarint)
  }

  public func batchedDictionaryProbe(
    _ probes: [CBORLDDictionaryProbe],
    dictionary: CBORLDDocumentDictionary,
    requiredFingerprint: CBORLDDigest
  ) async throws -> [CBORLDDictionaryProbeResult] {
    try dictionary.validate()
    try dictionary.verifyFingerprint(requiredFingerprint)
    let tables = dictionary.typeTable
    return probes.map { probe in
      .init(
        table: probe.table,
        value: probe.value,
        identifier: tables[probe.table]?[probe.value])
    }
  }

  public static func sha256(_ data: Data) -> CBORLDSHA256Result {
    let stateWords = SHA256CPUReference.hash(data)
    var bytes = Data(capacity: 32)
    for word in stateWords {
      var bigEndian = word.bigEndian
      withUnsafeBytes(of: &bigEndian) { bytes.append(contentsOf: $0) }
    }
    return .init(
      inputByteCount: data.count,
      stateWords: stateWords,
      // SHA-256 always yields 32 bytes, which the digest initializer requires.
      digest: try! CBORLDDigest(algorithm: .sha256, domain: .encodedBytes, version: 1, bytes: bytes)
    )
  }

  public static func byteDiff(_ left: Data, _ right: Data) -> CBORLDByteDiffResult {
    let commonCount = min(left.count, right.count)
    var mismatches = UInt64(max(left.count, right.count) - commonCount)
    var firstMismatch: Int? = left.count == right.count ? nil : commonCount
    for offset in 0..<commonCount where left[offset] != right[offset] {
      mismatches += 1
      if firstMismatch.map({ offset < $0 }) ?? true { firstMismatch = offset }
    }
    return .init(
      leftByteCount: left.count,
      rightByteCount: right.count,
      mismatchCount: mismatches,
      firstMismatchOffset: firstMismatch)
  }

  public static func byteStatistics(_ data: Data) -> CBORLDByteStatistics {
    var histogram = [UInt64](repeating: 0, count: 256)
    for byte in data { histogram[Int(byte)] += 1 }
    let count = UInt64(data.count)
    guard count != 0 else {
      return .init(byteCount: 0, histogram: histogram, shannonEntropyBitsPerByte: 0)
    }
    let total = Double(count)
    var entropy = 0.0
    for bin in histogram where bin != 0 {
      let probability = Double(bin) / total
      entropy -= probability * log2(probability)
    }
    return .init(
      byteCount: count,
      histogram: histogram,
      shannonEntropyBitsPerByte: entropy)
  }

  public static func validateUTF8(_ data: Data) -> CBORLDUTF8ValidationResult {
    let bytes = [UInt8](data)
    var index = 0
    while index < bytes.count {
      let lead = bytes[index]
      if lead <= 0x7f {
        index += 1
        continue
      }

      let continuationCount: Int
      let secondRange: ClosedRange<UInt8>
      switch lead {
      case 0xc2...0xdf:
        continuationCount = 1
        secondRange = 0x80...0xbf
      case 0xe0:
        continuationCount = 2
        secondRange = 0xa0...0xbf
      case 0xe1...0xec, 0xee...0xef:
        continuationCount = 2
        secondRange = 0x80...0xbf
      case 0xed:
        continuationCount = 2
        secondRange = 0x80...0x9f
      case 0xf0:
        continuationCount = 3
        secondRange = 0x90...0xbf
      case 0xf1...0xf3:
        continuationCount = 3
        secondRange = 0x80...0xbf
      case 0xf4:
        continuationCount = 3
        secondRange = 0x80...0x8f
      default:
        return .init(byteCount: bytes.count, isValid: false, firstInvalidByteOffset: index)
      }

      guard index + continuationCount < bytes.count else {
        return .init(byteCount: bytes.count, isValid: false, firstInvalidByteOffset: index)
      }
      guard secondRange.contains(bytes[index + 1]) else {
        return .init(byteCount: bytes.count, isValid: false, firstInvalidByteOffset: index + 1)
      }
      if continuationCount >= 2, !(0x80...0xbf).contains(bytes[index + 2]) {
        return .init(byteCount: bytes.count, isValid: false, firstInvalidByteOffset: index + 2)
      }
      if continuationCount == 3, !(0x80...0xbf).contains(bytes[index + 3]) {
        return .init(byteCount: bytes.count, isValid: false, firstInvalidByteOffset: index + 3)
      }
      index += continuationCount + 1
    }
    return .init(byteCount: bytes.count, isValid: true, firstInvalidByteOffset: nil)
  }

  public static func encodeMultibase(
    _ data: Data,
    as encoding: CBORLDMultibaseEncoding
  ) -> String {
    switch encoding {
    case .base58BTC:
      return encoding.rawValue + Base58Reference.encode(data)
    case .base64URL:
      return encoding.rawValue
        + data.base64EncodedString()
        .replacingOccurrences(of: "+", with: "-")
        .replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: "=", with: "")
    case .base64:
      return encoding.rawValue
        + data.base64EncodedString()
        .replacingOccurrences(of: "=", with: "")
    }
  }

  private static func integerOverflow(_ operation: String) -> CBORLDError {
    .init(code: .integerOverflow, message: "Exact \(operation) overflowed.")
  }

  private static func decodeMultibase(
    _ input: String,
    maximumInputBytes: Int
  ) -> CBORLDMultibaseDecodeResult {
    let inputBytes = [UInt8](input.utf8)
    guard inputBytes.count <= maximumInputBytes else {
      return .init(
        input: input,
        decoded: nil,
        firstInvalidByteOffset: maximumInputBytes,
        message: "Multibase input exceeds the configured byte limit.")
    }
    guard let prefix = inputBytes.first else {
      return .init(
        input: input,
        decoded: nil,
        firstInvalidByteOffset: 0,
        message: "Multibase input is missing an encoding prefix.")
    }
    guard prefix < 0x80, inputBytes.dropFirst().allSatisfy({ $0 < 0x80 }) else {
      let offset = inputBytes.firstIndex(where: { $0 >= 0x80 }) ?? 0
      return .init(
        input: input,
        decoded: nil,
        firstInvalidByteOffset: offset,
        message: "Supported multibase encodings use ASCII input.")
    }

    let payload = Array(inputBytes.dropFirst())
    switch prefix {
    case 0x7a:
      switch Base58Reference.decode(payload) {
      case .success(let data):
        return .init(input: input, decoded: data, firstInvalidByteOffset: nil, message: nil)
      case .failure(let offset):
        return .init(
          input: input,
          decoded: nil,
          firstInvalidByteOffset: offset + 1,
          message: "Invalid base58btc alphabet byte.")
      }
    case 0x75:
      return decodeBase64(
        input: input,
        payload: payload,
        urlSafe: true)
    case 0x4d:
      return decodeBase64(
        input: input,
        payload: payload,
        urlSafe: false)
    default:
      return .init(
        input: input,
        decoded: nil,
        firstInvalidByteOffset: 0,
        message: "Unsupported multibase prefix.")
    }
  }

  private static func decodeBase64(
    input: String,
    payload: [UInt8],
    urlSafe: Bool
  ) -> CBORLDMultibaseDecodeResult {
    let alphabet: (UInt8) -> Bool = { byte in
      switch byte {
      case 0x41...0x5a, 0x61...0x7a, 0x30...0x39:
        return true
      case 0x2d, 0x5f:
        return urlSafe
      case 0x2b, 0x2f:
        return !urlSafe
      default:
        return false
      }
    }
    if let offset = payload.firstIndex(where: { !alphabet($0) }) {
      return .init(
        input: input,
        decoded: nil,
        firstInvalidByteOffset: offset + 1,
        message: "Invalid base64 alphabet byte.")
    }
    guard payload.count % 4 != 1 else {
      return .init(
        input: input,
        decoded: nil,
        firstInvalidByteOffset: payload.count + 1,
        message: "Base64 payload has an invalid length.")
    }
    var encoded = String(decoding: payload, as: UTF8.self)
    if urlSafe {
      encoded = encoded.replacingOccurrences(of: "-", with: "+")
        .replacingOccurrences(of: "_", with: "/")
    }
    encoded += String(repeating: "=", count: (4 - encoded.count % 4) % 4)
    guard let data = Data(base64Encoded: encoded) else {
      return .init(
        input: input,
        decoded: nil,
        firstInvalidByteOffset: payload.count + 1,
        message: "Base64 payload could not be decoded.")
    }
    return .init(input: input, decoded: data, firstInvalidByteOffset: nil, message: nil)
  }

  private static func decodeUnsignedVarint(_ input: Data) -> CBORLDUnsignedVarintDecodeResult {
    let bytes = [UInt8](input)
    guard !bytes.isEmpty else {
      return .init(
        value: nil,
        bytesConsumed: 0,
        firstErrorOffset: 0,
        message: "Unsigned varint input is empty.")
    }

    var value: UInt64 = 0
    for (offset, byte) in bytes.enumerated() {
      guard offset < 10 else {
        return .init(
          value: nil,
          bytesConsumed: offset,
          firstErrorOffset: offset,
          message: "Unsigned varint exceeds UInt64 width.")
      }
      let payload = UInt64(byte & 0x7f)
      if offset == 9, payload > 1 {
        return .init(
          value: nil,
          bytesConsumed: offset + 1,
          firstErrorOffset: offset,
          message: "Unsigned varint overflows UInt64.")
      }
      value |= payload << UInt64(offset * 7)
      if byte & 0x80 == 0 {
        guard offset + 1 == bytes.count else {
          return .init(
            value: nil,
            bytesConsumed: offset + 1,
            firstErrorOffset: offset + 1,
            message: "Unsigned varint contains trailing bytes.")
        }
        return .init(
          value: value,
          bytesConsumed: offset + 1,
          firstErrorOffset: nil,
          message: nil)
      }
    }
    return .init(
      value: nil,
      bytesConsumed: bytes.count,
      firstErrorOffset: bytes.count - 1,
      message: "Unsigned varint is unterminated.")
  }

  public static func encodeUnsignedVarint(_ value: UInt64) -> Data {
    var value = value
    var output = Data()
    repeat {
      var byte = UInt8(value & 0x7f)
      value >>= 7
      if value != 0 { byte |= 0x80 }
      output.append(byte)
    } while value != 0
    return output
  }
}

private enum Base58DecodeOutcome {
  case success(Data)
  case failure(offset: Int)
}

private enum Base58Reference {
  static let alphabet = Array("123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz".utf8)
  static let indexes = Dictionary(
    uniqueKeysWithValues: alphabet.enumerated().map { ($0.element, $0.offset) })

  static func decode(_ input: [UInt8]) -> Base58DecodeOutcome {
    if input.isEmpty { return .success(Data()) }
    var bytes = [UInt8](repeating: 0, count: input.count)
    var length = 0
    for (offset, character) in input.enumerated() {
      guard var carry = indexes[character] else { return .failure(offset: offset) }
      var digitCount = 0
      for index in stride(from: bytes.count - 1, through: 0, by: -1)
      where carry != 0 || digitCount < length {
        carry += 58 * Int(bytes[index])
        bytes[index] = UInt8(carry & 0xff)
        carry >>= 8
        digitCount += 1
      }
      guard carry == 0 else { return .failure(offset: offset) }
      length = digitCount
    }
    let zeroCount = input.prefix { $0 == 0x31 }.count
    let start = bytes.count - length
    return .success(Data(repeating: 0, count: zeroCount) + Data(bytes[start...]))
  }

  static func encode(_ input: Data) -> String {
    if input.isEmpty { return "" }
    var digits = [UInt8](repeating: 0, count: input.count * 138 / 100 + 1)
    var length = 0
    for byte in input {
      var carry = Int(byte)
      var digitCount = 0
      for index in stride(from: digits.count - 1, through: 0, by: -1)
      where carry != 0 || digitCount < length {
        carry += 256 * Int(digits[index])
        digits[index] = UInt8(carry % 58)
        carry /= 58
        digitCount += 1
      }
      length = digitCount
    }
    let zeroCount = input.prefix { $0 == 0 }.count
    let start = digits.count - length
    let encoded = digits[start...].map { alphabet[Int($0)] }
    return String(repeating: "1", count: zeroCount) + String(decoding: encoded, as: UTF8.self)
  }
}

private struct CBORScanFailure: Error {
  let code: CBORLDErrorCode
  let offset: Int
  let message: String
}

private struct CBORStructuralScanner {
  private let bytes: [UInt8]
  private let limits: CBORLDDecodingLimits
  private var index = 0
  private var maximumDepth = 0
  private var itemCount: UInt64 = 0

  init(data: Data, limits: CBORLDDecodingLimits) {
    bytes = [UInt8](data)
    self.limits = limits
  }

  mutating func result() -> CBORLDStructuralScanResult {
    do {
      try validateLimits()
      try scanItem(depth: 0)
      guard index == bytes.count else {
        throw failure("Unexpected trailing bytes after the CBOR item.", offset: index)
      }
      return .init(
        byteCount: bytes.count,
        isValid: true,
        firstErrorOffset: nil,
        maximumDepth: maximumDepth,
        itemCount: itemCount,
        errorCode: nil,
        message: nil)
    } catch let error as CBORScanFailure {
      return .init(
        byteCount: bytes.count,
        isValid: false,
        firstErrorOffset: error.offset,
        maximumDepth: maximumDepth,
        itemCount: itemCount,
        errorCode: error.code,
        message: error.message)
    } catch {
      return .init(
        byteCount: bytes.count,
        isValid: false,
        firstErrorOffset: index,
        maximumDepth: maximumDepth,
        itemCount: itemCount,
        errorCode: .notCBOR,
        message: String(describing: error))
    }
  }

  private mutating func validateLimits() throws {
    guard limits.maximumInputBytes >= 0,
      limits.maximumNestingDepth >= 0,
      limits.maximumContainerItems >= 0
    else {
      throw failure(
        "CBOR scan limits must not be negative.",
        code: .resourceLimit,
        offset: 0)
    }
    guard bytes.count <= limits.maximumInputBytes else {
      throw failure(
        "CBOR input exceeds the configured byte limit.",
        code: .resourceLimit,
        offset: limits.maximumInputBytes)
    }
  }

  private mutating func scanItem(depth: Int) throws {
    let itemOffset = index
    guard depth <= limits.maximumNestingDepth else {
      throw failure(
        "CBOR nesting exceeds the configured depth.",
        code: .resourceLimit,
        offset: itemOffset)
    }
    let initial = try readByte()
    maximumDepth = max(maximumDepth, depth)
    let addition = itemCount.addingReportingOverflow(1)
    guard !addition.overflow else {
      throw failure(
        "CBOR item count overflows UInt64.",
        code: .resourceLimit,
        offset: itemOffset)
    }
    itemCount = addition.partialValue

    let major = initial >> 5
    let info = initial & 0x1f
    switch major {
    case 0, 1:
      _ = try readArgument(info)
    case 2:
      if info == 31 {
        try requireIndefiniteAllowed(offset: itemOffset)
        try scanIndefiniteStringChunks(expectedMajor: 2, validatesUTF8: false)
      } else {
        try skip(count: try checkedCount(readArgument(info), offset: itemOffset))
      }
    case 3:
      if info == 31 {
        try requireIndefiniteAllowed(offset: itemOffset)
        try scanIndefiniteStringChunks(expectedMajor: 3, validatesUTF8: true)
      } else {
        let dataOffset = index
        let data = try readData(count: try checkedCount(readArgument(info), offset: itemOffset))
        try requireValidUTF8(data, absoluteOffset: dataOffset)
      }
    case 4:
      try scanArray(info: info, depth: depth, itemOffset: itemOffset)
    case 5:
      try scanMap(info: info, depth: depth, itemOffset: itemOffset)
    case 6:
      _ = try readArgument(info)
      try scanItem(depth: depth + 1)
    case 7:
      try scanSimple(info: info, itemOffset: itemOffset)
    default:
      throw failure("Unknown CBOR major type.", offset: itemOffset)
    }
  }

  private mutating func scanArray(info: UInt8, depth: Int, itemOffset: Int) throws {
    if info == 31 {
      try requireIndefiniteAllowed(offset: itemOffset)
      var count = 0
      while try !isAtBreak() {
        count += 1
        try requireContainerCount(count, offset: itemOffset)
        try scanItem(depth: depth + 1)
      }
      index += 1
      return
    }
    let count = try checkedCount(readArgument(info), offset: itemOffset)
    try requireContainerCount(count, offset: itemOffset)
    for _ in 0..<count { try scanItem(depth: depth + 1) }
  }

  private mutating func scanMap(info: UInt8, depth: Int, itemOffset: Int) throws {
    var encodedKeys = Set<Data>()
    if info == 31 {
      try requireIndefiniteAllowed(offset: itemOffset)
      var count = 0
      while try !isAtBreak() {
        count += 1
        try requireContainerCount(count, offset: itemOffset)
        try scanMapPair(depth: depth, encodedKeys: &encodedKeys)
      }
      index += 1
      return
    }
    let count = try checkedCount(readArgument(info), offset: itemOffset)
    try requireContainerCount(count, offset: itemOffset)
    for _ in 0..<count { try scanMapPair(depth: depth, encodedKeys: &encodedKeys) }
  }

  private mutating func scanMapPair(
    depth: Int,
    encodedKeys: inout Set<Data>
  ) throws {
    let keyOffset = index
    try scanItem(depth: depth + 1)
    if limits.rejectDuplicateMapKeys {
      let encoded = Data(bytes[keyOffset..<index])
      guard encodedKeys.insert(encoded).inserted else {
        throw failure("CBOR map contains a duplicate encoded key.", offset: keyOffset)
      }
    }
    guard index < bytes.count, bytes[index] != 0xff else {
      throw failure("CBOR map is missing a value.", offset: index)
    }
    try scanItem(depth: depth + 1)
  }

  private mutating func scanIndefiniteStringChunks(
    expectedMajor: UInt8,
    validatesUTF8: Bool
  ) throws {
    while try !isAtBreak() {
      let chunkOffset = index
      let initial = try readByte()
      let major = initial >> 5
      let info = initial & 0x1f
      guard major == expectedMajor, info != 31 else {
        throw failure("Invalid indefinite-length string chunk.", offset: chunkOffset)
      }
      let dataOffset = index
      let data = try readData(count: try checkedCount(readArgument(info), offset: chunkOffset))
      if validatesUTF8 { try requireValidUTF8(data, absoluteOffset: dataOffset) }
    }
    index += 1
  }

  private mutating func scanSimple(info: UInt8, itemOffset: Int) throws {
    switch info {
    case 0...23:
      return
    case 24:
      let value = try readByte()
      guard value >= 32 else {
        throw failure("Two-byte CBOR simple value is reserved.", offset: itemOffset)
      }
    case 25:
      try skip(count: 2)
    case 26:
      try skip(count: 4)
    case 27:
      try skip(count: 8)
    default:
      throw failure("Reserved or misplaced CBOR simple value.", offset: itemOffset)
    }
  }

  private mutating func readArgument(_ info: UInt8) throws -> UInt64 {
    switch info {
    case 0...23: return UInt64(info)
    case 24: return UInt64(try readByte())
    case 25: return try readInteger(byteCount: 2)
    case 26: return try readInteger(byteCount: 4)
    case 27: return try readInteger(byteCount: 8)
    default: throw failure("Invalid CBOR additional information.", offset: index - 1)
    }
  }

  private mutating func readInteger(byteCount: Int) throws -> UInt64 {
    let start = index
    guard byteCount <= bytes.count - index else {
      throw failure("Unexpected end of CBOR integer.", offset: bytes.count)
    }
    var value: UInt64 = 0
    for _ in 0..<byteCount { value = (value << 8) | UInt64(try readByte()) }
    guard index == start + byteCount else {
      throw failure("CBOR integer width is inconsistent.", offset: start)
    }
    return value
  }

  private mutating func readByte() throws -> UInt8 {
    guard index < bytes.count else {
      throw failure("Unexpected end of CBOR data.", offset: bytes.count)
    }
    defer { index += 1 }
    return bytes[index]
  }

  private mutating func readData(count: Int) throws -> Data {
    let start = index
    try skip(count: count)
    return Data(bytes[start..<index])
  }

  private mutating func skip(count: Int) throws {
    guard count >= 0, count <= bytes.count - index else {
      throw failure("Unexpected end of CBOR byte sequence.", offset: bytes.count)
    }
    index += count
  }

  private func checkedCount(_ value: UInt64, offset: Int) throws -> Int {
    guard value <= UInt64(Int.max) else {
      throw failure("CBOR length exceeds the platform integer width.", offset: offset)
    }
    return Int(value)
  }

  private func requireContainerCount(_ count: Int, offset: Int) throws {
    guard count <= limits.maximumContainerItems else {
      throw failure(
        "CBOR container exceeds the configured item limit.",
        code: .resourceLimit,
        offset: offset)
    }
  }

  private func requireIndefiniteAllowed(offset: Int) throws {
    guard limits.allowsIndefiniteLengthItems else {
      throw failure("Indefinite-length CBOR items are disabled.", offset: offset)
    }
  }

  private func isAtBreak() throws -> Bool {
    guard index < bytes.count else {
      throw failure("Unterminated indefinite-length CBOR item.", offset: bytes.count)
    }
    return bytes[index] == 0xff
  }

  private func requireValidUTF8(_ data: Data, absoluteOffset: Int) throws {
    let result = CBORLDCPUComputeProvider.validateUTF8(data)
    guard result.isValid else {
      throw failure(
        "CBOR text string is not valid UTF-8.",
        offset: absoluteOffset + (result.firstInvalidByteOffset ?? 0))
    }
  }

  private func failure(
    _ message: String,
    code: CBORLDErrorCode = .notCBOR,
    offset: Int
  ) -> CBORScanFailure {
    .init(code: code, offset: max(0, min(offset, bytes.count)), message: message)
  }
}

/// FIPS 180-4 SHA-256 reference written with exact UInt32 modular arithmetic.
/// It is intentionally straightforward rather than optimized.
private enum SHA256CPUReference {
  private static let initialState: [UInt32] = [
    0x6a09_e667, 0xbb67_ae85, 0x3c6e_f372, 0xa54f_f53a,
    0x510e_527f, 0x9b05_688c, 0x1f83_d9ab, 0x5be0_cd19,
  ]

  private static let constants: [UInt32] = [
    0x428a_2f98, 0x7137_4491, 0xb5c0_fbcf, 0xe9b5_dba5,
    0x3956_c25b, 0x59f1_11f1, 0x923f_82a4, 0xab1c_5ed5,
    0xd807_aa98, 0x1283_5b01, 0x2431_85be, 0x550c_7dc3,
    0x72be_5d74, 0x80de_b1fe, 0x9bdc_06a7, 0xc19b_f174,
    0xe49b_69c1, 0xefbe_4786, 0x0fc1_9dc6, 0x240c_a1cc,
    0x2de9_2c6f, 0x4a74_84aa, 0x5cb0_a9dc, 0x76f9_88da,
    0x983e_5152, 0xa831_c66d, 0xb003_27c8, 0xbf59_7fc7,
    0xc6e0_0bf3, 0xd5a7_9147, 0x06ca_6351, 0x1429_2967,
    0x27b7_0a85, 0x2e1b_2138, 0x4d2c_6dfc, 0x5338_0d13,
    0x650a_7354, 0x766a_0abb, 0x81c2_c92e, 0x9272_2c85,
    0xa2bf_e8a1, 0xa81a_664b, 0xc24b_8b70, 0xc76c_51a3,
    0xd192_e819, 0xd699_0624, 0xf40e_3585, 0x106a_a070,
    0x19a4_c116, 0x1e37_6c08, 0x2748_774c, 0x34b0_bcb5,
    0x391c_0cb3, 0x4ed8_aa4a, 0x5b9c_ca4f, 0x682e_6ff3,
    0x748f_82ee, 0x78a5_636f, 0x84c8_7814, 0x8cc7_0208,
    0x90be_fffa, 0xa450_6ceb, 0xbef9_a3f7, 0xc671_78f2,
  ]

  static func hash(_ data: Data) -> [UInt32] {
    var message = [UInt8](data)
    let bitCount = UInt64(data.count) &* 8
    message.append(0x80)
    while message.count % 64 != 56 { message.append(0) }
    for shift in stride(from: 56, through: 0, by: -8) {
      message.append(UInt8(truncatingIfNeeded: bitCount >> UInt64(shift)))
    }

    var state = initialState
    var schedule = [UInt32](repeating: 0, count: 64)
    for blockStart in stride(from: 0, to: message.count, by: 64) {
      for index in 0..<16 {
        let offset = blockStart + index * 4
        schedule[index] =
          UInt32(message[offset]) << 24
          | UInt32(message[offset + 1]) << 16
          | UInt32(message[offset + 2]) << 8
          | UInt32(message[offset + 3])
      }
      for index in 16..<64 {
        let s0 =
          rotateRight(schedule[index - 15], by: 7)
          ^ rotateRight(schedule[index - 15], by: 18)
          ^ (schedule[index - 15] >> 3)
        let s1 =
          rotateRight(schedule[index - 2], by: 17)
          ^ rotateRight(schedule[index - 2], by: 19)
          ^ (schedule[index - 2] >> 10)
        schedule[index] = schedule[index - 16] &+ s0 &+ schedule[index - 7] &+ s1
      }

      var a = state[0]
      var b = state[1]
      var c = state[2]
      var d = state[3]
      var e = state[4]
      var f = state[5]
      var g = state[6]
      var h = state[7]
      for index in 0..<64 {
        let sum1 = rotateRight(e, by: 6) ^ rotateRight(e, by: 11) ^ rotateRight(e, by: 25)
        let choice = (e & f) ^ (~e & g)
        let temporary1 = h &+ sum1 &+ choice &+ constants[index] &+ schedule[index]
        let sum0 = rotateRight(a, by: 2) ^ rotateRight(a, by: 13) ^ rotateRight(a, by: 22)
        let majority = (a & b) ^ (a & c) ^ (b & c)
        let temporary2 = sum0 &+ majority
        h = g
        g = f
        f = e
        e = d &+ temporary1
        d = c
        c = b
        b = a
        a = temporary1 &+ temporary2
      }
      state[0] = state[0] &+ a
      state[1] = state[1] &+ b
      state[2] = state[2] &+ c
      state[3] = state[3] &+ d
      state[4] = state[4] &+ e
      state[5] = state[5] &+ f
      state[6] = state[6] &+ g
      state[7] = state[7] &+ h
    }
    return state
  }

  private static func rotateRight(_ value: UInt32, by amount: UInt32) -> UInt32 {
    (value >> amount) | (value << (32 - amount))
  }
}

func invalidComputeOutput(_ message: String) -> CBORLDError {
  .init(code: .invalidComputeOutput, message: message)
}

/// The largest integer JavaScript represents exactly, which bounds every
/// CBOR-LD identifier.
let cborldMaximumSafeInteger: UInt64 = 9_007_199_254_740_991

extension CBORLDError {
  static func invalidInput(_ message: String) -> Self {
    .init(code: .invalidInput, message: message)
  }
}
