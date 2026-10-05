import Foundation

#if canImport(Darwin)
  import Darwin
#elseif canImport(Glibc)
  import Glibc
#elseif canImport(Musl)
  import Musl
#endif

/// A command-line mistake. The tool reports it with usage guidance and exits
/// with status 2.
struct UsageError: Error, Equatable {
  let message: String

  init(_ message: String) {
    self.message = message
  }
}

/// Positional values and `--name value` options for one command.
///
/// An option may also be written `--name=value`, may repeat, and `-o` is short
/// for `--output`. `--` ends option parsing, and `-` is a positional value
/// meaning standard input.
struct ParsedArguments {
  private(set) var positionals: [String] = []
  private var values: [String: [String]] = [:]
  private var flags: Set<String> = []

  init(_ arguments: [String], flags allowedFlags: Set<String>, options allowedOptions: Set<String>)
    throws
  {
    var index = 0
    var optionsEnded = false
    while index < arguments.count {
      let argument = arguments[index]
      index += 1
      if optionsEnded || argument == "-" || !argument.hasPrefix("-") {
        positionals.append(argument)
        continue
      }
      if argument == "--" {
        optionsEnded = true
        continue
      }
      var name: String
      var inlineValue: String?
      if argument == "-o" {
        name = "output"
      } else if argument.hasPrefix("--") {
        name = String(argument.dropFirst(2))
        if let equals = name.firstIndex(of: "=") {
          inlineValue = String(name[name.index(after: equals)...])
          name = String(name[..<equals])
        }
      } else {
        throw UsageError("Unknown option \(argument).")
      }
      if allowedFlags.contains(name) {
        guard inlineValue == nil else {
          throw UsageError("Option --\(name) does not take a value.")
        }
        flags.insert(name)
      } else if allowedOptions.contains(name) {
        let value: String
        if let inlineValue {
          value = inlineValue
        } else {
          guard index < arguments.count else {
            throw UsageError("Option --\(name) requires a value.")
          }
          value = arguments[index]
          index += 1
        }
        values[name, default: []].append(value)
      } else {
        throw UsageError("Unknown option --\(name).")
      }
    }
  }

  func flag(_ name: String) -> Bool {
    flags.contains(name)
  }

  /// The only value of an option that may appear at most once.
  func value(_ name: String) throws -> String? {
    guard let values = values[name] else { return nil }
    guard values.count == 1 else {
      throw UsageError("Option --\(name) may be given only once.")
    }
    return values[0]
  }

  /// Every value of a repeatable option, in order.
  func values(_ name: String) -> [String] {
    values[name] ?? []
  }

  /// The single input path; `nil` or `-` means standard input.
  func inputPath() throws -> String? {
    guard positionals.count <= 1 else {
      throw UsageError("Expected at most one input file, but got \(positionals.count).")
    }
    return positionals.first
  }
}

/// Where a command reads and writes. Tests substitute in-memory files and
/// streams.
public struct ToolEnvironment: Sendable {
  var readStandardInput: @Sendable () throws -> Data
  var writeStandardOutput: @Sendable (Data) -> Void
  var writeStandardError: @Sendable (String) -> Void
  var readFile: @Sendable (String) throws -> Data
  var writeFile: @Sendable (String, Data) throws -> Void
  var standardOutputIsTerminal: Bool

  /// The process's standard streams and the local file system.
  public static var standard: Self {
    Self(
      readStandardInput: { FileHandle.standardInput.readDataToEndOfFile() },
      writeStandardOutput: { FileHandle.standardOutput.write($0) },
      writeStandardError: { FileHandle.standardError.write(Data($0.utf8)) },
      readFile: { try Data(contentsOf: URL(fileURLWithPath: $0)) },
      writeFile: { try $1.write(to: URL(fileURLWithPath: $0), options: .atomic) },
      standardOutputIsTerminal: isatty(STDOUT_FILENO) != 0)
  }
}
