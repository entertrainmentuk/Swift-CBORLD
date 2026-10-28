import Foundation

/// Remembers the outcome of a deterministic check over immutable inputs, such
/// as a dictionary's validation or a pinned document's fingerprint, so that a
/// long-lived encoder, decoder, or registry performs each check once instead
/// of once per document. Results are computed lazily, so unused entries are
/// never hashed.
final class VerificationMemo<Key: Hashable & Sendable>: @unchecked Sendable {
  private let lock = NSLock()
  private var outcomes: [Key: CBORLDError?] = [:]

  /// Returns the remembered failure for `key`, running `check` on first use.
  func failure(for key: Key, check: () throws -> Void) -> CBORLDError? {
    lock.lock()
    if let remembered = outcomes[key] {
      lock.unlock()
      return remembered
    }
    lock.unlock()
    let outcome: CBORLDError?
    do {
      try check()
      outcome = nil
    } catch let error as CBORLDError {
      outcome = error
    } catch {
      outcome = CBORLDError(code: .invalidInput, message: String(describing: error))
    }
    lock.lock()
    outcomes[key] = outcome
    lock.unlock()
    return outcome
  }

  /// Throws the remembered failure for `key`, if any.
  func require(_ key: Key, check: () throws -> Void) throws {
    if let failure = failure(for: key, check: check) { throw failure }
  }
}
