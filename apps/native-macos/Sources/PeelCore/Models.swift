import Foundation

public enum ExtractionMode: String, Codable, CaseIterable, Sendable { case javascript, jsonpath }
public struct ExtractionState: Codable, Equatable, Sendable {
  public var mode: ExtractionMode = .javascript
  public var queries: [String: String] = ["javascript": "data", "jsonpath": "$"]
  public init() {}
}
public struct HistoryRecord: Codable, Equatable, Identifiable, Sendable {
  public var id: String
  public var title: String
  public var content: String
  public var extraction: ExtractionState
  public var createdAt: String
  public var updatedAt: String
  public var pinned: Bool
  public init(id: String = UUID().uuidString, title: String = "Untitled", content: String = "") {
    self.id = id
    self.title = title
    self.content = content
    extraction = ExtractionState()
    let now = ISO8601DateFormatter().string(from: Date())
    createdAt = now
    updatedAt = now
    pinned = false
  }
}
public struct HistorySummary: Identifiable, Sendable {
  public let id: String
  public let title: String
  public let updatedAt: String
  public let pinned: Bool
  public init(id: String, title: String, updatedAt: String, pinned: Bool) {
    self.id = id
    self.title = title
    self.updatedAt = updatedAt
    self.pinned = pinned
  }
}
/// Syntax-highlighting palettes. The ids are persisted in settings and mirrored in `PeelEditor.mm`.
public struct EditorTheme: Identifiable, Equatable, Sendable {
  public let id: String
  public let name: String
  public static let defaultID = "vscode"
  public static let all = [
    EditorTheme(id: "vscode", name: "VS Code"),
    EditorTheme(id: "github", name: "GitHub"),
    EditorTheme(id: "solarized", name: "Solarized"),
    EditorTheme(id: "one", name: "One"),
    EditorTheme(id: "nord", name: "Nord"),
    EditorTheme(id: "dracula", name: "Dracula"),
    EditorTheme(id: "catppuccin", name: "Catppuccin"),
  ]
  public static func resolve(_ id: String) -> String {
    all.contains { $0.id == id } ? id : defaultID
  }
}
public struct AppSettings: Codable, Equatable, Sendable {
  public var theme = "system"
  public var editorTheme = EditorTheme.defaultID
  public var editorFontSize = 14
  public var quickPasteShortcut = ""
  public init() {}
  private enum CodingKeys: String, CodingKey {
    case theme, editorTheme, editorFontSize, quickPasteShortcut
  }
  /// Settings written before a field existed must keep loading, so every key is optional.
  public init(from decoder: Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    theme = try values.decodeIfPresent(String.self, forKey: .theme) ?? theme
    editorTheme = EditorTheme.resolve(
      try values.decodeIfPresent(String.self, forKey: .editorTheme) ?? editorTheme)
    editorFontSize = try values.decodeIfPresent(Int.self, forKey: .editorFontSize) ?? editorFontSize
    quickPasteShortcut =
      try values.decodeIfPresent(String.self, forKey: .quickPasteShortcut) ?? quickPasteShortcut
  }
}
public struct ExtractionRequest: Codable, Sendable {
  public let mode: ExtractionMode
  public let query: String
  public let text: String
  public init(mode: ExtractionMode, query: String, text: String) {
    self.mode = mode
    self.query = query
    self.text = text
  }
}
public struct ExtractionResult: Codable, Sendable {
  public let status: String
  public let text: String
  public let structured: Bool
  public init(status: String, text: String, structured: Bool = false) {
    self.status = status
    self.text = text
    self.structured = structured
  }
}
