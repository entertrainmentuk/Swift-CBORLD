import CBORLD
import Foundation

/// One invocation of a command: its parsed arguments and where it reads and
/// writes.
struct CommandContext {
  let arguments: ParsedArguments
  let environment: ToolEnvironment

  // MARK: Input and output

  /// The raw input, from the input file or standard input.
  func inputData() throws -> Data {
    let path = try arguments.inputPath()
    if let path, path != "-" {
      return try environment.readFile(path)
    }
    return try environment.readStandardInput()
  }

  /// CBOR-LD bytes from the input, which is hexadecimal text with `--hex`.
  func inputBytes() throws -> Data {
    let data = try inputData()
    guard arguments.flag("hex") else { return data }
    return try Self.bytes(fromHex: String(decoding: data, as: UTF8.self))
  }

  func inputJSON() throws -> JSONValue {
    try JSONValue(data: try inputData())
  }

  /// Writes bytes to `--output`, or to standard output. Binary output is
  /// written as hexadecimal text with `--hex`, and is never written to a
  /// terminal.
  func emitBytes(_ bytes: Data) throws {
    if arguments.flag("hex") {
      try emit(Data((Self.hex(bytes) + "\n").utf8))
      return
    }
    if try arguments.value("output") == nil, environment.standardOutputIsTerminal {
      throw UsageError(
        "Refusing to write binary CBOR-LD to a terminal; use --output FILE or --hex.")
    }
    try emit(bytes)
  }

  func emitText(_ text: String) throws {
    try emit(Data((text.hasSuffix("\n") ? text : text + "\n").utf8))
  }

  private func emit(_ data: Data) throws {
    if let path = try arguments.value("output") {
      try environment.writeFile(path, data)
    } else {
      environment.writeStandardOutput(data)
    }
  }

  func jsonText(_ value: JSONValue) throws -> String {
    let formatting: JSONEncoder.OutputFormatting =
      arguments.flag("compact")
      ? [.sortedKeys, .withoutEscapingSlashes]
      : [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    return String(decoding: try value.data(outputFormatting: formatting), as: UTF8.self)
  }

  func jsonText<T: Encodable>(encoding value: T) throws -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    encoder.dateEncodingStrategy = .iso8601
    return String(decoding: try encoder.encode(value), as: UTF8.self)
  }

  // MARK: Shared options

  /// `--untrusted` or `--untrusted-deterministic`; the package defaults
  /// otherwise.
  func decodingConfiguration() throws -> CBORLDDecodingConfiguration {
    switch (arguments.flag("untrusted"), arguments.flag("untrusted-deterministic")) {
    case (true, true):
      throw UsageError("Use either --untrusted or --untrusted-deterministic, not both.")
    case (true, false): return .untrustedCompatible
    case (false, true): return .untrustedDeterministic
    case (false, false): return .permissive
    }
  }

  /// Contexts from `--context URL=FILE`, pinned by `--pin URL=DIGEST`. The
  /// registry has no fallback, so any other context fails to load.
  func contextRegistry() throws -> CBORLDContextRegistry {
    var documents: [String: JSONValue] = [:]
    for assignment in arguments.values("context") {
      let (url, path) = try Self.split(assignment, option: "context")
      guard documents[url] == nil else {
        throw UsageError("Context \(url) is given more than once.")
      }
      documents[url] = try JSONValue(data: try environment.readFile(path))
    }
    var pins: [String: CBORLDDigest] = [:]
    for assignment in arguments.values("pin") {
      let (url, text) = try Self.split(assignment, option: "pin")
      let digest = try Self.digest(text)
      guard digest.domain == .contextDocument else {
        throw UsageError("The pin for \(url) must be a context-document digest.")
      }
      guard pins[url] == nil else {
        throw UsageError("Context \(url) is pinned more than once.")
      }
      pins[url] = digest
    }
    return CBORLDContextRegistry(documents: documents, expectedFingerprints: pins)
  }

  /// With `--require-pins`, every context must be pinned.
  func contextPolicy() -> CBORLDContextLoadingPolicy {
    var policy = CBORLDContextLoadingPolicy()
    policy.requiresPinnedContexts = arguments.flag("require-pins")
    return policy
  }

  /// Registry entries from `--registry FILE`, in the editor's draft JSON shape.
  func registryEntryLoader() throws -> CBORLDRegistryEntryLoader? {
    var entries: [UInt64: CBORLDRegistryEntry] = [:]
    for path in arguments.values("registry") {
      let entry = try JSONDecoder().decode(
        CBORLDRegistryEntry.self, from: try environment.readFile(path))
      guard entries[entry.id] == nil else {
        throw UsageError("Registry entry \(entry.id) is given more than once.")
      }
      entries[entry.id] = entry
    }
    guard !entries.isEmpty else { return nil }
    return { [entries] id in entries[id] }
  }

