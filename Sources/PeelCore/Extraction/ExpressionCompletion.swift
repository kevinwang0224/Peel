import Foundation

/// Completion for the extraction expression editor: `data.` or `$.store.` followed by the keys that
/// exist at that point of the document, `data[` / `data["` for keys that are not identifiers, and
/// callback parameters such as `x` in `data.items.map(x => x.` (also destructured, `({id}) =>`),
/// and chains through method calls such as `data.items.filter(…).map(x => x.id).` or explicit
/// `JSON.parse(data.value).` calls. Access chains also follow JSON object/array strings
/// automatically. Pure functions; the editor only supplies text.
public enum ExpressionCompletion {
  public enum Segment: Equatable, Sendable {
    case key(String)
    case index(Int)
    /// Any element of an array. Object elements are merged so every key seen is offered.
    case element
    /// A method call in the chain. `map` carries the path the callback returns from its
    /// parameter (`x => x.id` is `[.key("id")]`) when it is that simple.
    case call(String, map: [Segment]?)
    /// Decode the string produced by the preceding path, as an explicit `JSON.parse` call does.
    case parseJSON
  }
  public enum Kind: Equatable, Sendable {
    /// After `.` or `?.`.
    case member
    /// Directly after `[`; keys are offered quoted.
    case bracketKey
    /// Inside `["` or `['`; keys are offered unquoted.
    case quotedKey(quote: Character)
    /// A bare identifier that may be the start of the root name.
    case root
  }
  /// A completion point: the access path from the root and the text typed so far.
  public struct Site: Equatable, Sendable {
    public let kind: Kind
    public let path: [Segment]
    public let prefix: String
  }

  /// Largest source parsed for completion; bigger documents fall back to no suggestions.
  public static let maxDocumentBytes = 5 * 1024 * 1024
  /// Array elements merged to discover the keys of `x` in `items.map(x => x.`.
  static let sampledElements = 50

  /// Locates a completion point at the end of `text`, for example `data.items[0].na`.
  /// `root` is the name the expression starts from (`data` for JavaScript, `$` for JSONPath).
  /// Only access chains are analysed, with known built-in methods and `JSON.parse` calls allowed;
  /// string literals and anything not rooted at `root` or at a recognised callback parameter
  /// yield nil.
  public static func site(in text: String, root: String) -> Site? {
    site(Array(text.utf16), root: root)
  }

  /// Candidates for `site`, resolved against the parsed document and filtered by the typed prefix.
  /// `javascript` adds built-in members of arrays, strings and numbers, and the `data` root name.
  public static func candidates(for site: Site, in root: Any?, javascript: Bool) -> [String] {
    if site.kind == .root {
      let name = "data"
      guard javascript, name != site.prefix, name.hasPrefix(site.prefix.lowercased()) else {
        return []
      }
      return [name]
    }
    guard let root, let value = resolve(site.path, in: root) else { return [] }
    let prefix = site.prefix.lowercased()
    var names: [String]
    switch (site.kind, value) {
    case (.member, let object as [String: Any]):
      names = object.keys.filter(isPlainName)
    case (.bracketKey, let object as [String: Any]):
      names = object.keys.filter { !$0.contains("\"") && !$0.contains("\\") }.map { "\"\($0)\"" }
    case (.quotedKey(let quote), let object as [String: Any]):
      names = object.keys.filter { !$0.contains(quote) && !$0.contains("\\") }
    case (.member, is [Any]):
      names = javascript ? arrayMembers : []
    case (.member, let number as NSNumber):
      names = !javascript || CFGetTypeID(number) == CFBooleanGetTypeID() ? [] : numberMembers
    case (.member, is String):
      names = javascript ? stringMembers : []
    default:
      names = []
    }
    if !prefix.isEmpty { names = names.filter { $0.lowercased().hasPrefix(prefix) } }
    // A completed identifier is not a suggestion.
    names.removeAll { $0 == site.prefix }
    return names.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
  }

  /// Parses the document once for completion; nil if it is too large or not valid JSON.
  public static func parse(_ text: String) -> Any? {
    guard text.utf8.count <= maxDocumentBytes else { return nil }
    return try? JSONSerialization.jsonObject(
      with: Data(text.utf8), options: [.fragmentsAllowed])
  }

  // MARK: - Locating the completion point

