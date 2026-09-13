import Foundation

struct TermDefinition: Sendable, Equatable {
  var values: [String: JSONValue]
  var isProtected: Bool
  var propagates: Bool

  var id: String? { values["@id"]?.stringValue }
  var type: String? { values["@type"]?.stringValue }
  var scopedContext: JSONValue? { values["@context"] }

  func semanticallyEquals(_ other: TermDefinition) -> Bool {
    values == other.values
  }
}

struct ContextEntry: Sendable {
  var context: [String: JSONValue]
  var termMap: [String: TermDefinition]
}

final class ContextLoader {
  private let documentLoader: CBORLDDocumentLoader?
  private var contextMap: [JSONValue: ContextEntry] = [:]
  private var loadingURLs = Set<String>()
  private(set) var termToID = CBORLDConstants.keywords
  private var idToTerm: [UInt64: String]
  private var nextTermID = CBORLDConstants.firstCustomTermID

  init(documentLoader: CBORLDDocumentLoader?) {
    self.documentLoader = documentLoader
    self.idToTerm = CBORLDConstants.reversed(CBORLDConstants.keywords)
  }

  func id(for term: String, plural: Bool = false) -> CBORValue {
    guard let id = termToID[term] else { return .string(term) }
    return .unsigned(plural ? id + 1 : id)
  }

  func term(for key: CBORValue) throws -> (term: String, plural: Bool) {
    if case .string(let term) = key { return (term, false) }
    guard case .unsigned(let id) = key else {
      throw CBORLDError(
        code: "ERR_UNKNOWN_CBORLD_TERM_ID",
        message: "A CBOR-LD term key must be a string or unsigned integer.")
    }
    let plural = id & 1 == 1
    let base = plural ? id - 1 : id
    guard let term = idToTerm[base] else {
      throw CBORLDError(
        code: "ERR_UNKNOWN_CBORLD_TERM_ID",
        message: "Unknown term ID \"\(id)\" was detected in the CBOR-LD input.")
    }
    return (term, plural)
  }

  func hasTerm(id: UInt64) -> Bool { idToTerm[id] != nil }

  func load(_ contextValue: JSONValue) async throws -> ContextEntry {
    if let entry = contextMap[contextValue] { return entry }

    if case .string(let url) = contextValue {
      return try await loadRemoteContext(url)
    }

    return try await add(contextValue, contextURL: nil, cacheKey: contextValue)
  }

  private func loadRemoteContext(_ url: String) async throws -> ContextEntry {
    let cacheKey = JSONValue.string(url)
    if let cached = contextMap[cacheKey] { return cached }
    guard loadingURLs.insert(url).inserted else {
      throw CBORLDError(
        code: "ERR_INVALID_CONTEXT",
        message: "Circular remote context or @import reference detected for \"\(url)\".")
    }
    defer { loadingURLs.remove(url) }
    guard let documentLoader else {
      throw CBORLDError(
        code: "ERR_NO_DOCUMENT_LOADER",
        message: "A document loader is required to resolve context \"\(url)\".")
    }
    let document = try await documentLoader(url)
    guard case .object(let object) = document,
      let context = object["@context"]
    else {
      throw CBORLDError(
        code: "ERR_INVALID_CONTEXT",
        message: "Loaded document \"\(url)\" does not contain @context.")
    }
    return try await add(context, contextURL: url, cacheKey: cacheKey)
  }

  private func add(
    _ contextValue: JSONValue,
    contextURL: String?,
    cacheKey: JSONValue
  ) async throws -> ContextEntry {
    guard case .object(var context) = contextValue else {
      throw CBORLDError(
        code: "ERR_INVALID_CONTEXT",
        message: "A JSON-LD context must be an object or a context URL.")
    }

    if let importURL = context["@import"]?.stringValue {
      let imported = try await loadRemoteContext(importURL)
      context = imported.context.merging(context) { _, current in current }
    }

    let contextProtected = context["@protected"] == .bool(true)
    var terms: [String: TermDefinition] = [:]
    for key in context.keys.sorted() {
      if key.hasPrefix("@") { continue }
      guard let rawDefinition = context[key], rawDefinition != .null else { continue }

      let values: [String: JSONValue]
      switch rawDefinition {
      case .string(let id): values = ["@id": .string(id)]
      case .object(let object): values = object
      default:
        throw CBORLDError(
          code: "ERR_INVALID_TERM_DEFINITION",
          message:
            "Invalid JSON-LD term definition for \"\(key)\"; it must be a string or an object.")
      }
      terms[key] = TermDefinition(
        values: values,
        isProtected: contextProtected,
        propagates: true)

      if termToID[key] == nil {
        termToID[key] = nextTermID
        idToTerm[nextTermID] = key
        nextTermID += 2
      }
    }

    let entry = ContextEntry(context: context, termMap: terms)
    contextMap[cacheKey] = entry
    if let contextURL { contextMap[.string(contextURL)] = entry }
    return entry
  }
}

final class ActiveContext {
  var termMap: [String: TermDefinition]
  let previous: ActiveContext?
  let contextLoader: ContextLoader
  let typeTerms: [String]

  init(
    termMap: [String: TermDefinition] = [:],
    previous: ActiveContext? = nil,
    contextLoader: ContextLoader
  ) {
    self.termMap = termMap
    self.previous = previous
    self.contextLoader = contextLoader
    self.typeTerms =
      ["@type"]
      + termMap.compactMap { term, definition in
        definition.id == "@type" ? term : nil
      }
  }

