import CBORLD
import Foundation
import XCTest

@testable import CBORLDCommandLine

final class CommandLineToolTests: XCTestCase {
  private let contextURL = "https://example.com/contexts/notes-v1"
  private let context: JSONValue = [
    "@context": [
      "type": "@type",
      "Note": "https://example.com/Note",
      "summary": "https://example.com/summary",
    ]
  ]
  private var document: JSONValue {
    ["@context": .string(contextURL), "type": "Note", "summary": "From the command line"]
  }

  private func workspace() throws -> Workspace {
    let workspace = Workspace()
    workspace.files["context.json"] = try context.data()
    workspace.files["note.json"] = try document.data()
    return workspace
  }

  // MARK: Round trips

  func testEncodeThenDecodeRestoresTheDocumentAndMatchesTheLibrary() async throws {
    let workspace = try workspace()
    let pin = try CBORLD.contextFingerprint(of: context).description
    let encodeStatus = await workspace.run(
      "encode", "note.json", "--context", "\(contextURL)=context.json",
      "--pin", "\(contextURL)=\(pin)", "--require-pins", "-o", "note.cborld")
    XCTAssertEqual(encodeStatus, 0, workspace.standardError)
    let bytes = try XCTUnwrap(workspace.files["note.cborld"])
    let registry = CBORLDContextRegistry(documents: [contextURL: context])
    let expected = try await CBORLD.encode(
      document,
      options: .init(registryEntryID: 1, contextDocumentLoader: registry.contextDocumentLoader))
    XCTAssertEqual(bytes, expected)

    let decodeStatus = await workspace.run(
      "decode", "note.cborld", "--context=\(contextURL)=context.json", "--untrusted",
      "--compact")
    XCTAssertEqual(decodeStatus, 0, workspace.standardError)
    XCTAssertEqual(try JSONValue(data: Data(workspace.standardOutput.utf8)), document)
    XCTAssertFalse(workspace.standardOutput.dropLast().contains("\n"))
  }

  func testHexStandardStreamsAndDeterministicModes() async throws {
    let workspace = try workspace()
    let keys: JSONValue = ["b": 1, "aa": 2]
    workspace.standardInput = try keys.data()
    let status = await workspace.run(
      "encode", "--registry-entry", "0", "--mode", "core-deterministic", "--hex")
    XCTAssertEqual(status, 0, workspace.standardError)
    let hex = workspace.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines)
    let expected = try CBORLD.encodeUncompressed(
      ["b": 1, "aa": 2], serializationMode: .coreDeterministic)
    XCTAssertEqual(hex, CommandContext.hex(expected))

