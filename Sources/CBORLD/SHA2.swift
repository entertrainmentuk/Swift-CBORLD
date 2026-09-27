import Foundation

#if canImport(CryptoKit)
  import CryptoKit
#endif

/// Incremental SHA-2 behind every digest API.
///
/// Apple platforms use CryptoKit, a system framework that runs on the
/// processor's SHA-2 instructions. Other platforms use
/// ``PortableSHA2Hasher``, which is dependency-free. The two produce identical
/// digests; the test suite keeps the portable implementation compiled on every
/// platform and checks both against each other.
struct CBORLDSHA2Hasher {
  #if canImport(CryptoKit)
    private enum Storage {
      case sha256(CryptoKit.SHA256)
      case sha384(CryptoKit.SHA384)
      case sha512(CryptoKit.SHA512)
    }
  #else
    private typealias Storage = PortableSHA2Hasher
  #endif

  private var storage: Storage

  /// The implementation in use on this platform, for diagnostics.
  static var implementation: String {
    #if canImport(CryptoKit)
      "CryptoKit"
    #else
      "portable"
    #endif
  }

  init(algorithm: CBORLDHashAlgorithm) {
    #if canImport(CryptoKit)
      switch algorithm {
      case .sha256: storage = .sha256(CryptoKit.SHA256())
      case .sha384: storage = .sha384(CryptoKit.SHA384())
      case .sha512: storage = .sha512(CryptoKit.SHA512())
      }
    #else
      storage = PortableSHA2Hasher(algorithm: algorithm)
    #endif
  }

  mutating func update(bytes: UnsafeRawBufferPointer) {
    #if canImport(CryptoKit)
      switch storage {
      case .sha256(var hasher):
        hasher.update(bufferPointer: bytes)
        storage = .sha256(hasher)
      case .sha384(var hasher):
        hasher.update(bufferPointer: bytes)
        storage = .sha384(hasher)
      case .sha512(var hasher):
        hasher.update(bufferPointer: bytes)
        storage = .sha512(hasher)
      }
    #else
      storage.update(bytes: bytes)
    #endif
  }

  mutating func update(data: Data) {
    data.withUnsafeBytes { update(bytes: $0) }
  }

  func finalize() -> Data {
    #if canImport(CryptoKit)
      switch storage {
      case .sha256(let hasher): return Data(hasher.finalize())
      case .sha384(let hasher): return Data(hasher.finalize())
      case .sha512(let hasher): return Data(hasher.finalize())
      }
    #else
      return storage.finalize()
    #endif
  }

  static func hash(_ data: Data, algorithm: CBORLDHashAlgorithm) -> Data {
    var hasher = Self(algorithm: algorithm)
    hasher.update(data: data)
    return hasher.finalize()
  }
}

/// Dependency-free FIPS 180-4 SHA-256, SHA-384, and SHA-512.
///
/// Blocks are compressed straight from the caller's buffer, the message
/// schedule lives in a temporary stack allocation, and only a partial block is
/// retained between updates, so hashing allocates nothing per block.
struct PortableSHA2Hasher {
  private enum Core {
    case sha256(PortableSHA256)
    case sha512(PortableSHA512)
  }

  private var core: Core

  init(algorithm: CBORLDHashAlgorithm) {
    switch algorithm {
    case .sha256: core = .sha256(PortableSHA256())
    case .sha384: core = .sha512(PortableSHA512(is384: true))
    case .sha512: core = .sha512(PortableSHA512(is384: false))
    }
  }

  mutating func update(bytes: UnsafeRawBufferPointer) {
    switch core {
    case .sha256(var state):
      state.update(bytes)
      core = .sha256(state)
    case .sha512(var state):
      state.update(bytes)
      core = .sha512(state)
    }
  }

  mutating func update(data: Data) {
    data.withUnsafeBytes { update(bytes: $0) }
  }

  func finalize() -> Data {
    switch core {
    case .sha256(let state): return state.finalize()
    case .sha512(let state): return state.finalize()
    }
  }

  static func hash(_ data: Data, algorithm: CBORLDHashAlgorithm) -> Data {
    var hasher = Self(algorithm: algorithm)
    hasher.update(data: data)
    return hasher.finalize()
  }
}

private struct PortableSHA256 {
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