  func applyingEmbeddedContexts(to object: [String: JSONValue]) async throws -> ActiveContext {
    let updated = try await updateTermMap(
      activeTermMap: termMap,
      contexts: object["@context"] ?? .object([:]))
    return ActiveContext(termMap: updated, previous: self, contextLoader: contextLoader)
  }

  func applyingPropertyScopedContext(for term: String) async throws -> ActiveContext {
    let updated = try await updateTermMap(
      activeTermMap: revertedTermMap(),
      contexts: termMap[term]?.scopedContext ?? .object([:]),
      propertyScope: true)
    return ActiveContext(termMap: updated, previous: self, contextLoader: contextLoader)
  }

  func applyingTypeScopedContexts(_ objectTypes: Set<String>) async throws -> ActiveContext {
    var current = termMap
    for type in objectTypes.sorted() {
      current = try await updateTermMap(
        activeTermMap: current,
        contexts: current[type]?.scopedContext ?? .object([:]),
        typeScope: true)
    }
    return ActiveContext(termMap: current, previous: self, contextLoader: contextLoader)
  }

  func definition(for term: String) -> TermDefinition {
    termMap[term] ?? TermDefinition(values: [:], isProtected: false, propagates: true)
  }

  private func revertedTermMap() -> [String: TermDefinition] {
    var result = termMap.filter { $0.value.propagates }
    for (term, definition) in termMap where !definition.propagates {
      var context = previous
      var prior = context?.termMap[term]
      while prior != nil, prior?.propagates == false {
        context = context?.previous
        prior = context?.termMap[term]
      }
      if let prior { result[term] = prior }
    }
    return result
  }

  private func updateTermMap(
    activeTermMap: [String: TermDefinition],
    contexts: JSONValue,
    propertyScope: Bool = false,
    typeScope: Bool = false
  ) async throws -> [String: TermDefinition] {
    let contextValues = contexts.arrayValue ?? [contexts]
    var active = activeTermMap

    for contextValue in contextValues {
      let entry = try await contextLoader.load(contextValue)
      let propagates = entry.context["@propagate"]?.boolValue ?? !typeScope
      var newMap = entry.termMap.mapValues { definition in
        var definition = definition
        definition.propagates = propagates
        return definition
      }

      try resolveCURIEs(
        activeTermMap: active,
        context: entry.context,
        newTermMap: &newMap)

      for (term, activeDefinition) in active {
        if var definition = newMap[term] {
          if activeDefinition.isProtected {
            if !propertyScope && !definition.semanticallyEquals(activeDefinition) {
              throw CBORLDError(
                code: "ERR_PROTECTED_TERM_REDEFINITION",
                message: "Unexpected redefinition of protected term \"\(term)\".")
            }
            definition.values = activeDefinition.values
            definition.isProtected = true
            newMap[term] = definition
          }
        } else if entry.context[term] != .null {
          newMap[term] = activeDefinition
        }
      }
      active = newMap
    }
    return active
  }

  private func resolveCURIEs(
    activeTermMap: [String: TermDefinition],
    context: [String: JSONValue],
    newTermMap: inout [String: TermDefinition]
  ) throws {
    for key in newTermMap.keys {
      guard var definition = newTermMap[key] else { continue }
      if let id = definition.id {
        definition.values["@id"] = .string(
          try resolveCURIE(
            id, activeTermMap: activeTermMap, context: context))
      } else {
        let resolved = try resolveCURIE(
          key, activeTermMap: activeTermMap, context: context)
        if resolved.contains(":") { definition.values["@id"] = .string(resolved) }
      }
      if let type = definition.type {
        definition.values["@type"] = .string(
          try resolveCURIE(
            type, activeTermMap: activeTermMap, context: context))
      }
      guard definition.id != nil else {
        throw CBORLDError(
          code: "ERR_INVALID_TERM_DEFINITION",
          message:
            "Invalid JSON-LD term definition for \"\(key)\"; the @id value could not be determined."
        )
      }
      newTermMap[key] = definition
    }
  }

  private func resolveCURIE(
    _ possibleCURIE: String,
    activeTermMap: [String: TermDefinition],
    context: [String: JSONValue],
    depth: Int = 0
  ) throws -> String {
    guard possibleCURIE.contains(":") else { return possibleCURIE }
    guard depth < 128 else {
      throw CBORLDError(
        code: "ERR_INVALID_TERM_DEFINITION",
        message: "Circular CURIE definition detected for \"\(possibleCURIE)\".")
    }
    let parts = possibleCURIE.split(separator: ":", omittingEmptySubsequences: false)
    guard let prefix = parts.first.map(String.init) else { return possibleCURIE }
    let suffix = parts.dropFirst().map(String.init).joined(separator: ":")

    let prefixID: String?
    if let raw = context[prefix] {
      switch raw {
      case .string(let value): prefixID = value
      case .object(let value): prefixID = value["@id"]?.stringValue
      default: prefixID = nil
      }
    } else {
      prefixID = activeTermMap[prefix]?.id
    }
    guard let prefixID else { return possibleCURIE }
    return try resolveCURIE(
      prefixID + suffix,
      activeTermMap: activeTermMap,
      context: context,
      depth: depth + 1)
  }
}

extension JSONValue {
  fileprivate var boolValue: Bool? {
    guard case .bool(let value) = self else { return nil }
    return value
  }
}