    workspace.reset(standardInput: Data(("0x" + hex.uppercased() + "\n").utf8))
    let decodeStatus = await workspace.run("decode", "-", "--hex", "--untrusted")
    XCTAssertEqual(decodeStatus, 0, workspace.standardError)
    XCTAssertEqual(try JSONValue(data: Data(workspace.standardOutput.utf8)), ["b": 1, "aa": 2])
  }

  func testRegistryFilesSelectAProcessingModel() async throws {
    let workspace = try workspace()
    workspace.files["entry.json"] = Data(
      #"{"id": 100, "processingModel": {"semanticCompression": false}}"#.utf8)
    let status = await workspace.run(
      "encode", "note.json", "--registry", "entry.json", "--registry-entry", "100",
      "--context", "\(contextURL)=context.json", "--hex")
    XCTAssertEqual(status, 0, workspace.standardError)
    let hex = workspace.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines)
    XCTAssertTrue(hex.hasPrefix("d9cb1d821864"), hex)

    workspace.reset(standardInput: Data(hex.utf8))
    let decodeStatus = await workspace.run(
      "decode", "--hex", "--registry", "entry.json", "--context", "\(contextURL)=context.json")
    XCTAssertEqual(decodeStatus, 0, workspace.standardError)
    XCTAssertEqual(try JSONValue(data: Data(workspace.standardOutput.utf8)), document)
  }

  // MARK: Inspection and digests

  func testInspectDescribesTheEnvelopeInTextAndJSON() async throws {
    let workspace = Workspace()
    let bytes = try CBORLD.encodeUncompressed(["a": 1])
    workspace.files["doc.cborld"] = bytes
    let status = await workspace.run("inspect", "doc.cborld", "--untrusted-deterministic")
    XCTAssertEqual(status, 0, workspace.standardError)
    XCTAssertTrue(workspace.standardOutput.contains("format: cbor-ld-1.0"))
    XCTAssertTrue(workspace.standardOutput.contains("registry entry: 0"))
    XCTAssertTrue(workspace.standardOutput.contains("compressed: no"))
    XCTAssertTrue(
      workspace.standardOutput.contains(CBORLD.transportDigest(of: bytes).description))

    workspace.reset()
    let jsonStatus = await workspace.run("inspect", "doc.cborld", "--json")
    XCTAssertEqual(jsonStatus, 0)
    let decoded = try JSONDecoder().decode(
      CBORLDInspection.self, from: Data(workspace.standardOutput.utf8))
    XCTAssertEqual(decoded, try CBORLD.inspect(bytes))
  }

  func testDigestKindsMatchTheLibrary() async throws {
    let workspace = try workspace()
    workspace.files["bytes.bin"] = Data([0xd9, 0xcb, 0x1d, 0x82, 0x00, 0xa0])
    let cases: [([String], String)] = [
      (
        ["digest", "bytes.bin"],
        CBORLD.transportDigest(of: Data([0xd9, 0xcb, 0x1d, 0x82, 0x00, 0xa0])).description
      ),
      (
        ["digest", "note.json", "--kind", "structure", "--algorithm", "sha512"],
        try CBORLD.structuralFingerprint(of: document, algorithm: .sha512).description
      ),
      (
        ["digest", "context.json", "--kind=context", "--algorithm", "sha2-384"],
        try CBORLD.contextFingerprint(of: context, algorithm: .sha384).description
      ),
    ]
    for (arguments, expected) in cases {
      workspace.reset()
      let status = await workspace.run(arguments)
      XCTAssertEqual(status, 0, workspace.standardError)
      XCTAssertEqual(workspace.standardOutput, expected + "\n")
    }
  }

  // MARK: Verification

  func testVerifyReportsEachCheckAndExitsWithOneOnMismatch() async throws {
    let workspace = try workspace()
    let pin = try CBORLD.contextFingerprint(of: context)
    let encodeStatus = await workspace.run(
      "encode", "note.json", "--context", "\(contextURL)=context.json", "-o", "note.cborld",
      "--write-manifest", "note.manifest.json")
    XCTAssertEqual(encodeStatus, 0, workspace.standardError)
    let bytes = try XCTUnwrap(workspace.files["note.cborld"])
    let transport = CBORLD.transportDigest(of: bytes)
    let structure = try CBORLD.structuralFingerprint(of: document)

    workspace.reset()
    let matching = await workspace.run(
      "verify", "note.cborld", "--transport", transport.description,
      "--structure", structure.description, "--context", "\(contextURL)=context.json",
      "--pin", "\(contextURL)=\(pin)")
    XCTAssertEqual(matching, 0, workspace.standardOutput)
    XCTAssertTrue(workspace.standardOutput.contains("verified: transport-digest"))
    XCTAssertTrue(workspace.standardOutput.contains("verified: structural-fingerprint"))
    XCTAssertTrue(workspace.standardOutput.hasSuffix("result: valid\n"))

    workspace.reset()
    let wrong = CBORLD.transportDigest(of: Data("other".utf8))
    let mismatched = await workspace.run(
      "verify", "note.cborld", "--transport", wrong.description, "--json")
    XCTAssertEqual(mismatched, 1)
    let report = try JSONDecoder.iso8601Test.decode(
      CBORLDVerificationReport.self, from: Data(workspace.standardOutput.utf8))
    XCTAssertFalse(report.isValid)
    XCTAssertEqual(report.checks.first { $0.kind == .transportDigest }?.status, .mismatch)

    workspace.reset()
    let manifestStatus = await workspace.run(
      "verify", "note.cborld", "--manifest", "note.manifest.json",
      "--context", "\(contextURL)=context.json")
    XCTAssertEqual(manifestStatus, 0, workspace.standardOutput)

    workspace.files["note.cborld"]?[bytes.count - 1] ^= 0x01
    workspace.reset()
    let tampered = await workspace.run(
      "verify", "note.cborld", "--manifest", "note.manifest.json",
      "--context", "\(contextURL)=context.json")
    XCTAssertEqual(tampered, 1)
    XCTAssertTrue(workspace.standardOutput.hasSuffix("result: invalid\n"))
  }

  // MARK: Errors

  func testProcessingErrorsReportTheirCodeAndExitWithOne() async throws {
    let workspace = try workspace()
    let unknown = await workspace.run("encode", "note.json", "--hex")
    XCTAssertEqual(unknown, 1)
    XCTAssertTrue(workspace.standardError.contains("ERR_UNKNOWN_CONTEXT"), workspace.standardError)

    workspace.reset()
    let unpinned = await workspace.run(
      "encode", "note.json", "--hex", "--require-pins", "--context", "\(contextURL)=context.json")
    XCTAssertEqual(unpinned, 1)
    XCTAssertTrue(workspace.standardError.contains("ERR_UNPINNED_CONTEXT"), workspace.standardError)

    // 23 written with a one-byte argument is valid CBOR but not preferred.
    workspace.reset(standardInput: Data("d9cb1d8200811817".utf8))
    let widened = await workspace.run("decode", "--hex", "--untrusted-deterministic")
    XCTAssertEqual(widened, 1)
    XCTAssertTrue(
      workspace.standardError.contains("ERR_NON_PREFERRED_INTEGER"), workspace.standardError)
    XCTAssertTrue(workspace.standardError.contains("at byte offset"), workspace.standardError)

    workspace.reset()
    let limited = await workspace.run(
      "encode", "note.json", "--hex", "--context", "\(contextURL)=context.json",
      "--max-output-bytes", "8")
    XCTAssertEqual(limited, 1)
    XCTAssertTrue(workspace.standardError.contains("ERR_RESOURCE_LIMIT"))

    workspace.reset()
    let missingFile = await workspace.run("decode", "missing.cborld")
    XCTAssertEqual(missingFile, 1)
    XCTAssertTrue(workspace.standardError.hasPrefix("error: "))
  }

  func testUsageErrorsExitWithTwo() async throws {
    let workspace = try workspace()
    let invocations: [[String]] = [
      [],
      ["frobnicate"],
      ["help", "frobnicate"],
      ["decode", "--bogus"],
      ["decode", "-x"],
      ["decode", "--output"],
      ["decode", "--hex=yes"],
      ["decode", "a", "b"],
      ["decode", "--untrusted", "--untrusted-deterministic", "--hex"],
      ["encode", "note.json", "--mode", "fast", "--hex"],
      ["encode", "note.json", "--registry-entry", "-1", "--hex"],
      ["encode", "note.json", "--context", "nofile", "--hex"],
      ["encode", "note.json", "--context", "u=context.json", "--context", "u=context.json"],
      ["encode", "note.json", "--pin", "u=\(CBORLD.transportDigest(of: Data()))"],
      ["encode", "note.json", "--pin", "u=nonsense"],
      ["encode", "note.json", "--context", "\(contextURL)=context.json", "-o", "a", "-o", "b"],
      ["encode", "note.json", "--context", "\(contextURL)=context.json"],
      ["digest", "note.json", "--kind", "weird"],
      ["digest", "note.json", "--algorithm", "md5"],
      ["verify", "note.json"],
      ["verify", "note.json", "--manifest", "m", "--transport", "x"],
    ]
    for arguments in invocations {
      workspace.reset()
      workspace.isTerminal = true
      let status = await workspace.run(arguments)
      XCTAssertEqual(status, 2, "\(arguments): \(workspace.standardError)")
      XCTAssertTrue(workspace.standardError.contains("cborld"), "\(arguments)")
    }
    workspace.reset(standardInput: Data("0x123".utf8))
    let odd = await workspace.run("decode", "--hex")
    XCTAssertEqual(odd, 2)
    workspace.reset(standardInput: Data("zz".utf8))
    let notHex = await workspace.run("decode", "--hex")
    XCTAssertEqual(notHex, 2)
  }

  func testStandardEnvironmentUsesTheFileSystem() throws {
    let environment = ToolEnvironment.standard
    let path = FileManager.default.temporaryDirectory
      .appendingPathComponent("cborld-\(UUID().uuidString).bin").path
    defer { try? FileManager.default.removeItem(atPath: path) }
    try environment.writeFile(path, Data([1, 2, 3]))
    XCTAssertEqual(try environment.readFile(path), Data([1, 2, 3]))
    XCTAssertThrowsError(try environment.readFile(path + ".missing"))
  }

  func testHelpAndVersion() async throws {
    let workspace = Workspace()
    for arguments in [["help"], ["--help"], ["-h"]] {
      workspace.reset()
      let status = await workspace.run(arguments)
      XCTAssertEqual(status, 0)
      XCTAssertTrue(workspace.standardOutput.contains("Commands:"))
    }
    for command in Command.allCases {
      workspace.reset()
      let viaHelp = await workspace.run("help", command.rawValue)
      XCTAssertEqual(viaHelp, 0)
      XCTAssertTrue(workspace.standardOutput.hasPrefix("Usage: cborld \(command.rawValue)"))
      workspace.reset()
      let viaFlag = await workspace.run(command.rawValue, "--help")
      XCTAssertEqual(viaFlag, 0)
      XCTAssertTrue(workspace.standardOutput.hasPrefix("Usage: cborld \(command.rawValue)"))
    }
    workspace.reset()
    let version = await workspace.run("--version")
    XCTAssertEqual(version, 0)
    XCTAssertEqual(workspace.standardOutput, "cborld \(CommandLineTool.version)\n")
  }
}

