import Foundation
import XCTest

@testable import CBORLD

/// Seeded generators for property and differential tests. Every run prints
/// nothing unless a property fails, and failures report the seed and case so
/// that the input can be reproduced and minimized into a regression fixture.
///
/// The iteration count defaults to a quick setting for ordinary test runs.
/// Scheduled fuzzing sets `CBORLD_FUZZ_ITERATIONS` (and optionally
/// `CBORLD_FUZZ_SEED`, in hexadecimal) to run far more cases. A value that
/// does not parse stops the run instead of silently using the default.
enum PropertyTesting {
  static var iterations: Int {
    guard let text = ProcessInfo.processInfo.environment["CBORLD_FUZZ_ITERATIONS"] else {
      return 300
    }
    guard let iterations = Int(text), iterations > 0 else {
      preconditionFailure("CBORLD_FUZZ_ITERATIONS must be a positive integer, not \"\(text)\".")
    }
    return iterations
  }

  static var seed: UInt64 {
    guard let text = ProcessInfo.processInfo.environment["CBORLD_FUZZ_SEED"] else {
      return 0xC0B0_1D5E_ED00_0001
    }
    let digits = text.hasPrefix("0x") ? text.dropFirst(2) : Substring(text)
    guard let seed = UInt64(digits, radix: 16) else {
      preconditionFailure("CBORLD_FUZZ_SEED must be hexadecimal, not \"\(text)\".")
    }
    return seed
  }
}

extension SplitMix64 {
  mutating func int(_ range: ClosedRange<Int>) -> Int {
    range.lowerBound + Int(next() % UInt64(range.upperBound - range.lowerBound + 1))
  }

  mutating func chance(_ numerator: UInt64, in denominator: UInt64) -> Bool {
    next() % denominator < numerator
  }

  mutating func element<T>(_ values: [T]) -> T {
    values[Int(next() % UInt64(values.count))]
  }
}

// MARK: - JSON trees

struct JSONGenerator {
  var random: SplitMix64
  var maximumDepth = 5
  var maximumWidth = 6

  init(seed: UInt64) {
    random = SplitMix64(seed: seed)
  }

  mutating func value(depth: Int = 0) -> JSONValue {
    let containerAllowed = depth < maximumDepth
    switch random.int(0...(containerAllowed ? 9 : 6)) {
    case 0: return .null
    case 1: return .bool(random.chance(1, in: 2))
    case 2: return .integer(integer())
    case 3: return .number(number())
    case 4, 5, 6: return .string(string())
    case 7, 8:
      return .array((0..<random.int(0...maximumWidth)).map { _ in value(depth: depth + 1) })
    default:
      var object: [String: JSONValue] = [:]
      for _ in 0..<random.int(0...maximumWidth) { object[string()] = value(depth: depth + 1) }
      return .object(object)
    }
  }

  mutating func integer() -> Int64 {
    switch random.int(0...5) {
    case 0: return Int64(random.int(-24...24))
    case 1: return random.element([23, 24, 255, 256, 65_535, 65_536, -25, -256, -257])
    case 2: return random.element([Int64.max, Int64.min, 4_294_967_295, 4_294_967_296])
    case 3: return Int64(bitPattern: random.next())
    default: return Int64(random.int(-100_000...100_000))
    }
  }

  /// A finite number drawn from every IEEE 754 width and edge.
  mutating func number() -> Double {
    let value = anyNumber()
    return value.isFinite ? value : 0.25
  }

  private mutating func anyNumber() -> Double {
    switch random.int(0...6) {
    case 0: return random.element([0.5, -1.5, 1.0, 65_504, 1e-7, 3.4028234663852886e38])
    case 1: return Double(Float16(bitPattern: UInt16(truncatingIfNeeded: random.next())))
    case 2: return Double(Float(bitPattern: UInt32(truncatingIfNeeded: random.next())))
    case 3: return random.element([5e-324, 2.2250738585072014e-308, -0.0, 9_007_199_254_740_994])
    default:
      return Double(bitPattern: random.next())
    }
  }

  mutating func string() -> String {
    let alphabet: [Character] = ["a", "b", "z", "@", " ", "é", "中", "😀", "-", "0"]
    let length = random.chance(1, in: 20) ? random.int(20...300) : random.int(0...8)
    return String((0..<length).map { _ in random.element(alphabet) })
  }
}

// MARK: - Arbitrary CBOR

/// Produces syntactically plausible CBOR with every representation choice the
/// parsers must handle, including invalid ones.
struct CBORGenerator {
  var random: SplitMix64
  var maximumDepth = 5

  init(seed: UInt64) {
    random = SplitMix64(seed: seed)
  }