  private var state: [UInt32] = [
    0x6a09_e667, 0xbb67_ae85, 0x3c6e_f372, 0xa54f_f53a,
    0x510e_527f, 0x9b05_688c, 0x1f83_d9ab, 0x5be0_cd19,
  ]
  private var pending = [UInt8](repeating: 0, count: 64)
  private var pendingCount = 0
  private var byteCount: UInt64 = 0

  mutating func update(_ bytes: UnsafeRawBufferPointer) {
    guard let base = bytes.baseAddress, !bytes.isEmpty else { return }
    byteCount &+= UInt64(bytes.count)
    var offset = 0
    if pendingCount > 0 {
      let taken = Swift.min(64 - pendingCount, bytes.count)
      pending.withUnsafeMutableBytes { buffer in
        (buffer.baseAddress! + pendingCount).copyMemory(from: base, byteCount: taken)
      }
      pendingCount += taken
      offset = taken
      guard pendingCount == 64 else { return }
      pending.withUnsafeBytes { compress($0.baseAddress!) }
      pendingCount = 0
    }
    while bytes.count - offset >= 64 {
      compress(base + offset)
      offset += 64
    }
    if offset < bytes.count {
      let remaining = bytes.count - offset
      pending.withUnsafeMutableBytes { buffer in
        buffer.baseAddress!.copyMemory(from: base + offset, byteCount: remaining)
      }
      pendingCount = remaining
    }
  }

  func finalize() -> Data {
    var copy = self
    let bitCount = byteCount &* 8
    var padding = [UInt8](
      repeating: 0, count: pendingCount < 56 ? 64 - pendingCount : 128 - pendingCount)
    padding[0] = 0x80
    for index in 0..<8 {
      padding[padding.count - 1 - index] = UInt8(truncatingIfNeeded: bitCount >> UInt64(8 * index))
    }
    padding.withUnsafeBytes { copy.update($0) }
    var digest = Data(capacity: 32)
    for word in copy.state {
      digest.append(contentsOf: [
        UInt8(truncatingIfNeeded: word >> 24), UInt8(truncatingIfNeeded: word >> 16),
        UInt8(truncatingIfNeeded: word >> 8), UInt8(truncatingIfNeeded: word),
      ])
    }
    return digest
  }

  private mutating func compress(_ block: UnsafeRawPointer) {
    withUnsafeTemporaryAllocation(of: UInt32.self, capacity: 64) { schedule in
      for index in 0..<16 {
        schedule[index] = UInt32(
          bigEndian: block.loadUnaligned(fromByteOffset: index &* 4, as: UInt32.self))
      }
      for index in 16..<64 {
        let early = schedule[index &- 15]
        let late = schedule[index &- 2]
        let sigma0 = rotateRight(early, 7) ^ rotateRight(early, 18) ^ (early >> 3)
        let sigma1 = rotateRight(late, 17) ^ rotateRight(late, 19) ^ (late >> 10)
        schedule[index] = schedule[index &- 16] &+ sigma0 &+ schedule[index &- 7] &+ sigma1
      }
      var a = state[0]
      var b = state[1]
      var c = state[2]
      var d = state[3]
      var e = state[4]
      var f = state[5]
      var g = state[6]
      var h = state[7]
      Self.constants.withUnsafeBufferPointer { constants in
        for index in 0..<64 {
          let sum1 = rotateRight(e, 6) ^ rotateRight(e, 11) ^ rotateRight(e, 25)
          let choice = (e & f) ^ (~e & g)
          let temporary1 = h &+ sum1 &+ choice &+ constants[index] &+ schedule[index]
          let sum0 = rotateRight(a, 2) ^ rotateRight(a, 13) ^ rotateRight(a, 22)
          let majority = (a & b) ^ (a & c) ^ (b & c)
          h = g
          g = f
          f = e
          e = d &+ temporary1
          d = c
          c = b
          b = a
          a = temporary1 &+ sum0 &+ majority
        }
      }
      state[0] &+= a
      state[1] &+= b
      state[2] &+= c
      state[3] &+= d
      state[4] &+= e
      state[5] &+= f
      state[6] &+= g
      state[7] &+= h
    }
  }
}

private struct PortableSHA512 {
  private static let initial512: [UInt64] = [
    0x6a09_e667_f3bc_c908, 0xbb67_ae85_84ca_a73b,
    0x3c6e_f372_fe94_f82b, 0xa54f_f53a_5f1d_36f1,
    0x510e_527f_ade6_82d1, 0x9b05_688c_2b3e_6c1f,
    0x1f83_d9ab_fb41_bd6b, 0x5be0_cd19_137e_2179,
  ]