  private static func site(
    _ chars: [UInt16], root: String, argumentStart: Int? = nil, parseDepth: Int = 0
  ) -> Site? {
    guard parseDepth <= 32 else { return nil }
    var i = chars.count
    let kind: Kind
    let prefix: String
    if let quote = quotedKeyStart(chars) {
      kind = .quotedKey(quote: Character(UnicodeScalar(chars[quote])!))
      prefix = String(decoding: chars[(quote + 1)...], as: UTF16.self)
      i = quote - 1  // the `[`
    } else {
      while i > 0, isIdentifier(chars[i - 1]) { i -= 1 }
      prefix = String(decoding: chars[i...], as: UTF16.self)
      if i > 0, chars[i - 1] == dot {
        kind = .member
      } else if prefix.isEmpty, i > 0, chars[i - 1] == openBracket {
        kind = .bracketKey
        i -= 1
      } else if prefix.utf16.count >= 2 {
        return Site(kind: .root, path: [], prefix: prefix)
      } else {
        return nil
      }
    }

    var segments: [Segment] = []
    /// Consumes `.` or `?.` (whitespace allowed before it) ending at `i`; false when there is none.
    func consumeDot() -> Bool {
      var j = i
      while j > 0, isSpace(chars[j - 1]) { j -= 1 }
      guard j > 0, chars[j - 1] == dot else { return false }
      j -= 1
      if j > 0, chars[j - 1] == question { j -= 1 }
      i = j
      return true
    }
    if kind == .member, !consumeDot() { return nil }

    var base: [Segment] = []
    while true {
      while i > 0, isSpace(chars[i - 1]) { i -= 1 }
      guard i > 0 else { return nil }
      let c = chars[i - 1]
      if c == closeBracket {
        guard let (segment, start) = bracket(chars, closing: i - 1) else { return nil }
        segments.append(segment)
        i = start
        continue
      }
      if c == closeParen {
        // `owner.method(…)`: only method calls can be followed through.
        let close = i - 1
        guard let open = matchingOpenParen(chars, closing: close) else { return nil }
        var end = open
        while end > 0, isSpace(chars[end - 1]) { end -= 1 }
        var start = end
        while start > 0, isIdentifier(chars[start - 1]) { start -= 1 }
        guard start < end else { return nil }
        let method = String(decoding: chars[start..<end], as: UTF16.self)
        i = start
        guard consumeDot() else { return nil }
        if method == "parse", root != "$", let start = globalJSONStart(chars, endingAt: i) {
          // Keep the surrounding text so callback parameters still resolve, but require
          // the entire argument to be an access chain rather than an arbitrary expression.
          guard let argument = site(
            Array(chars[..<close]) + [dot], root: root, argumentStart: open + 1,
            parseDepth: parseDepth + 1), argument.kind == .member, argument.prefix.isEmpty
          else { return nil }
          base = argument.path + [.parseJSON]
          i = start
          break
        }
        let mapping = method == "map" ? mappedPath(chars, open: open, close: close) : nil
        segments.append(.call(method, map: mapping))
        continue
      }
      guard isIdentifier(c) else { return nil }
      var j = i
      while j > 0, isIdentifier(chars[j - 1]) { j -= 1 }
      let name = String(decoding: chars[j..<i], as: UTF16.self)
      i = j
      if consumeDot() {
        segments.append(.key(name))
        continue
      }
      if name != root {
        guard let path = parameterPath(name, in: chars, before: j, root: root) else { return nil }
        base = path
      }
      break
    }
    if let argumentStart {
      guard i >= argumentStart, chars[argumentStart..<i].allSatisfy(isSpace) else { return nil }
    }
    return Site(kind: kind, path: base + segments.reversed(), prefix: prefix)
  }

  /// Recognise the global receiver, excluding property paths such as `other.JSON.parse`.
  private static func globalJSONStart(_ chars: [UInt16], endingAt end: Int) -> Int? {
    var end = end
    while end > 0, isSpace(chars[end - 1]) { end -= 1 }
    var start = end
    while start > 0, isIdentifier(chars[start - 1]) { start -= 1 }
    guard String(decoding: chars[start..<end], as: UTF16.self) == "JSON" else { return nil }
    var previous = start
    while previous > 0, isSpace(chars[previous - 1]) { previous -= 1 }
    guard previous == 0 || chars[previous - 1] != dot else { return nil }
    return start
  }

  /// Methods whose callback receives array elements, with the parameter positions that do.
  /// `sort`, `reverse` and the like are absent: the input is frozen, so they would throw.
  private static let callbackParameters: [String: [Int]] = [
    "map": [0], "filter": [0], "find": [0], "findIndex": [0], "findLast": [0],
    "findLastIndex": [0], "some": [0], "every": [0], "forEach": [0], "flatMap": [0],
    "reduce": [1], "reduceRight": [1], "toSorted": [0, 1],
  ]

