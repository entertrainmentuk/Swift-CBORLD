import Foundation
import XCTest

@testable import CBORLD

/// The digest APIs use CryptoKit on Apple platforms and the portable
/// implementation elsewhere. These tests keep both paths compiled and require
/// them to agree byte for byte, so the portable code remains a correctness
/// oracle for the accelerated one.
final class SHA2AgreementTests: XCTestCase {
  func testPortableImplementationMatchesPublishedVectors() {
    let vectors: [(CBORLDHashAlgorithm, String, String)] = [
      (.sha256, "", "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"),
      (.sha256, "abc", "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"),
      (
        .sha256, "abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq",
        "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1"
      ),
      (
        .sha384, "abc",
        "cb00753f45a35e8bb5a03d699ac65007272c32ab0eded1631a8b605a43ff5bed"
          + "8086072ba1e7cc2358baeca134c825a7"
      ),
      (
        .sha512, "abc",
        "ddaf35a193617abacc417349ae20413112e6fa4e89a97ea20a9eeee64b55d39a"
          + "2192992a274fc1a836ba3c23a3feebbd454d4423643ce80e2a9ac94fa54ca49f"
      ),
      (
        .sha512,
        "abcdefghbcdefghicdefghijdefghijkefghijklfghijklmghijklmnhijklmno"
          + "ijklmnopjklmnopqklmnopqrlmnopqrsmnopqrstnopqrstu",
        "8e959b75dae313da8cf4f72814fc143f8f7779c6eb9f7fa17299aeadb6889018"
          + "501d289e4900f7e4331b99dec4b5433ac7d329eeb6dd26545e96e55b874be909"
      ),
    ]
    for (algorithm, message, expected) in vectors {
      XCTAssertEqual(
        PortableSHA2Hasher.hash(Data(message.utf8), algorithm: algorithm).hexString, expected,
        "\(algorithm) of \"\(message)\"")
      XCTAssertEqual(
        CBORLDSHA2Hasher.hash(Data(message.utf8), algorithm: algorithm).hexString, expected,
        "\(CBORLDSHA2Hasher.implementation) \(algorithm) of \"\(message)\"")
    }
  }

  func testPlatformAndPortableHashersAgreeAcrossLengthsAndChunkings() {
    var generator = SplitMix64(seed: 0x5eed_5a2a)
    let source = Data((0..<1_200).map { _ in UInt8(truncatingIfNeeded: generator.next()) })
    for algorithm in CBORLDHashAlgorithm.allCases {
      // Every length through two SHA-512 blocks crosses each padding boundary.
      for length in 0...300 {
        let message = source.prefix(length)
        let expected = PortableSHA2Hasher.hash(Data(message), algorithm: algorithm)
        XCTAssertEqual(
          CBORLDSHA2Hasher.hash(Data(message), algorithm: algorithm), expected,
          "\(algorithm) length \(length)")
      }
      // Incremental updates with irregular chunk sizes must equal one update.
      for _ in 0..<40 {
        var platform = CBORLDSHA2Hasher(algorithm: algorithm)
        var portable = PortableSHA2Hasher(algorithm: algorithm)
        var offset = 0
        while offset < source.count {
          let size = Int(generator.next() % 150)
          let chunk = source.subdata(in: offset..<min(source.count, offset + size))
          platform.update(data: chunk)
          portable.update(data: chunk)
          offset += size
        }
        let whole = PortableSHA2Hasher.hash(source, algorithm: algorithm)
        XCTAssertEqual(portable.finalize(), whole, "\(algorithm) chunked portable")
        XCTAssertEqual(platform.finalize(), whole, "\(algorithm) chunked platform")
      }
    }
  }

  func testLargeInputAgreesAndMatchesTheMillionAVector() {
    let million = Data(repeating: UInt8(ascii: "a"), count: 1_000_000)
    let expected = "cdc76e5c9914fb9281a1c7e284d73e67f1809a48a497200e046d39ccc7112cd0"
    XCTAssertEqual(PortableSHA2Hasher.hash(million, algorithm: .sha256).hexString, expected)
    XCTAssertEqual(CBORLDSHA2Hasher.hash(million, algorithm: .sha256).hexString, expected)
    let large = million.prefix(131_072)
    for algorithm in [CBORLDHashAlgorithm.sha384, .sha512] {
      XCTAssertEqual(
        CBORLDSHA2Hasher.hash(large, algorithm: algorithm),
        PortableSHA2Hasher.hash(large, algorithm: algorithm))
    }
  }

  func testTransportDigestUsesTheSameBytesOnEveryPath() throws {
    let bytes = try CBORLD.encodeUncompressed(["note": "hash me", "count": 3])
    for algorithm in CBORLDHashAlgorithm.allCases {
      let digest = CBORLD.transportDigest(of: bytes, algorithm: algorithm)
      XCTAssertEqual(digest.bytes, PortableSHA2Hasher.hash(bytes, algorithm: algorithm))
      let chunks = stride(from: 0, to: bytes.count, by: 3).map {
        bytes.subdata(in: $0..<min(bytes.count, $0 + 3))
      }
      XCTAssertEqual(CBORLD.transportDigest(chunks: chunks, algorithm: algorithm), digest)
    }
  }
}
