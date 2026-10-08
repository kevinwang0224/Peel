import CSQLite
import Foundation

public struct StorageError: LocalizedError {
  public let message: String
  public init(message: String) { self.message = message }
  public var errorDescription: String? { message }
}
private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// All disk access is serialized off the UI actor. Lists never return document bodies.
public actor HistoryStore {
  private let database: OpaquePointer
  public init(url: URL) throws {
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    var handle: OpaquePointer?
    guard
      sqlite3_open_v2(
        url.path, &handle, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil)
        == SQLITE_OK,
      let handle
    else {
      if let handle { sqlite3_close(handle) }
      throw StorageError(message: "Cannot open history database")
    }
    database = handle
    sqlite3_busy_timeout(handle, 3000)
    sqlite3_create_function_v2(
      handle, "peel_fold", 1, SQLITE_UTF8 | SQLITE_DETERMINISTIC, nil,
      { context, _, args in
        guard let value = args?[0], let raw = sqlite3_value_text(value) else {
          sqlite3_result_null(context)
          return
        }
        let folded = String(cString: raw).lowercased()
        folded.withCString { sqlite3_result_text(context, $0, -1, sqliteTransient) }
      }, nil, nil, nil)
    let schema = """
      PRAGMA journal_mode=WAL;
      CREATE TABLE IF NOT EXISTS records (
        id TEXT PRIMARY KEY, title TEXT NOT NULL, content TEXT NOT NULL, extraction TEXT NOT NULL,
        createdAt TEXT NOT NULL, updatedAt TEXT NOT NULL, pinned INTEGER NOT NULL);
      CREATE INDEX IF NOT EXISTS record_order ON records(pinned DESC, updatedAt DESC);
      CREATE TABLE IF NOT EXISTS settings (key TEXT PRIMARY KEY, value TEXT NOT NULL);
      CREATE TABLE IF NOT EXISTS migrations (path TEXT PRIMARY KEY);
      """
    guard sqlite3_exec(handle, schema, nil, nil, nil) == SQLITE_OK else {
      let message = String(cString: sqlite3_errmsg(handle))
      sqlite3_close(handle)
      throw StorageError(message: message)
    }
  }
  deinit { sqlite3_close(database) }

  public func list(search: String = "", limit: Int = 100, offset: Int = 0) throws
    -> [HistorySummary]
  {
    let query = search.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    let statement = try prepare(
      "SELECT id,title,updatedAt,pinned FROM records WHERE ?='' OR instr(peel_fold(title),?)>0 OR instr(peel_fold(content),?)>0 ORDER BY pinned DESC,updatedAt DESC,id LIMIT ? OFFSET ?"
    )
    defer { sqlite3_finalize(statement) }
    for index in 1...3 { bind(query, to: statement, at: Int32(index)) }
    sqlite3_bind_int64(statement, 4, Int64(max(1, min(limit, 1000))))
    sqlite3_bind_int64(statement, 5, Int64(max(0, offset)))
    var result: [HistorySummary] = []
    while try next(statement) {
      result.append(
        HistorySummary(
          id: text(statement, 0), title: text(statement, 1),
          updatedAt: text(statement, 2), pinned: sqlite3_column_int(statement, 3) != 0))
    }
    return result
  }
  public func record(id: String) throws -> HistoryRecord? {
    let statement = try prepare(
      "SELECT id,title,content,extraction,createdAt,updatedAt,pinned FROM records WHERE id=?")
    defer { sqlite3_finalize(statement) }
    bind(id, to: statement, at: 1)
    guard try next(statement) else { return nil }
    var record = HistoryRecord(
      id: text(statement, 0), title: text(statement, 1), content: text(statement, 2))
    record.extraction = try JSONDecoder().decode(
      ExtractionState.self, from: Data(text(statement, 3).utf8))
    record.createdAt = text(statement, 4)
    record.updatedAt = text(statement, 5)
    record.pinned = sqlite3_column_int(statement, 6) != 0
    return record
  }
  public func save(_ record: HistoryRecord) throws {
    let statement = try prepare(
      "INSERT INTO records VALUES(?,?,?,?,?,?,?) ON CONFLICT(id) DO UPDATE SET title=excluded.title,content=excluded.content,extraction=excluded.extraction,updatedAt=excluded.updatedAt,pinned=excluded.pinned"
    )
    defer { sqlite3_finalize(statement) }
    let extraction = String(decoding: try JSONEncoder().encode(record.extraction), as: UTF8.self)
    for (index, value) in [
      record.id, record.title, record.content, extraction, record.createdAt, record.updatedAt,
    ].enumerated() {
      bind(value, to: statement, at: Int32(index + 1))
    }
    sqlite3_bind_int(statement, 7, record.pinned ? 1 : 0)
    try finish(statement)
  }
  public func delete(id: String) throws {
    let statement = try prepare("DELETE FROM records WHERE id=?")
    defer { sqlite3_finalize(statement) }
    bind(id, to: statement, at: 1)
    try finish(statement)
  }
  public func settings() throws -> AppSettings {
    let statement = try prepare("SELECT value FROM settings WHERE key='app'")
    defer { sqlite3_finalize(statement) }
    guard try next(statement) else { return AppSettings() }
    return try JSONDecoder().decode(AppSettings.self, from: Data(text(statement, 0).utf8))
  }
  public func saveSettings(_ settings: AppSettings) throws {
    let statement = try prepare("INSERT OR REPLACE INTO settings VALUES('app',?)")
    defer { sqlite3_finalize(statement) }
    bind(String(decoding: try JSONEncoder().encode(settings), as: UTF8.self), to: statement, at: 1)
    try finish(statement)
  }

  /// Import each source once, atomically. The source files are never changed.
  public func migrateLegacy(files: [URL]) throws {
    for file in files where FileManager.default.fileExists(atPath: file.path) {
      let check = try prepare("SELECT path FROM migrations WHERE path=?")
      bind(file.standardizedFileURL.path, to: check, at: 1)
      let migrated = try next(check)
      sqlite3_finalize(check)
      if migrated { continue }
      let data = try Data(contentsOf: file)
      guard let snapshot = try JSONSerialization.jsonObject(with: data) as? [String: Any],
        let history = snapshot["history"] as? [[String: Any]]
      else {
        throw StorageError(message: "Invalid legacy history: \(file.lastPathComponent)")
      }
      let schema = snapshot["schemaVersion"] as? Int ?? 1
      guard (1...2).contains(schema) else {
        throw StorageError(message: "Unsupported legacy schema \(schema)")
      }
      try execute("BEGIN IMMEDIATE")
      do {
        for value in history {
          guard let id = value["id"] as? String, let title = value["title"] as? String,
            let content = value["content"] as? String,
            let created = value["createdAt"] as? String,
            let updated = value["updatedAt"] as? String,
            let pinned = value["pinned"] as? Bool
          else {
            throw StorageError(message: "Invalid record in legacy history")
          }
          var record = HistoryRecord(id: id, title: title, content: content)
          record.createdAt = created
          record.updatedAt = updated
          record.pinned = pinned
          if let extraction = value["extraction"] as? [String: Any] {
            if let mode = extraction["mode"] as? String, let parsed = ExtractionMode(rawValue: mode)
            {
              record.extraction.mode = parsed
            }
            if let queries = extraction["queries"] as? [String: Any] {
              for mode in ExtractionMode.allCases {
                if let query = queries[mode.rawValue] as? String {
                  record.extraction.queries[mode.rawValue] = query
                }
              }
            }
          }
          try save(record)
        }
        if let raw = snapshot["settings"] as? [String: Any] {
          var settings = try self.settings()
          if let theme = raw["theme"] as? String, ["system", "light", "dark"].contains(theme),
            theme != "system" || settings.theme == "system"
          {
            settings.theme = theme
          }
          if let size = raw["editorFontSize"] as? Int, (10...30).contains(size),
            size != 14 || settings.editorFontSize == 14
          {
            settings.editorFontSize = size
          }
          if let shortcut = raw["quickPasteShortcut"] as? String,
            !shortcut.isEmpty || settings.quickPasteShortcut.isEmpty
          {
            settings.quickPasteShortcut = shortcut
          }
          try saveSettings(settings)
        }
        let marker = try prepare("INSERT INTO migrations VALUES(?)")
        bind(file.standardizedFileURL.path, to: marker, at: 1)
        defer { sqlite3_finalize(marker) }
        try finish(marker)
        try execute("COMMIT")
      } catch {
        try? execute("ROLLBACK")
        throw error
      }
    }
  }
  private func prepare(_ sql: String) throws -> OpaquePointer {
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
      throw failure()
    }
    return statement
  }
  private func execute(_ sql: String) throws {
    guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else { throw failure() }
  }
  private func bind(_ value: String, to statement: OpaquePointer, at index: Int32) {
    value.withCString { _ = sqlite3_bind_text(statement, index, $0, -1, sqliteTransient) }
  }
  private func text(_ statement: OpaquePointer, _ column: Int32) -> String {
    String(cString: sqlite3_column_text(statement, column))
  }
  private func next(_ statement: OpaquePointer) throws -> Bool {
    let status = sqlite3_step(statement)
    if status == SQLITE_ROW { return true }
    if status == SQLITE_DONE { return false }
    throw failure()
  }
  private func finish(_ statement: OpaquePointer) throws {
    if try next(statement) { throw failure() }
  }
  private func failure() -> StorageError {
    StorageError(message: String(cString: sqlite3_errmsg(database)))
  }
}