  // MARK: Value parsing

  static func split(_ assignment: String, option: String) throws -> (String, String) {
    guard let equals = assignment.lastIndex(of: "="),
      equals != assignment.startIndex, assignment.index(after: equals) != assignment.endIndex
    else {
      throw UsageError("--\(option) expects URL=VALUE, not \(assignment).")
    }
    return (
      String(assignment[..<equals]), String(assignment[assignment.index(after: equals)...])
    )
  }

  /// Parses the `algorithm:domain:vN:hex` form that digests print.
  static func digest(_ text: String) throws -> CBORLDDigest {
    let parts = text.split(separator: ":", omittingEmptySubsequences: false)
    guard parts.count == 4,
      let algorithm = CBORLDHashAlgorithm(rawValue: String(parts[0])),
      let domain = CBORLDHashDomain(rawValue: String(parts[1])),
      parts[2].first == "v", let version = UInt8(parts[2].dropFirst())
    else {
      throw UsageError(
        "\(text) is not a digest; expected ALGORITHM:DOMAIN:vVERSION:HEX, such as sha2-256:encoded-bytes:v1:…"
      )
    }
    return try CBORLDDigest(
      algorithm: algorithm, domain: domain, version: version, hex: String(parts[3]))
  }

  static func algorithm(_ name: String?) throws -> CBORLDHashAlgorithm {
    switch name {
    case nil, "sha256", "sha2-256": return .sha256
    case "sha384", "sha2-384": return .sha384
    case "sha512", "sha2-512": return .sha512
    case .some(let other):
      throw UsageError("Unknown digest algorithm \(other); use sha256, sha384, or sha512.")
    }
  }

  static func serializationMode(_ name: String?) throws -> CBORLDSerializationMode {
    guard let name else { return .compatibility }
    guard let mode = CBORLDSerializationMode(rawValue: name) else {
      let names = CBORLDSerializationMode.allCases.map(\.rawValue).joined(separator: ", ")
      throw UsageError("Unknown serialization mode \(name); use one of \(names).")
    }
    return mode
  }

  static func integer(_ text: String?, option: String) throws -> Int? {
    guard let text else { return nil }
    guard let value = Int(text), value >= 0 else {
      throw UsageError("--\(option) expects a non-negative integer, not \(text).")
    }
    return value
  }

  static func bytes(fromHex text: String) throws -> Data {
    var digits = text.filter { !$0.isWhitespace }
    if digits.hasPrefix("0x") || digits.hasPrefix("0X") { digits.removeFirst(2) }
    guard digits.count.isMultiple(of: 2) else {
      throw UsageError("Hexadecimal input has an odd number of digits.")
    }
    var bytes = Data(capacity: digits.count / 2)
    var index = digits.startIndex
    while index < digits.endIndex {
      let next = digits.index(index, offsetBy: 2)
      guard let byte = UInt8(digits[index..<next], radix: 16) else {
        throw UsageError("Input is not hexadecimal: \(digits[index..<next]).")
      }
      bytes.append(byte)
      index = next
    }
    return bytes
  }

  static func hex(_ bytes: Data) -> String {
    bytes.map { String(format: "%02x", $0) }.joined()
  }
}

// MARK: - Commands

extension CommandContext {
  /// JSON-LD in, CBOR-LD out.
  func encode() async throws -> Int32 {
    let document = try inputJSON()
    let registry = try contextRegistry()
    var limits = CBORLDEncodingLimits()
    if let maximum = try Self.integer(
      arguments.value("max-output-bytes"), option: "max-output-bytes")
    {
      limits.maximumOutputBytes = maximum
    }
    let registryEntryID = try Self.integer(
      arguments.value("registry-entry"), option: "registry-entry")
    let options = CBORLDEncodingOptions(
      serializationMode: try Self.serializationMode(arguments.value("mode")),
      registryEntryID: UInt64(registryEntryID ?? 1),
      registryEntryLoader: try registryEntryLoader(),
      limits: limits,
      contextPolicy: contextPolicy(),
      contextDocumentLoader: registry.contextDocumentLoader)
    let bytes = try await CBORLD.encode(document, options: options)

    if let manifestPath = try arguments.value("write-manifest") {
      let manifest = try CBORLD.integrityManifest(
        for: bytes,
        document: document,
        contextDocuments: registry.documents,
        declaredSerializationMode: options.serializationMode)
      try environment.writeFile(manifestPath, Data((try jsonText(encoding: manifest) + "\n").utf8))
    }
    try emitBytes(bytes)
    return 0
  }

