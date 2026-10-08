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
}
public struct AppSettings: Codable, Equatable, Sendable {
  public var theme = "system"
  public var editorFontSize = 14
  public var quickPasteShortcut = ""
  public init() {}
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
