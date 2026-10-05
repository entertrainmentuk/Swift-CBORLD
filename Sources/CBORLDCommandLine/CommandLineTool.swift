import CBORLD
import Foundation

/// The `cborld` command: encode, decode, inspect, digest, and verify CBOR-LD
/// documents offline.
///
/// Contexts are read only from files named with `--context URL=FILE`; the
/// tool never fetches anything from the network.
public enum CommandLineTool {
  public static let version = "0.1.0"

  /// Runs one invocation and returns its exit status: 0 for success, 1 for a
  /// processing error or failed verification, and 2 for a usage error.
  public static func run(
    _ arguments: [String],
    environment: ToolEnvironment = .standard
  ) async -> Int32 {
    guard let name = arguments.first else {
      environment.writeStandardError(overview)
      return 2
    }
    switch name {
    case "help", "--help", "-h":
      return help(Array(arguments.dropFirst()), environment: environment)
    case "--version", "version":
      environment.writeStandardOutput(Data("cborld \(version)\n".utf8))
      return 0
    default:
      break
    }
    guard let command = Command(rawValue: name) else {
      environment.writeStandardError("error: Unknown command \(name).\n\n\(overview)")
      return 2
    }
    let rest = Array(arguments.dropFirst())
    if rest.contains("--help") || rest.contains("-h") {
      environment.writeStandardOutput(Data(command.usage.utf8))
      return 0
    }
    do {
      let context = CommandContext(
        arguments: try ParsedArguments(rest, flags: command.flags, options: command.options),
        environment: environment)
      switch command {
      case .encode: return try await context.encode()
      case .decode: return try await context.decode()
      case .inspect: return try context.inspect()
      case .digest: return try context.digest()
      case .verify: return try await context.verify()
      }
    } catch let error as UsageError {
      environment.writeStandardError(
        "error: \(error.message)\nRun 'cborld help \(command.rawValue)' for usage.\n")
      return 2
    } catch let error as CBORLDError {
      var message = "error: \(error.code): \(error.message)\n"
      if let diagnostic = error.diagnostic {
        message += "  at \(diagnostic)\n"
      }
      environment.writeStandardError(message)
      return 1
    } catch {
      environment.writeStandardError("error: \(error.localizedDescription)\n")
      return 1
    }
  }

  private static func help(_ topics: [String], environment: ToolEnvironment) -> Int32 {
    guard let topic = topics.first else {
      environment.writeStandardOutput(Data(overview.utf8))
      return 0
    }
    guard let command = Command(rawValue: topic) else {
      environment.writeStandardError("error: Unknown command \(topic).\n\n\(overview)")
      return 2
    }
    environment.writeStandardOutput(Data(command.usage.utf8))
    return 0
  }

  static let overview = """
    Usage: cborld <command> [options] [INPUT]

    Encode, decode, inspect, digest, and verify CBOR-LD documents. INPUT is a
    file, or standard input when omitted or '-'. Contexts are read only from
    files given with --context; nothing is fetched from the network.

    Commands:
      encode    Compress a JSON-LD document into CBOR-LD
      decode    Restore a CBOR-LD document as JSON-LD
      inspect   Describe a CBOR-LD envelope without loading contexts
      digest    Compute a transport digest or a structural or context fingerprint
      verify    Check CBOR-LD bytes against expected digests or a manifest

    Run 'cborld help <command>' for a command's options.

    """
}

/// The commands, with the options each accepts.
enum Command: String, CaseIterable {
  case encode
  case decode
  case inspect
  case digest
  case verify

  private static let contextOptions: Set<String> = ["context", "pin", "registry"]

  var flags: Set<String> {
    switch self {
    case .encode: ["hex", "require-pins"]
    case .decode: ["hex", "require-pins", "untrusted", "untrusted-deterministic", "compact"]
    case .inspect: ["hex", "untrusted", "untrusted-deterministic", "json"]
    case .digest: ["hex"]
    case .verify: ["hex", "untrusted", "untrusted-deterministic", "json"]
    }
  }