  /// Resolves `name` as a parameter of an enclosing `owner.method(name => …` call and returns the
  /// path of the array element it stands for.
  private static func parameterPath(
    _ name: String, in chars: [UInt16], before limit: Int, root: String
  ) -> [Segment]? {
    var depth = 0
    var i = limit
    while i > 0 {
      i -= 1
      let c = chars[i]
      if c == closeParen {
        depth += 1
      } else if c == openParen {
        if depth > 0 {
          depth -= 1
          continue
        }
        // An enclosing call whose first argument is an arrow function.
        guard let parameters = arrowParameters(chars, from: i + 1, limit: limit),
          let (position, key) = parameter(name, in: parameters)
        else { continue }
        var end = i
        while end > 0, isSpace(chars[end - 1]) { end -= 1 }
        var start = end
        while start > 0, isIdentifier(chars[start - 1]) { start -= 1 }
        guard start < end,
          let positions = callbackParameters[String(decoding: chars[start..<end], as: UTF16.self)],
          positions.contains(position)
        else { return nil }
        var dotEnd = start
        while dotEnd > 0, isSpace(chars[dotEnd - 1]) { dotEnd -= 1 }
        guard dotEnd > 0, chars[dotEnd - 1] == dot,
          let owner = site(Array(chars[..<dotEnd]), root: root), owner.kind == .member
        else { return nil }
        return owner.path + [.element] + (key.map { [Segment.key($0)] } ?? [])
      }
    }
    return nil
  }

  private enum Binding {
    case whole(String)
    /// `{ id, name: alias }`: local name to key.
    case pattern([String: String])
  }

  /// Position of the parameter that binds `name`, and the element key it stands for when it comes
  /// from a destructuring pattern.
  private static func parameter(_ name: String, in parameters: [Binding]) -> (Int, String?)? {
    for (position, binding) in parameters.enumerated() {
      switch binding {
      case .whole(let whole) where whole == name: return (position, nil)
      case .pattern(let keys): if let key = keys[name] { return (position, key) }
      default: break
      }
    }
    return nil
  }

  /// Parameters of the arrow function that starts at `start`: `x =>`, `(x, i) =>` or
  /// `({ id, name: n }, i) =>`. Defaulted, rest and nested patterns bind nothing.
  private static func arrowParameters(_ chars: [UInt16], from start: Int, limit: Int) -> [Binding]? {
    var i = start
    func skipSpace() { while i < limit, isSpace(chars[i]) { i += 1 } }
    func binding(_ units: ArraySlice<UInt16>) -> Binding {
      var trimmed = units
      while let first = trimmed.first, isSpace(first) { trimmed.removeFirst() }
      while let last = trimmed.last, isSpace(last) { trimmed.removeLast() }
      if trimmed.allSatisfy(isIdentifier) { return .whole(String(decoding: trimmed, as: UTF16.self)) }
      guard trimmed.first == openBrace, trimmed.last == closeBrace else { return .whole("") }
      var keys: [String: String] = [:]
      let inner = trimmed.dropFirst().dropLast()
      for entry in inner.split(separator: comma, omittingEmptySubsequences: true) {
        let parts = entry.split(separator: colon, omittingEmptySubsequences: false)
        func ident(_ units: ArraySlice<UInt16>) -> String? {
          let text = String(decoding: units, as: UTF16.self).trimmingCharacters(in: .whitespaces)
          return !text.isEmpty && text.utf16.allSatisfy(isIdentifier) ? text : nil
        }
        if parts.count == 1, let key = ident(parts[0]) {
          keys[key] = key
        } else if parts.count == 2, let key = ident(parts[0]), let local = ident(parts[1]) {
          keys[local] = key
        }
      }
      return .pattern(keys)
    }
    skipSpace()
    var bindings: [Binding] = []
    if i < limit, chars[i] == openParen {
      i += 1
      var from = i
      var braces = 0
      var closed = false
      while i < limit {
        let c = chars[i]
        if c == openBrace {
          braces += 1
        } else if c == closeBrace {
          braces -= 1
        } else if c == comma, braces == 0 {
          bindings.append(binding(chars[from..<i]))
          from = i + 1
        } else if c == closeParen, braces == 0 {
          bindings.append(binding(chars[from..<i]))
          closed = true
          i += 1
          break
        }
        i += 1
      }
      guard closed else { return nil }
    } else {
      let from = i
      while i < limit, isIdentifier(chars[i]) { i += 1 }
      guard i > from else { return nil }
      bindings = [.whole(String(decoding: chars[from..<i], as: UTF16.self))]
    }
    skipSpace()
    guard i + 2 <= limit, chars[i] == equal, chars[i + 1] == greater else { return nil }
    return bindings
  }

