import Foundation

/// The size of an in-memory JSON tree, measured without serializing it.
///
/// Every field is exact and independent of any text formatting.
/// ``encodedByteCount`` is the size of the tree as preferred-width,
/// definite-length CBOR, which is the payload size of a registry-entry-zero
/// CBOR-LD document in every serialization mode.
public struct CBORLDStructuralCost: Sendable, Hashable, Codable {
  /// Values in the tree, counting every container and scalar once.
  public var nodeCount: Int
  /// UTF-8 bytes in string values and object keys.
  public var stringByteCount: Int
  /// Deepest container nesting. A scalar root has depth `0`, `[]` has depth
  /// `1`, and `[[1]]` has depth `2`.
  public var maximumDepth: Int
  /// Exact size of the tree encoded as preferred-width, definite-length CBOR.
  public var encodedByteCount: Int

  public init(nodeCount: Int, stringByteCount: Int, maximumDepth: Int, encodedByteCount: Int) {
    self.nodeCount = nodeCount
    self.stringByteCount = stringByteCount
    self.maximumDepth = maximumDepth
    self.encodedByteCount = encodedByteCount
  }
}

extension JSONValue {
  /// Measures the tree iteratively, so arbitrarily deep values cannot exhaust
  /// the call stack. Totals saturate at `Int.max`.
  public var structuralCost: CBORLDStructuralCost {
    var nodes = 0
    var stringBytes = 0
    var maximumDepth = 0
    var encodedBytes = 0
    var pending: [(value: JSONValue, depth: Int)] = [(self, 0)]
    while let (value, depth) = pending.popLast() {
      nodes = saturatingAdd(nodes, 1)
      switch value {
      case .null, .bool:
        encodedBytes = saturatingAdd(encodedBytes, 1)
      case .integer(let integer):
        let argument = integer >= 0 ? UInt64(integer) : UInt64(bitPattern: ~integer)
        encodedBytes = saturatingAdd(encodedBytes, CBOREncoder.headerByteCount(argument))
      case .number(let number):
        encodedBytes = saturatingAdd(encodedBytes, Self.encodedByteCount(of: number))
      case .string(let string):
        let count = string.utf8.count
        stringBytes = saturatingAdd(stringBytes, count)
        encodedBytes = saturatingAdd(
          encodedBytes, saturatingAdd(CBOREncoder.headerByteCount(UInt64(count)), count))
      case .array(let values):
        maximumDepth = Swift.max(maximumDepth, depth + 1)
        encodedBytes = saturatingAdd(
          encodedBytes, CBOREncoder.headerByteCount(UInt64(values.count)))
        for element in values { pending.append((element, depth + 1)) }
      case .object(let object):
        maximumDepth = Swift.max(maximumDepth, depth + 1)
        encodedBytes = saturatingAdd(
          encodedBytes, CBOREncoder.headerByteCount(UInt64(object.count)))
        for (key, element) in object {
          let count = key.utf8.count
          stringBytes = saturatingAdd(stringBytes, count)
          encodedBytes = saturatingAdd(
            encodedBytes, saturatingAdd(CBOREncoder.headerByteCount(UInt64(count)), count))
          pending.append((element, depth + 1))
        }
      }
    }
    return CBORLDStructuralCost(
      nodeCount: nodes,
      stringByteCount: stringBytes,
      maximumDepth: maximumDepth,
      encodedByteCount: encodedBytes)
  }

  /// Mirrors the encoder: integral numbers in the safe-integer range become
  /// integers, and other finite numbers use the shortest exact float width.
  private static func encodedByteCount(of number: Double) -> Int {
    if number.isFinite, number.rounded(.towardZero) == number {
      if number >= 0, number <= Double(CBORLDConstants.maximumSafeInteger) {
        return CBOREncoder.headerByteCount(UInt64(number))
      }
      if number >= -Double(CBORLDConstants.maximumSafeInteger), number < 0 {
        return CBOREncoder.headerByteCount(UInt64(bitPattern: ~Int64(number)))
      }
    }
    if number.isNaN || Double(Float16(number)).bitPattern == number.bitPattern { return 3 }
    if Double(Float(number)).bitPattern == number.bitPattern { return 5 }
    return 9
  }
}

@inline(__always)
private func saturatingAdd(_ lhs: Int, _ rhs: Int) -> Int {
  let (sum, overflow) = lhs.addingReportingOverflow(rhs)
  return overflow ? .max : sum
}