  /// A CBOR-LD envelope around a random payload.
  mutating func envelope() -> [UInt8] {
    var bytes: [UInt8] = []
    switch random.int(0...9) {
    case 0...5:
      bytes += [0xd9, 0xcb, 0x1d]
      bytes += head(major: 4, random.chance(1, in: 10) ? 3 : 2)
      bytes += head(major: 0, random.element([0, 0, 0, 1, 2, 300]))
    case 6: bytes += head(major: 6, UInt64(random.int(1_536...1_791)))
    case 7: bytes += head(major: 6, random.element([1_280, 1_281]))
    case 8: bytes += head(major: 6, random.element([1, 24, 51_996]))
    default: break
    }
    bytes += item(depth: 3)
    return bytes
  }

  mutating func item(depth: Int) -> [UInt8] {
    let containerAllowed = depth < maximumDepth
    switch random.int(0...(containerAllowed ? 12 : 8)) {
    case 0: return head(major: 0, argument())
    case 1: return head(major: 1, argument())
    case 2: return string(major: 2)
    case 3, 4: return string(major: 3)
    case 5: return simple()
    case 6: return float()
    case 7: return [random.element([0xf4, 0xf5, 0xf6, 0xf7])]
    case 8: return head(major: 0, UInt64(random.int(0...30)))
    case 9, 10: return array(depth: depth)
    case 11: return map(depth: depth)
    default: return head(major: 6, argument()) + item(depth: depth + 1)
    }
  }

  /// A head whose argument is written in a preferred or wider width.
  mutating func head(major: UInt8, _ value: UInt64) -> [UInt8] {
    let prefix = major << 5
    var width = preferredWidth(value)
    if random.chance(1, in: 8) { width = min(width + random.int(1...3), 4) }
    // A width is never narrower than the preferred width, so the value fits.
    switch width {
    case 0: return [prefix | UInt8(value)]
    case 1: return [prefix | 24, UInt8(value)]
    case 2: return [prefix | 25, UInt8(value >> 8), UInt8(truncatingIfNeeded: value)]
    case 3: return [prefix | 26] + Self.bigEndian(value, byteCount: 4)
    default: return [prefix | 27] + Self.bigEndian(value, byteCount: 8)
    }
  }

  private func preferredWidth(_ value: UInt64) -> Int {
    switch value {
    case 0...23: return 0
    case 24...0xff: return 1
    case 0x100...0xffff: return 2
    case 0x1_0000...0xffff_ffff: return 3
    default: return 4
    }
  }

  private mutating func argument() -> UInt64 {
    switch random.int(0...4) {
    case 0: return UInt64(random.int(0...30))
    case 1: return random.element([23, 24, 255, 256, 65_535, 65_536, 4_294_967_295])
    case 2: return random.element([UInt64(Int64.max), UInt64(Int64.max) + 1, .max])
    default: return UInt64(random.int(0...100_000))
    }
  }

  private mutating func string(major: UInt8) -> [UInt8] {
    let content: [UInt8]
    if major == 3, !random.chance(1, in: 12) {
      var text = JSONGenerator(seed: random.next())
      content = Array(text.string().utf8)
    } else {
      content = (0..<random.int(0...6)).map { _ in UInt8(truncatingIfNeeded: random.next()) }
    }
    if random.chance(1, in: 6) {
      var bytes: [UInt8] = [major << 5 | 31]
      var start = 0
      while start < content.count {
        let end = min(content.count, start + random.int(1...3))
        bytes += head(major: major, UInt64(end - start)) + content[start..<end]
        start = end
      }
      return bytes + [0xff]
    }
    return head(major: major, UInt64(content.count)) + content
  }

  private mutating func simple() -> [UInt8] {
    switch random.int(0...3) {
    case 0: return [0xe0 | UInt8(random.int(0...19))]
    case 1: return [0xf8, UInt8(random.int(0...255))]
    case 2: return [0xe0 | UInt8(random.int(28...31))]
    default: return [0xf6]
    }
  }

  private mutating func float() -> [UInt8] {
    var numbers = JSONGenerator(seed: random.next())
    let value = numbers.number()
    switch random.int(0...4) {
    case 0:
      return [0xf9] + Self.bigEndian(UInt64(Float16(value).bitPattern), byteCount: 2)
    case 1:
      return [0xfa] + Self.bigEndian(UInt64(Float(value).bitPattern), byteCount: 4)
    case 2:
      let nanBits: UInt64 = random.element([0x7e00, 0x7e01, 0xfe00, 0x7c00, 0xfc00])
      return [0xf9] + Self.bigEndian(nanBits, byteCount: 2)
    default:
      return [0xfb] + Self.bigEndian(value.bitPattern, byteCount: 8)
    }
  }

