import Foundation

public struct JSONIssue: Error, Equatable, Sendable, LocalizedError {
  public let message: String
  public let byteOffset: Int
  public let line: Int
  public let column: Int
  public var errorDescription: String? { "Line \(line), column \(column): \(message)" }
}

public struct JSONSummary: Sendable {
  public let rootType: String
  public let keyCount: Int
  public let byteSize: Int
}

/// Strict JSON tokenizer. Formatting keeps number lexemes and property order intact.
public enum JSONDocument {
  public static func format(_ text: String, compact: Bool = false) throws -> String {
    if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "" }
    var parser = Parser(text)
    try parser.parse()
    var output = ""
    var depth = 0
    let tokens = parser.tokens
    func newline() -> String { compact ? "" : "\n" + String(repeating: "  ", count: depth) }
    for (index, token) in tokens.enumerated() {
      let value = String(decoding: parser.bytes[token], as: UTF8.self)
      let previous = index > 0 ? parser.bytes[tokens[index - 1].lowerBound] : 0
      let next = index + 1 < tokens.count ? parser.bytes[tokens[index + 1].lowerBound] : 0
      switch parser.bytes[token.lowerBound] {
      case 123, 91:
        output += value
        depth += 1
        if next != 125 && next != 93 { output += newline() }
      case 125, 93:
        depth -= 1
        if previous != 123 && previous != 91 { output += newline() }
        output += value
      case 44: output += "," + newline()
      case 58: output += compact ? ":" : ": "
      default: output += value
      }
    }
    return output
  }

  public static func summary(_ text: String) throws -> JSONSummary {
    var parser = Parser(text, collectTokens: false)
    if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      return JSONSummary(rootType: "Empty", keyCount: 0, byteSize: text.utf8.count)
    }
    try parser.parse()
    return JSONSummary(
      rootType: parser.rootType, keyCount: parser.keyCount, byteSize: parser.bytes.count)
  }

  public static func formatInput(_ text: String, compact: Bool = false) throws -> String {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    if let value = try? JSONSerialization.jsonObject(
      with: Data(trimmed.utf8), options: [.fragmentsAllowed]),
      let inner = value as? String,
      let type = try? summary(inner).rootType, type == "Object" || type == "Array"
    {
      return try format(inner, compact: compact)
    }
    if (try? summary(trimmed)) == nil, trimmed.contains("\\\""),
      let inner = try? JSONSerialization.jsonObject(
        with: Data(("\"" + trimmed + "\"").utf8), options: [.fragmentsAllowed]) as? String,
      let type = try? summary(inner).rootType, type == "Object" || type == "Array"
    {
      return try format(inner, compact: compact)
    }
    return try format(text, compact: compact)
  }

  public static func pasted(_ text: String) -> String { (try? formatInput(text)) ?? text }
}

private struct Parser {
  let bytes: [UInt8]
  var position = 0
  var tokens: [Range<Int>] = []
  var keyCount = 0
  var rootType = "Invalid"
  let collectTokens: Bool
  init(_ text: String, collectTokens: Bool = true) {
    bytes = Array(text.utf8)
    self.collectTokens = collectTokens
  }

  mutating func parse() throws {
    skipSpace()
    rootType = try value(depth: 0)
    skipSpace()
    if position != bytes.count { throw issue("Unexpected character") }
  }

  func issue(_ message: String) -> JSONIssue {
    let prefix = String(decoding: bytes[..<min(position, bytes.count)], as: UTF8.self)
    let lines = prefix.split(separator: "\n", omittingEmptySubsequences: false)
    return JSONIssue(
      message: message, byteOffset: position, line: lines.count,
      column: (lines.last?.utf16.count ?? 0) + 1)
  }