// MARK: - In-memory environment

/// Files and standard streams for one test, shared with the tool's closures.
private final class Workspace: @unchecked Sendable {
  private let lock = NSLock()
  private var _files: [String: Data] = [:]
  private var _output = Data()
  private var _error = ""
  private var _input = Data()
  private var _isTerminal = false

  var files: [String: Data] {
    get { lock.withLock { _files } }
    set { lock.withLock { _files = newValue } }
  }

  var standardInput: Data {
    get { lock.withLock { _input } }
    set { lock.withLock { _input = newValue } }
  }

  var isTerminal: Bool {
    get { lock.withLock { _isTerminal } }
    set { lock.withLock { _isTerminal = newValue } }
  }

  var standardOutput: String { lock.withLock { String(decoding: _output, as: UTF8.self) } }
  var standardError: String { lock.withLock { _error } }

  func reset(standardInput: Data = Data()) {
    lock.withLock {
      _output = Data()
      _error = ""
      _input = standardInput
      _isTerminal = false
    }
  }

  func run(_ arguments: String...) async -> Int32 {
    await run(arguments)
  }

  func run(_ arguments: [String]) async -> Int32 {
    let environment = ToolEnvironment(
      readStandardInput: { [self] in standardInput },
      writeStandardOutput: { [self] data in lock.withLock { _output.append(data) } },
      writeStandardError: { [self] text in lock.withLock { _error += text } },
      readFile: { [self] path in
        guard let data = files[path] else {
          throw CocoaError(.fileReadNoSuchFile, userInfo: [NSFilePathErrorKey: path])
        }
        return data
      },
      writeFile: { [self] path, data in files[path] = data },
      standardOutputIsTerminal: isTerminal)
    return await CommandLineTool.run(arguments, environment: environment)
  }
}

extension JSONDecoder {
  fileprivate static var iso8601Test: JSONDecoder {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return decoder
  }
}