  private static let initial384: [UInt64] = [
    0xcbbb_9d5d_c105_9ed8, 0x629a_292a_367c_d507,
    0x9159_015a_3070_dd17, 0x152f_ecd8_f70e_5939,
    0x6733_2667_ffc0_0b31, 0x8eb4_4a87_6858_1511,
    0xdb0c_2e0d_64f9_8fa7, 0x47b5_481d_befa_4fa4,
  ]

  private static let constants: [UInt64] = [
    0x428a_2f98_d728_ae22, 0x7137_4491_23ef_65cd,
    0xb5c0_fbcf_ec4d_3b2f, 0xe9b5_dba5_8189_dbbc,
    0x3956_c25b_f348_b538, 0x59f1_11f1_b605_d019,
    0x923f_82a4_af19_4f9b, 0xab1c_5ed5_da6d_8118,
    0xd807_aa98_a303_0242, 0x1283_5b01_4570_6fbe,
    0x2431_85be_4ee4_b28c, 0x550c_7dc3_d5ff_b4e2,
    0x72be_5d74_f27b_896f, 0x80de_b1fe_3b16_96b1,
    0x9bdc_06a7_25c7_1235, 0xc19b_f174_cf69_2694,
    0xe49b_69c1_9ef1_4ad2, 0xefbe_4786_384f_25e3,
    0x0fc1_9dc6_8b8c_d5b5, 0x240c_a1cc_77ac_9c65,
    0x2de9_2c6f_592b_0275, 0x4a74_84aa_6ea6_e483,
    0x5cb0_a9dc_bd41_fbd4, 0x76f9_88da_8311_53b5,
    0x983e_5152_ee66_dfab, 0xa831_c66d_2db4_3210,
    0xb003_27c8_98fb_213f, 0xbf59_7fc7_beef_0ee4,
    0xc6e0_0bf3_3da8_8fc2, 0xd5a7_9147_930a_a725,
    0x06ca_6351_e003_826f, 0x1429_2967_0a0e_6e70,
    0x27b7_0a85_46d2_2ffc, 0x2e1b_2138_5c26_c926,
    0x4d2c_6dfc_5ac4_2aed, 0x5338_0d13_9d95_b3df,
    0x650a_7354_8baf_63de, 0x766a_0abb_3c77_b2a8,
    0x81c2_c92e_47ed_aee6, 0x9272_2c85_1482_353b,
    0xa2bf_e8a1_4cf1_0364, 0xa81a_664b_bc42_3001,
    0xc24b_8b70_d0f8_9791, 0xc76c_51a3_0654_be30,
    0xd192_e819_d6ef_5218, 0xd699_0624_5565_a910,
    0xf40e_3585_5771_202a, 0x106a_a070_32bb_d1b8,
    0x19a4_c116_b8d2_d0c8, 0x1e37_6c08_5141_ab53,
    0x2748_774c_df8e_eb99, 0x34b0_bcb5_e19b_48a8,
    0x391c_0cb3_c5c9_5a63, 0x4ed8_aa4a_e341_8acb,
    0x5b9c_ca4f_7763_e373, 0x682e_6ff3_d6b2_b8a3,
    0x748f_82ee_5def_b2fc, 0x78a5_636f_4317_2f60,
    0x84c8_7814_a1f0_ab72, 0x8cc7_0208_1a64_39ec,
    0x90be_fffa_2363_1e28, 0xa450_6ceb_de82_bde9,
    0xbef9_a3f7_b2c6_7915, 0xc671_78f2_e372_532b,
    0xca27_3ece_ea26_619c, 0xd186_b8c7_21c0_c207,
    0xeada_7dd6_cde0_eb1e, 0xf57d_4f7f_ee6e_d178,
    0x06f0_67aa_7217_6fba, 0x0a63_7dc5_a2c8_98a6,
    0x113f_9804_bef9_0dae, 0x1b71_0b35_131c_471b,
    0x28db_77f5_2304_7d84, 0x32ca_ab7b_40c7_2493,
    0x3c9e_be0a_15c9_bebc, 0x431d_67c4_9c10_0d4c,
    0x4cc5_d4be_cb3e_42b6, 0x597f_299c_fc65_7e2a,
    0x5fcb_6fab_3ad6_faec, 0x6c44_198c_4a47_5817,
  ]

  private var state: [UInt64]
  private var pending = [UInt8](repeating: 0, count: 128)
  private var pendingCount = 0
  private var byteCount: UInt64 = 0
  private let is384: Bool

