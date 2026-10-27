/// IEEE 754 binary16 conversions in software.
///
/// `Float16` does not exist on Intel Macs, so using it directly makes the package fail to build there (and so any
/// universal macOS build). Every half-precision conversion goes through here instead. The tests hold both functions
/// bit for bit to the hardware `Float16` conversions over all 65,536 half bit patterns, on platforms that have it.
enum HalfPrecision {
  /// The double a half-precision bit pattern denotes. Exact: every binary16 value is a binary64 value. A NaN keeps its
  /// sign and payload and comes back quiet, as the hardware conversion does.
  static func double(fromBits bits: UInt16) -> Double {
    let negative = bits & 0x8000 != 0
    let exponent = Int(bits >> 10 & 0x1f)
    let fraction = UInt64(bits & 0x3ff)
    switch exponent {
    case 0:
      let magnitude = Double(fraction) * 0x1p-24
      return negative ? -magnitude : magnitude
    case 0x1f where fraction == 0:
      return negative ? -.infinity : .infinity
    case 0x1f:
      return Double(bitPattern: (negative ? 1 << 63 : 0) | 0x7ff8_0000_0000_0000 | fraction << 42)
    default:
      let magnitude = Double(sign: .plus, exponent: exponent - 15, significand: 1 + Double(fraction) / 1024)
      return negative ? -magnitude : magnitude
    }
  }

  /// The half-precision bit pattern of `value` when `value` is exactly representable in binary16, else `nil`.
  /// Signed zeros and infinities are representable; NaN is never reported here (callers choose its encoding).
  static func exactBits(of value: Double) -> UInt16? {
    if value.isNaN { return nil }
    let sign: UInt16 = value.sign == .minus ? 0x8000 : 0
    let magnitude = value.magnitude
    if magnitude == 0 { return sign }
    if magnitude.isInfinite { return sign | 0x7c00 }
    let exponent = Int(magnitude.exponent)
    if exponent > 15 { return nil }
    if exponent >= -14 {
      // Normal: 1.f × 2^e with ten fraction bits.
      let scaled = magnitude.significand * 1024
      guard scaled.rounded(.towardZero) == scaled else { return nil }
      return sign | UInt16(exponent + 15) << 10 | (UInt16(scaled) - 1024)
    }
    // Subnormal: m × 2^-24. Here magnitude < 2^-14, so m < 1024 needs no check.
    let scaled = magnitude * 0x1p24
    guard scaled.rounded(.towardZero) == scaled else { return nil }
    return sign | UInt16(scaled)
  }
}