  private static func bigEndian(_ value: UInt64, byteCount: Int) -> [UInt8] {
    (0..<byteCount).map { index in
      UInt8(truncatingIfNeeded: value >> UInt64(8 * (byteCount - 1 - index)))
    }
  }

  private mutating func array(depth: Int) -> [UInt8] {
    let count = random.int(0...4)
    let elements = (0..<count).flatMap { _ in item(depth: depth + 1) }
    if random.chance(1, in: 5) { return [0x9f] + elements + [0xff] }
    return head(major: 4, UInt64(count)) + elements
  }

  private mutating func map(depth: Int) -> [UInt8] {
    let count = random.int(0...4)
    var entries: [UInt8] = []
    var previousKey: [UInt8]?
    for _ in 0..<count {
      let key: [UInt8]
      if let previousKey, random.chance(1, in: 6) {
        key = previousKey
      } else if random.chance(3, in: 4) {
        key = string(major: 3)
      } else {
        key = item(depth: depth + 1)
      }
      previousKey = key
      entries += key + item(depth: depth + 1)
    }
    if random.chance(1, in: 5) { return [0xbf] + entries + [0xff] }
    return head(major: 5, UInt64(count)) + entries
  }
}

// MARK: - Mutation and chunking

enum ByteMutation {
  static func mutate(_ bytes: [UInt8], random: inout SplitMix64) -> [UInt8] {
    var result = bytes
    for _ in 0..<random.int(1...3) {
      switch random.int(0...4) {
      case 0 where !result.isEmpty:
        result[random.int(0...(result.count - 1))] ^= UInt8(1 << random.int(0...7))
      case 1 where !result.isEmpty:
        result[random.int(0...(result.count - 1))] = UInt8(truncatingIfNeeded: random.next())
      case 2:
        result.insert(UInt8(truncatingIfNeeded: random.next()), at: random.int(0...result.count))
      case 3 where !result.isEmpty:
        result.remove(at: random.int(0...(result.count - 1)))
      default:
        if !result.isEmpty { result.removeLast(random.int(0...(result.count - 1))) }
      }
    }
    return result
  }
}

/// Splits bytes at random boundaries, including empty chunks.
func randomChunks(_ bytes: [UInt8], random: inout SplitMix64) -> [Data] {
  var chunks: [Data] = []
  var start = 0
  while start < bytes.count {
    let size = random.chance(1, in: 10) ? 0 : random.int(1...max(1, min(17, bytes.count)))
    let end = min(bytes.count, start + size)
    chunks.append(Data(bytes[start..<end]))
    start = end
  }
  return chunks
}

extension Array where Element == Data {
  var asyncChunks: AsyncArray<Data> { AsyncArray(elements: self) }
}

/// The outcome of one operation, compared across implementations. Failures
/// compare by error code; the message is kept to explain known differences.
enum Outcome: Equatable, CustomStringConvertible {
  case success(String)
  case failure(CBORLDErrorCode, message: String)
  case otherFailure(String)

  init(catching body: () throws -> String) {
    do {
      self = .success(try body())
    } catch let error as CBORLDError {
      self = .failure(error.code, message: error.message)
    } catch {
      self = .otherFailure(String(describing: type(of: error)))
    }
  }

  init(catching body: () async throws -> String) async {
    do {
      self = .success(try await body())
    } catch let error as CBORLDError {
      self = .failure(error.code, message: error.message)
    } catch {
      self = .otherFailure(String(describing: type(of: error)))
    }
  }

  static func == (lhs: Outcome, rhs: Outcome) -> Bool {
    switch (lhs, rhs) {
    case (.success(let left), .success(let right)): return left == right
    case (.failure(let left, _), .failure(let right, _)): return left == right
    case (.otherFailure(let left), .otherFailure(let right)): return left == right
    default: return false
    }
  }

  var isSuccess: Bool {
    if case .success = self { return true }
    return false
  }

  var failureMessage: String? {
    if case .failure(_, let message) = self { return message }
    return nil
  }

  var description: String {
    switch self {
    case .success(let value): return "success(\(value))"
    case .failure(let code, let message): return "failure(\(code): \(message))"
    case .otherFailure(let type): return "failure(\(type))"
    }
  }
}

extension JSONValue {
  /// A canonical spelling for comparing values whose dictionaries may iterate
  /// in different orders.
  var canonicalHex: String {
    (try? CBORLD.encodeUncompressed(self, serializationMode: .coreDeterministic).hexString)
      ?? "\(self)"
  }
}