  var options: Set<String> {
    switch self {
    case .encode:
      Self.contextOptions.union([
        "output", "mode", "registry-entry", "max-output-bytes", "write-manifest",
      ])
    case .decode: Self.contextOptions.union(["output"])
    case .inspect: ["output"]
    case .digest: ["output", "kind", "algorithm"]
    case .verify: ["output", "context", "pin", "transport", "structure", "manifest"]
    }
  }

  var usage: String {
    switch self {
    case .encode:
      """
      Usage: cborld encode [options] [INPUT.json]

      Compresses a JSON-LD document into CBOR-LD bytes.

      Options:
        -o, --output FILE          Write the bytes to FILE
        --hex                      Write hexadecimal text instead of bytes
        --registry-entry N         Registry entry to encode with (default 1;
                                   0 is uncompressed CBOR)
        --registry FILE            A registry entry in the editor's draft JSON
                                   form; repeatable
        --mode MODE                compatibility (default), deterministic,
                                   length-first-deterministic, or
                                   core-deterministic
        --context URL=FILE         Read the context for URL from FILE; repeatable
        --pin URL=DIGEST           Require URL's context to match a
                                   context-document digest; repeatable
        --require-pins             Reject any context without a pin
        --max-output-bytes N       Fail before the output exceeds N bytes
        --write-manifest FILE      Also write an integrity manifest for the
                                   output, for 'cborld verify --manifest'

      Binary output is never written to a terminal; use --output or --hex.

      """
    case .decode:
      """
      Usage: cborld decode [options] [INPUT]

      Restores a CBOR-LD document as JSON-LD.

      Options:
        -o, --output FILE          Write the JSON to FILE
        --hex                      Read hexadecimal text instead of bytes
        --compact                  Write JSON on a single line
        --untrusted                Apply bounded limits for untrusted input
        --untrusted-deterministic  Also require RFC 8949 length-first
                                   deterministic bytes
        --registry FILE            A registry entry in the editor's draft JSON
                                   form; repeatable
        --context URL=FILE         Read the context for URL from FILE; repeatable
        --pin URL=DIGEST           Require URL's context to match a
                                   context-document digest; repeatable
        --require-pins             Reject any context without a pin

      """
    case .inspect:
      """
      Usage: cborld inspect [options] [INPUT]

      Describes a CBOR-LD envelope: format, registry entry, compression, size,
      and transport digest. Contexts are not loaded.

      Options:
        --hex                      Read hexadecimal text instead of bytes
        --json                     Write the inspection as JSON
        --untrusted                Apply bounded limits for untrusted input
        --untrusted-deterministic  Also require RFC 8949 length-first
                                   deterministic bytes
        -o, --output FILE          Write to FILE

      """
    case .digest:
      """
      Usage: cborld digest [options] [INPUT]

      Prints a digest as ALGORITHM:DOMAIN:vVERSION:HEX.

      Options:
        --kind KIND                transport (default; hashes the exact bytes),
                                   structure (fingerprints a JSON document), or
                                   context (fingerprints a JSON-LD context)
        --algorithm NAME           sha256 (default), sha384, or sha512
        --hex                      Read hexadecimal text instead of bytes
                                   (transport only)
        -o, --output FILE          Write to FILE

      A digest detects changes; it does not identify who produced the bytes.

      """
    case .verify:
      """
      Usage: cborld verify [options] [INPUT]

      Checks CBOR-LD bytes and prints one line per check. Exits with 1 when any
      check fails.

      Options:
        --transport DIGEST         Expected transport digest of the bytes
        --structure DIGEST         Expected structural fingerprint of the
                                   decoded document
        --pin URL=DIGEST           Expected context-document digest; repeatable
        --context URL=FILE         Read the context for URL from FILE; repeatable
        --manifest FILE            Check against an integrity manifest instead
                                   of --transport and --structure
        --untrusted                Apply bounded limits for untrusted input
        --untrusted-deterministic  Also require RFC 8949 length-first
                                   deterministic bytes
        --hex                      Read hexadecimal text instead of bytes
        --json                     Write the report as JSON
        -o, --output FILE          Write to FILE

      """
    }
  }
}