  /// Index of the `(` that matches the `)` at `closing`.
  private static func matchingOpenParen(_ chars: [UInt16], closing: Int) -> Int? {
    var depth = 0
    var j = closing
    while j >= 0 {
      if chars[j] == closeParen {
        depth += 1
      } else if chars[j] == openParen {
        depth -= 1
        if depth == 0 { return j }
      }
      j -= 1
    }
    return nil
  }

  /// For `map(x => x.id)` the path `[.key("id")]` relative to the element; nil when the callback
  /// is not `param => <access chain on param>`.
  private static func mappedPath(_ chars: [UInt16], open: Int, close: Int) -> [Segment]? {
    let text = String(decoding: chars[(open + 1)..<close], as: UTF16.self)
    guard let arrow = text.range(of: "=>") else { return nil }
    var parameter = text[..<arrow.lowerBound].trimmingCharacters(in: .whitespaces)
    if parameter.hasPrefix("("), parameter.hasSuffix(")") {
      parameter = String(parameter.dropFirst().dropLast())
    }
    guard !parameter.isEmpty, parameter.utf16.allSatisfy(isIdentifier) else { return nil }
    let body = text[arrow.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
    guard !body.isEmpty else { return nil }
    guard let site = site(Array((body + ".").utf16), root: parameter), site.kind == .member,
      site.prefix.isEmpty
    else { return nil }
    return site.path
  }

  /// Index of the opening quote when the text ends inside `["…` or `['…`.
  private static func quotedKeyStart(_ chars: [UInt16]) -> Int? {
    var j = chars.count
    while j > 0 {
      let c = chars[j - 1]
      if c == doubleQuote || c == singleQuote || c == openBracket || c == closeBracket || c == 0x0A {
        break
      }
      j -= 1
    }
    guard j >= 2, chars[j - 1] == doubleQuote || chars[j - 1] == singleQuote,
      chars[j - 2] == openBracket
    else { return nil }
    return j - 1
  }

  // MARK: - Resolving against the document

  private static func resolve(_ path: [Segment], in root: Any) -> Any? {
    var value = root
    for segment in path {
      // Explicit JSON.parse still consumes the original string; ordinary access
      // automatically follows an embedded object or array.
      if segment != .parseJSON { value = navigable(value) }
      switch (segment, value) {
      case (.key(let key), let object as [String: Any]):
        guard let next = object[key] else { return nil }
        value = next
      case (.index(let index), let array as [Any]):
        guard array.indices.contains(index) else { return nil }
        value = array[index]
      case (.element, let array as [Any]):
        guard let element = merged(array) else { return nil }
        value = element
      case (.key("length"), is [Any]), (.key("length"), is String):
        value = NSNumber(value: 0)
      case (.call(let name, let map), _):
        guard let result = call(name, map: map, on: value) else { return nil }
        value = result
      case (.parseJSON, let text as String):
        guard (try? JSONDocument.summary(text)) != nil, let parsed = parse(text) else { return nil }
        value = parsed
      default:
        return nil
      }
    }
    return navigable(value)
  }

  private static func navigable(_ value: Any) -> Any {
    guard let text = value as? String, text.utf8.count <= maxDocumentBytes else { return value }
    return JSONDocument.embeddedStructure(text) ?? value
  }
  /// A representative value of what `value.name(…)` returns. Only the type matters.
  private static func call(_ name: String, map: [Segment]?, on value: Any) -> Any? {
    let number = NSNumber(value: 0)
    let bool = NSNumber(value: true)
    switch value {
    case let array as [Any]:
      switch name {
      case "filter", "slice", "concat", "toSorted", "toReversed", "with", "toSpliced":
        return array
      case "find", "findLast", "at": return merged(array)
      case "map":
        guard let map, let element = merged(array), let mapped = resolve(map, in: element)
        else { return [Any]() }
        return [mapped]
      case "join": return ""
      case "every", "some", "includes": return bool
      case "findIndex", "findLastIndex", "indexOf", "lastIndexOf": return number
      case "flat", "flatMap", "keys", "values", "entries": return [Any]()
      default: return nil
      }
    case is String:
      switch name {
      case "at", "charAt", "concat", "normalize", "padEnd", "padStart", "repeat", "replace",
        "replaceAll", "slice", "substring", "toLowerCase", "toUpperCase", "trim", "trimEnd",
        "trimStart":
        return ""
      case "split": return [""] as [Any]
      case "endsWith", "includes", "startsWith": return bool
      case "codePointAt", "indexOf", "lastIndexOf", "localeCompare", "search": return number
      default: return nil
      }
    case let value as NSNumber where CFGetTypeID(value) != CFBooleanGetTypeID():
      return numberMembers.contains(name) ? "" : nil
    default:
      return nil
    }
  }
  private static func merged(_ array: [Any]) -> Any? {
    guard let raw = array.first else { return nil }
    let first = navigable(raw)
    guard first is [String: Any] else { return first }
    var keys: [String: Any] = [:]
    for element in array.prefix(sampledElements) {
      guard let object = navigable(element) as? [String: Any] else { continue }
      for (key, value) in object where keys[key] == nil { keys[key] = value }
    }
    return keys
  }

  // MARK: - Built-in members

  static let arrayMembers = [
    "length", "at", "concat", "entries", "every", "filter", "find", "findIndex", "findLast",
    "findLastIndex", "flat", "flatMap", "forEach", "includes", "indexOf", "join", "keys",
    "lastIndexOf", "map", "reduce", "reduceRight", "slice", "some", "toReversed", "toSorted",
    "values",
  ]
  static let stringMembers = [
    "length", "at", "charAt", "codePointAt", "endsWith", "includes", "indexOf", "lastIndexOf",
    "localeCompare", "match", "matchAll", "normalize", "padEnd", "padStart", "repeat", "replace",
    "replaceAll", "search", "slice", "split", "startsWith", "substring", "toLowerCase",
    "toUpperCase", "trim", "trimEnd", "trimStart",
  ]
  static let numberMembers = ["toFixed", "toLocaleString", "toPrecision", "toString"]

  // MARK: - Characters

  private static let dot: UInt16 = 0x2E
  private static let question: UInt16 = 0x3F
  private static let comma: UInt16 = 0x2C
  private static let equal: UInt16 = 0x3D
  private static let greater: UInt16 = 0x3E
  private static let openParen: UInt16 = 0x28
  private static let closeParen: UInt16 = 0x29
  private static let colon: UInt16 = 0x3A
  private static let openBrace: UInt16 = 0x7B
  private static let closeBrace: UInt16 = 0x7D
  private static let openBracket: UInt16 = 0x5B
  private static let closeBracket: UInt16 = 0x5D
  private static let doubleQuote: UInt16 = 0x22
  private static let singleQuote: UInt16 = 0x27

  private static func isSpace(_ c: UInt16) -> Bool { c == 0x20 || c == 0x09 || c == 0x0A || c == 0x0D }
  /// ASCII only, so a UTF-16 offset in an identifier is also a UTF-8 byte offset for the editor.
  private static func isIdentifier(_ c: UInt16) -> Bool {
    (c >= 0x30 && c <= 0x39) || (c >= 0x41 && c <= 0x5A) || (c >= 0x61 && c <= 0x7A) || c == 0x5F
      || c == 0x24
  }
  /// Keys usable after a dot; others need `data["a-b"]`.
  private static func isPlainName(_ name: String) -> Bool {
    guard let first = name.utf16.first, !(first >= 0x30 && first <= 0x39) else { return false }
    return name.utf16.allSatisfy(isIdentifier)
  }
  /// Parses `[12]`, `["key"]` or `['key']` whose `]` is at `closing`; returns the segment and the
  /// index of its `[`.
  private static func bracket(_ chars: [UInt16], closing: Int) -> (Segment, Int)? {
    var j = closing
    while j > 0, chars[j - 1] != openBracket { j -= 1 }
    guard j > 0 else { return nil }
    let start = j - 1
    let content = String(decoding: chars[j..<closing], as: UTF16.self)
    if let index = Int(content), index >= 0 { return (.index(index), start) }
    guard content.count >= 2, let quote = content.first, quote == "\"" || quote == "'",
      content.last == quote
    else { return nil }
    let key = String(content.dropFirst().dropLast())
    guard !key.contains(quote), !key.contains("\\") else { return nil }
    return (.key(key), start)
  }
}
