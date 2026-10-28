import XCTest

@testable import CBORLD

/// The software binary16 conversions are held to the hardware `Float16` ones wherever the hardware type exists, so the
/// Intel build (which has no `Float16`) runs code proven equal to it.
final class HalfPrecisionTests: XCTestCase {
  #if !(os(macOS) && arch(x86_64))
    func testEveryHalfBitPatternDecodesLikeFloat16() {
      for bits in UInt16.min...UInt16.max {
        let hardware = Double(Float16(bitPattern: bits))
        XCTAssertEqual(
          HalfPrecision.double(fromBits: bits).bitPattern, hardware.bitPattern,
          "bits 0x\(String(bits, radix: 16))")
      }
    }

    func testExactnessAgreesWithFloat16RoundTrip() {
      func hardware(_ x: Double) -> UInt16? {
        if x.isNaN { return nil }
        let half = Float16(x)
        return Double(half).bitPattern == x.bitPattern ? half.bitPattern : nil
      }
      var probes: [Double] = []
      for bits in UInt16.min...UInt16.max {
        let x = Double(Float16(bitPattern: bits))
        guard !x.isNaN else { continue }
        // Each half value, its binary64 neighbours, and the midpoints and quarter points towards the next half value.
        let next = Double(Float16(bitPattern: bits).nextUp)
        probes += [
          x, x.nextUp, x.nextDown, x + (next - x) / 2, x + (next - x) / 4, Double(Float(x).nextUp),
        ]
      }
      var generator = SystemRandomNumberGenerator()
      for _ in 0..<200_000 {
        probes.append(Double(bitPattern: generator.next()))
        probes.append(
          Double(Float(bitPattern: UInt32.random(in: .min ... .max, using: &generator))))
      }
      probes += [
        0x1p-24, 0x1p-25, 65504, 65520, 65536, .leastNonzeroMagnitude, .greatestFiniteMagnitude,
        .infinity, -.infinity,
      ]
      for x in probes {
        XCTAssertEqual(
          HalfPrecision.exactBits(of: x), hardware(x),
          "x \(x) bits 0x\(String(x.bitPattern, radix: 16))")
      }
    }
  #endif

  func testClosedForms() {
    XCTAssertEqual(HalfPrecision.double(fromBits: 0x3c00), 1)
    XCTAssertEqual(HalfPrecision.double(fromBits: 0x7bff), 65504)
    XCTAssertEqual(HalfPrecision.double(fromBits: 0x0001), 0x1p-24)
    XCTAssertEqual(HalfPrecision.double(fromBits: 0x8000).sign, .minus)
    XCTAssertTrue(HalfPrecision.double(fromBits: 0x7e00).isNaN)
    XCTAssertEqual(HalfPrecision.exactBits(of: 1.5), 0x3e00)
    XCTAssertEqual(HalfPrecision.exactBits(of: -0.0), 0x8000)
    XCTAssertEqual(HalfPrecision.exactBits(of: 0x1p-24), 0x0001)
    XCTAssertNil(HalfPrecision.exactBits(of: 0x1p-25))
    XCTAssertNil(HalfPrecision.exactBits(of: 65520))
    XCTAssertNil(HalfPrecision.exactBits(of: 0.1))
    XCTAssertNil(HalfPrecision.exactBits(of: .nan))
  }
}
