import XCTest

@testable import PeelCore

final class HistoryStoreTests: XCTestCase {
  func testSavedRecordSurvivesReopeningWithoutLoadingAllBodies() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("history.sqlite")
    let store = try HistoryStore(url: url)
    let record = HistoryRecord(title: "Payload", content: "{\"name\":\"你好\"}")
    try await store.save(record)
    let reopened = try HistoryStore(url: url)
    let list = try await reopened.list(search: "你好")
    XCTAssertEqual(list.map(\.id), [record.id])
    let restored = try await reopened.record(id: record.id)
    XCTAssertEqual(restored, record)
  }
  func testFutureSchemaIsNotImportedOrMarkedComplete() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = try HistoryStore(url: directory.appendingPathComponent("history.sqlite"))
    let legacy = directory.appendingPathComponent("peel-data.json")
    try Data("{\"schemaVersion\":99,\"history\":[]}".utf8).write(to: legacy)
    do {
      try await store.migrateLegacy(files: [legacy])
      XCTFail("Unknown schema must be rejected")
    } catch { XCTAssertTrue(error.localizedDescription.contains("schema")) }
  }
}

extension HistoryStoreTests {
  func testMigrationKeepsCurrentRecordAndSettingsAndRunsOnlyOnce() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = try HistoryStore(url: directory.appendingPathComponent("history.sqlite"))
    let legacy = directory.appendingPathComponent("old.json")
    let current = directory.appendingPathComponent("current.json")
    let source = """
      {"schemaVersion":1,"history":[{"id":"r1","title":"Old","content":"old","createdAt":"2025-01-01","updatedAt":"2025-01-02","pinned":false}],"settings":{"theme":"dark","editorFontSize":16}}
      """
    try Data(source.utf8).write(to: legacy)
    let newSource = """
      {"schemaVersion":2,"history":[{"id":"r1","title":"Current","content":"你好 ÄBC","createdAt":"2025-01-01","updatedAt":"2026-01-02","pinned":true,"extraction":{"mode":"jsonpath","queries":{"jsonpath":"$.items"}}}],"settings":{"theme":"system","quickPasteShortcut":"Command+Shift+J"}}
      """
    try Data(newSource.utf8).write(to: current)
    try await store.migrateLegacy(files: [legacy, current])
    let importedValue = try await store.record(id: "r1")
    let imported = try XCTUnwrap(importedValue)
    XCTAssertEqual(imported.title, "Current")
    XCTAssertEqual(imported.extraction.queries["javascript"], "data")
    XCTAssertEqual(imported.extraction.queries["jsonpath"], "$.items")
    XCTAssertTrue(imported.pinned)
    let settings = try await store.settings()
    XCTAssertEqual(settings.theme, "dark")
    XCTAssertEqual(settings.editorFontSize, 16)
    XCTAssertEqual(settings.quickPasteShortcut, "Command+Shift+J")
    let matches = try await store.list(search: "äbc")
    XCTAssertEqual(matches.map(\.id), ["r1"])
    var edited = imported
    edited.content = "native edit"
    try await store.save(edited)
    try await store.migrateLegacy(files: [legacy, current])
    let restored = try await store.record(id: "r1")
    XCTAssertEqual(restored?.content, "native edit")
    XCTAssertEqual(try Data(contentsOf: current), Data(newSource.utf8))
  }
  func testInvalidMigrationRollsBackAndCanBeRetried() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = try HistoryStore(url: directory.appendingPathComponent("history.sqlite"))
    let source = directory.appendingPathComponent("old.json")
    let record = HistoryRecord(id: "valid", title: "Valid", content: "null")
    let raw = try JSONSerialization.jsonObject(with: JSONEncoder().encode(record))
    try JSONSerialization.data(withJSONObject: [
      "schemaVersion": 2, "history": [raw, ["bad": true]],
    ]).write(to: source)
    do {
      try await store.migrateLegacy(files: [source])
      XCTFail("Invalid migration should fail")
    } catch {}
    let empty = try await store.list()
    XCTAssertTrue(empty.isEmpty)
    try JSONSerialization.data(withJSONObject: ["schemaVersion": 2, "history": [raw]]).write(
      to: source)
    try await store.migrateLegacy(files: [source])
    let restored = try await store.record(id: record.id)
    XCTAssertEqual(restored, record)
  }
  func testPagingPinningAndDeletingUsePublicStoreInterface() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = try HistoryStore(url: directory.appendingPathComponent("history.sqlite"))
    var pinned = HistoryRecord(id: "p", title: "Pinned", content: "{}")
    pinned.pinned = true
    try await store.save(HistoryRecord(id: "a"))
    try await store.save(pinned)
    let first = try await store.list(limit: 1)
    XCTAssertEqual(first.first?.id, "p")
    let next = try await store.list(limit: 1, offset: 1)
    XCTAssertEqual(next.first?.id, "a")
    try await store.delete(id: "p")
    let removed = try await store.record(id: "p")
    XCTAssertNil(removed)
    let retained = try await store.record(id: "a")
    XCTAssertNotNil(retained)
  }
  func testNulCharactersInDraftAndTitleSurviveSaveAndReload() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = try HistoryStore(url: directory.appendingPathComponent("history.sqlite"))
    let record = HistoryRecord(title: "before\u{0}after", content: "invalid\u{0}draft")
    try await store.save(record)
    let restored = try await store.record(id: record.id)
    XCTAssertEqual(restored, record)
  }
}