  init(is384: Bool) {
    self.is384 = is384
    self.state = is384 ? Self.initial384 : Self.initial512
  }

  mutating func update(_ bytes: UnsafeRawBufferPointer) {
    guard let base = bytes.baseAddress, !bytes.isEmpty else { return }
    byteCount &+= UInt64(bytes.count)
    var offset = 0
    if pendingCount > 0 {
      let taken = Swift.min(128 - pendingCount, bytes.count)
      pending.withUnsafeMutableBytes { buffer in
        (buffer.baseAddress! + pendingCount).copyMemory(from: base, byteCount: taken)
      }
      pendingCount += taken
      offset = taken
      guard pendingCount == 128 else { return }
      pending.withUnsafeBytes { compress($0.baseAddress!) }
      pendingCount = 0
    }
    while bytes.count - offset >= 128 {
      compress(base + offset)
      offset += 128
    }
    if offset < bytes.count {
      let remaining = bytes.count - offset
      pending.withUnsafeMutableBytes { buffer in
        buffer.baseAddress!.copyMemory(from: base + offset, byteCount: remaining)
      }
      pendingCount = remaining
    }
  }

  func finalize() -> Data {
    var copy = self
    // The message length is a 128-bit big-endian bit count.
    let bitHigh = byteCount >> 61
    let bitLow = byteCount << 3
    var padding = [UInt8](
      repeating: 0, count: pendingCount < 112 ? 128 - pendingCount : 256 - pendingCount)
    padding[0] = 0x80
    for index in 0..<8 {
      padding[padding.count - 1 - index] = UInt8(truncatingIfNeeded: bitLow >> UInt64(8 * index))
      padding[padding.count - 9 - index] = UInt8(truncatingIfNeeded: bitHigh >> UInt64(8 * index))
    }
    padding.withUnsafeBytes { copy.update($0) }
    var digest = Data(capacity: 64)
    for word in copy.state.prefix(is384 ? 6 : 8) {
      for shift in stride(from: 56, through: 0, by: -8) {
        digest.append(UInt8(truncatingIfNeeded: word >> UInt64(shift)))
      }
    }
    return digest
  }

  private mutating func compress(_ block: UnsafeRawPointer) {
    withUnsafeTemporaryAllocation(of: UInt64.self, capacity: 80) { schedule in
      for index in 0..<16 {
        schedule[index] = UInt64(
          bigEndian: block.loadUnaligned(fromByteOffset: index &* 8, as: UInt64.self))
      }
      for index in 16..<80 {
        let early = schedule[index &- 15]
        let late = schedule[index &- 2]
        let sigma0 = rotateRight(early, 1) ^ rotateRight(early, 8) ^ (early >> 7)
        let sigma1 = rotateRight(late, 19) ^ rotateRight(late, 61) ^ (late >> 6)
        schedule[index] = schedule[index &- 16] &+ sigma0 &+ schedule[index &- 7] &+ sigma1
      }
      var a = state[0]
      var b = state[1]
      var c = state[2]
      var d = state[3]
      var e = state[4]
      var f = state[5]
      var g = state[6]
      var h = state[7]
      Self.constants.withUnsafeBufferPointer { constants in
        for index in 0..<80 {
          let sum1 = rotateRight(e, 14) ^ rotateRight(e, 18) ^ rotateRight(e, 41)
          let choice = (e & f) ^ (~e & g)
          let temporary1 = h &+ sum1 &+ choice &+ constants[index] &+ schedule[index]
          let sum0 = rotateRight(a, 28) ^ rotateRight(a, 34) ^ rotateRight(a, 39)
          let majority = (a & b) ^ (a & c) ^ (b & c)
          h = g
          g = f
          f = e
          e = d &+ temporary1
          d = c
          c = b
          b = a
          a = temporary1 &+ sum0 &+ majority
        }
      }
      state[0] &+= a
      state[1] &+= b
      state[2] &+= c
      state[3] &+= d
      state[4] &+= e
      state[5] &+= f
      state[6] &+= g
      state[7] &+= h
    }
  }
}

@inline(__always)
private func rotateRight(_ value: UInt32, _ amount: UInt32) -> UInt32 {
  (value >> amount) | (value << (32 &- amount))
}

@inline(__always)
private func rotateRight(_ value: UInt64, _ amount: UInt64) -> UInt64 {
  (value >> amount) | (value << (64 &- amount))
}
