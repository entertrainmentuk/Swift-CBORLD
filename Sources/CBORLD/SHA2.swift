import Foundation

/// Dependency-free incremental SHA-2 used on every supported platform. Keeping
/// one implementation avoids an Apple/Linux semantic split and preserves true
/// streaming file digests without buffering the complete input.
struct CBORLDSHA2Hasher {
  private enum Storage {
    case sha256(SHA256State)
    case sha512(SHA512State)
  }

  private var storage: Storage

  init(algorithm: CBORLDHashAlgorithm) {
    switch algorithm {
    case .sha256: storage = .sha256(SHA256State())
    case .sha384: storage = .sha512(SHA512State(is384: true))
    case .sha512: storage = .sha512(SHA512State(is384: false))
    }
  }

  mutating func update(data: Data) {
    switch storage {
    case .sha256(var state):
      state.update(data)
      storage = .sha256(state)
    case .sha512(var state):
      state.update(data)
      storage = .sha512(state)
    }
  }

  mutating func finalize() -> Data {
    switch storage {
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

private struct SHA256State {
  private static let initial: [UInt32] = [
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

  private var state = Self.initial
  private var buffer: [UInt8] = []
  private var byteCount: UInt64 = 0

  mutating func update(_ data: Data) {
    byteCount &+= UInt64(data.count)
    consume([UInt8](data))
  }

  func finalize() -> Data {
    var copy = self
    let bitCount = copy.byteCount &* 8
    var final = copy.buffer
    final.append(0x80)
    while final.count % 64 != 56 { final.append(0) }
    appendBigEndian(bitCount, to: &final)
    copy.buffer.removeAll(keepingCapacity: false)
    copy.consume(final)
    var digest = Data(capacity: 32)
    for word in copy.state { appendBigEndian(word, to: &digest) }
    return digest
  }

  private mutating func consume(_ bytes: [UInt8]) {
    var index = 0
    if !buffer.isEmpty {
      let needed = min(64 - buffer.count, bytes.count)
      buffer.append(contentsOf: bytes[0..<needed])
      index += needed
      if buffer.count == 64 {
        process(buffer, offset: 0)
        buffer.removeAll(keepingCapacity: true)
      }
    }
    while index + 64 <= bytes.count {
      process(bytes, offset: index)
      index += 64
    }
    if index < bytes.count { buffer.append(contentsOf: bytes[index...]) }
  }

  private mutating func process(_ bytes: [UInt8], offset: Int) {
    var schedule = [UInt32](repeating: 0, count: 64)
    for index in 0..<16 {
      let start = offset + index * 4
      schedule[index] =
        UInt32(bytes[start]) << 24 | UInt32(bytes[start + 1]) << 16
        | UInt32(bytes[start + 2]) << 8 | UInt32(bytes[start + 3])
    }
    for index in 16..<64 {
      let s0 =
        rotate(schedule[index - 15], 7) ^ rotate(schedule[index - 15], 18)
        ^ (schedule[index - 15] >> 3)
      let s1 =
        rotate(schedule[index - 2], 17) ^ rotate(schedule[index - 2], 19)
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
      let sum1 = rotate(e, 6) ^ rotate(e, 11) ^ rotate(e, 25)
      let choice = (e & f) ^ (~e & g)
      let temporary1 = h &+ sum1 &+ choice &+ Self.constants[index] &+ schedule[index]
      let sum0 = rotate(a, 2) ^ rotate(a, 13) ^ rotate(a, 22)
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
    state[0] &+= a
    state[1] &+= b
    state[2] &+= c
    state[3] &+= d
    state[4] &+= e
    state[5] &+= f
    state[6] &+= g
    state[7] &+= h
  }

  private func rotate(_ value: UInt32, _ amount: UInt32) -> UInt32 {
    (value >> amount) | (value << (32 - amount))
  }
}

private struct SHA512State {
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
  private var buffer: [UInt8] = []
  private var byteCount: UInt64 = 0
  private let is384: Bool

  init(is384: Bool) {
    self.is384 = is384
    self.state = is384 ? Self.initial384 : Self.initial512
  }

  mutating func update(_ data: Data) {
    byteCount &+= UInt64(data.count)
    consume([UInt8](data))
  }

  func finalize() -> Data {
    var copy = self
    let bitHigh = copy.byteCount >> 61
    let bitLow = copy.byteCount << 3
    var final = copy.buffer
    final.append(0x80)
    while final.count % 128 != 112 { final.append(0) }
    appendBigEndian(bitHigh, to: &final)
    appendBigEndian(bitLow, to: &final)
    copy.buffer.removeAll(keepingCapacity: false)
    copy.consume(final)
    let wordCount = copy.is384 ? 6 : 8
    var digest = Data(capacity: wordCount * 8)
    for word in copy.state.prefix(wordCount) { appendBigEndian(word, to: &digest) }
    return digest
  }

  private mutating func consume(_ bytes: [UInt8]) {
    var index = 0
    if !buffer.isEmpty {
      let needed = min(128 - buffer.count, bytes.count)
      buffer.append(contentsOf: bytes[0..<needed])
      index += needed
      if buffer.count == 128 {
        process(buffer, offset: 0)
        buffer.removeAll(keepingCapacity: true)
      }
    }
    while index + 128 <= bytes.count {
      process(bytes, offset: index)
      index += 128
    }
    if index < bytes.count { buffer.append(contentsOf: bytes[index...]) }
  }

  private mutating func process(_ bytes: [UInt8], offset: Int) {
    var schedule = [UInt64](repeating: 0, count: 80)
    for index in 0..<16 {
      let start = offset + index * 8
      var word: UInt64 = 0
      for byte in bytes[start..<(start + 8)] { word = (word << 8) | UInt64(byte) }
      schedule[index] = word
    }
    for index in 16..<80 {
      let s0 =
        rotate(schedule[index - 15], 1) ^ rotate(schedule[index - 15], 8)
        ^ (schedule[index - 15] >> 7)
      let s1 =
        rotate(schedule[index - 2], 19) ^ rotate(schedule[index - 2], 61)
        ^ (schedule[index - 2] >> 6)
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
    for index in 0..<80 {
      let sum1 = rotate(e, 14) ^ rotate(e, 18) ^ rotate(e, 41)
      let choice = (e & f) ^ (~e & g)
      let temporary1 = h &+ sum1 &+ choice &+ Self.constants[index] &+ schedule[index]
      let sum0 = rotate(a, 28) ^ rotate(a, 34) ^ rotate(a, 39)
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
    state[0] &+= a
    state[1] &+= b
    state[2] &+= c
    state[3] &+= d
    state[4] &+= e
    state[5] &+= f
    state[6] &+= g
    state[7] &+= h
  }

  private func rotate(_ value: UInt64, _ amount: UInt64) -> UInt64 {
    (value >> amount) | (value << (64 - amount))
  }
}

private func appendBigEndian<T: FixedWidthInteger>(_ value: T, to bytes: inout [UInt8]) {
  for shift in stride(from: T.bitWidth - 8, through: 0, by: -8) {
    bytes.append(UInt8(truncatingIfNeeded: value >> shift))
  }
}

private func appendBigEndian<T: FixedWidthInteger>(_ value: T, to data: inout Data) {
  var value = value.bigEndian
  withUnsafeBytes(of: &value) { data.append(contentsOf: $0) }
}