  /// CBOR-LD in, JSON-LD out.
  func decode() async throws -> Int32 {
    let bytes = try inputBytes()
    let registry = try contextRegistry()
    let options = CBORLDDecodingOptions(
      configuration: try decodingConfiguration(),
      registryEntryLoader: try registryEntryLoader(),
      contextPolicy: contextPolicy(),
      contextDocumentLoader: registry.contextDocumentLoader)
    let document = try await CBORLD.decode(bytes, options: options)
    try emitText(try jsonText(document))
    return 0
  }

  /// Envelope and transport facts, without loading contexts.
  func inspect() throws -> Int32 {
    let inspection = try CBORLD.inspect(inputBytes(), configuration: decodingConfiguration())
    if arguments.flag("json") {
      try emitText(try jsonText(encoding: inspection))
      return 0
    }
    try emitText(
      """
      format: \(inspection.format.rawValue)
      registry entry: \(inspection.registryEntryID.map(String.init) ?? "none")
      compressed: \(inspection.payloadIsCompressed ? "yes" : "no")
      bytes: \(inspection.byteCount)
      transport digest: \(inspection.transportDigest)
      payload: \(inspection.payloadDescription)
      """)
    return 0
  }

  /// A transport digest, structural fingerprint, or context fingerprint.
  func digest() throws -> Int32 {
    let algorithm = try Self.algorithm(arguments.value("algorithm"))
    let digest: CBORLDDigest
    switch try arguments.value("kind") ?? "transport" {
    case "transport":
      digest = CBORLD.transportDigest(of: try inputBytes(), algorithm: algorithm)
    case "structure":
      digest = try CBORLD.structuralFingerprint(of: try inputJSON(), algorithm: algorithm)
    case "context":
      digest = try CBORLD.contextFingerprint(of: try inputJSON(), algorithm: algorithm)
    case let other:
      throw UsageError("Unknown digest kind \(other); use transport, structure, or context.")
    }
    try emitText(digest.description)
    return 0
  }

  /// Checks bytes against expected digests or a manifest. Exits with 1 when
  /// any check fails.
  func verify() async throws -> Int32 {
    let bytes = try inputBytes()
    let registry = try contextRegistry()
    let configuration = try decodingConfiguration()
    var report: CBORLDVerificationReport
    var pinnedContexts = Set(registry.expectedFingerprints.keys)
    if let manifestPath = try arguments.value("manifest") {
      guard try arguments.value("transport") == nil, try arguments.value("structure") == nil
      else {
        throw UsageError("--manifest already states the expected digests.")
      }
      let manifest = try JSONDecoder.iso8601.decode(
        CBORLDIntegrityManifest.self, from: try environment.readFile(manifestPath))
      pinnedContexts.formUnion(manifest.contextFingerprints.keys)
      report = await CBORLD.verificationReport(
        for: bytes, against: manifest, contextRegistry: registry, limits: configuration.limits)
    } else {
      let transport = try arguments.value("transport").map(Self.digest)
      let structure = try arguments.value("structure").map(Self.digest)
      guard transport != nil || structure != nil || !registry.expectedFingerprints.isEmpty else {
        throw UsageError("Give --transport, --structure, --pin, or --manifest to verify against.")
      }
      report = await CBORLD.verificationReport(
        for: bytes,
        policy: .init(
          expectedTransportDigest: transport,
          expectedStructuralFingerprint: structure,
          contextRegistry: registry,
          limits: configuration.limits))
    }

    // With --require-pins, decoding may use only pinned contexts, as encode
    // and decode enforce through their loading policy.
    if arguments.flag("require-pins") {
      let unpinned = registry.documents.keys.filter { !pinnedContexts.contains($0) }.sorted()
      if !unpinned.isEmpty {
        report = CBORLDVerificationReport(
          checkedAt: report.checkedAt,
          inspection: report.inspection,
          checks: report.checks
            + unpinned.map { url in
              CBORLDVerificationCheck(
                kind: .contextDocument, subject: url, status: .invalid,
                message: "The context is supplied without a pin, and --require-pins is set.")
            },
          warnings: report.warnings)
      }
    }

    if arguments.flag("json") {
      try emitText(try jsonText(encoding: report))
    } else {
      var lines = report.checks.map { check in
        let subject = check.subject.map { " \($0)" } ?? ""
        return "\(check.status.rawValue): \(check.kind.rawValue)\(subject): \(check.message)"
      }
      lines += report.warnings.map { "warning: \($0)" }
      lines.append(report.isValid ? "result: valid" : "result: invalid")
      try emitText(lines.joined(separator: "\n"))
    }
    return report.isValid ? 0 : 1
  }
}

extension JSONDecoder {
  /// Manifests written by `encode --write-manifest` use ISO 8601 dates.
  fileprivate static var iso8601: JSONDecoder {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return decoder
  }
}