  mutating func skipSpace() {
    while position < bytes.count && [9, 10, 13, 32].contains(bytes[position]) { position += 1 }
  }
  mutating func punctuation(_ byte: UInt8) throws {
    skipSpace()
    guard position < bytes.count, bytes[position] == byte else {
      throw issue("Expected '\(String(UnicodeScalar(byte)))'")
    }
    if collectTokens { tokens.append(position..<position + 1) }
    position += 1
  }
  mutating func value(depth: Int) throws -> String {
    guard depth <= 512 else { throw issue("JSON nesting exceeds 512 levels") }
    skipSpace()
    guard position < bytes.count else { throw issue("Value expected") }
    switch bytes[position] {
    case 123:
      try punctuation(123)
      skipSpace()
      if position < bytes.count && bytes[position] == 125 {
        try punctuation(125)
        return "Object"
      }
      while true {
        skipSpace()
        guard position < bytes.count && bytes[position] == 34 else {
          throw issue("Property name expected")
        }
        try string()
        keyCount += 1
        try punctuation(58)
        _ = try value(depth: depth + 1)
        skipSpace()
        if position < bytes.count && bytes[position] == 125 { break }
        try punctuation(44)
      }
      try punctuation(125)
      return "Object"
    case 91:
      try punctuation(91)
      skipSpace()
      if position < bytes.count && bytes[position] == 93 {
        try punctuation(93)
        return "Array"
      }
      while true {
        _ = try value(depth: depth + 1)
        skipSpace()
        if position < bytes.count && bytes[position] == 93 { break }
        try punctuation(44)
      }
      try punctuation(93)
      return "Array"
    case 34:
      try string()
      return "String"
    case 116:
      try literal("true")
      return "Boolean"
    case 102:
      try literal("false")
      return "Boolean"
    case 110:
      try literal("null")
      return "Null"
    case 45, 48...57:
      try number()
      return "Number"
    default: throw issue("Value expected")
    }
  }
  mutating func string() throws {
    let start = position
    position += 1
    while position < bytes.count {
      let byte = bytes[position]
      if byte == 34 {
        position += 1
        if collectTokens { tokens.append(start..<position) }
        return
      }
      if byte < 32 { throw issue("Unescaped control character") }
      if byte == 92 {
        position += 1
        guard position < bytes.count else { throw issue("Unterminated escape") }
        if bytes[position] == 117 {
          for _ in 0..<4 {
            position += 1
            guard position < bytes.count,
              (48...57).contains(bytes[position]) || (65...70).contains(bytes[position])
                || (97...102).contains(bytes[position])
            else { throw issue("Invalid Unicode escape") }
          }
        } else if ![34, 92, 47, 98, 102, 110, 114, 116].contains(bytes[position]) {
          throw issue("Invalid escape")
        }
      }
      position += 1
    }
    throw issue("Unterminated string")
  }
  mutating func literal(_ text: String) throws {
    let start = position
    for byte in text.utf8 {
      guard position < bytes.count && bytes[position] == byte else {
        throw issue("Invalid literal")
      }
      position += 1
    }
    if collectTokens { tokens.append(start..<position) }
  }
  mutating func number() throws {
    let start = position
    if bytes[position] == 45 { position += 1 }
    guard position < bytes.count else { throw issue("Number expected") }
    if bytes[position] == 48 {
      position += 1
    } else {
      guard (49...57).contains(bytes[position]) else { throw issue("Invalid number") }
      digits()
    }
    if position < bytes.count && bytes[position] == 46 {
      position += 1
      let begin = position
      digits()
      if begin == position { throw issue("Fraction digits expected") }
    }
    if position < bytes.count && [69, 101].contains(bytes[position]) {
      position += 1
      if position < bytes.count && [43, 45].contains(bytes[position]) { position += 1 }
      let begin = position
      digits()
      if begin == position { throw issue("Exponent digits expected") }
    }
    if collectTokens { tokens.append(start..<position) }
  }
  mutating func digits() {
    while position < bytes.count && (48...57).contains(bytes[position]) { position += 1 }
  }
}
