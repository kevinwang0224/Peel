import XCTest

@testable import PeelCore

final class HistoryGroupingTests: XCTestCase {
  private var calendar: Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC")!
    return calendar
  }
  private let now = ISO8601DateFormatter().date(from: "2026-10-08T12:00:00Z")!
  private func record(_ id: String, _ updatedAt: String, pinned: Bool = false) -> HistorySummary {
    HistorySummary(id: id, title: id, updatedAt: updatedAt, pinned: pinned)
  }
  func testGroupsFollowSidebarOrderAndSkipEmptySections() {
    let sections = HistoryGrouping.sections(
      [
        record("pin", "2025-01-01T00:00:00Z", pinned: true),
        record("today", "2026-10-08T01:00:00Z"),
        record("yesterday", "2026-10-07T23:59:59Z"),
        record("week", "2026-10-02T00:00:00Z"),
        record("month", "2026-09-30T23:59:59Z"),
        record("expired", "2026-08-01T00:00:00Z"),
      ], now: now, calendar: calendar)
    XCTAssertEqual(
      sections.map(\.group), [.pinned, .today, .yesterday, .previous7Days, .previous30Days, .expired])
    XCTAssertEqual(sections.map { $0.records.map(\.id) }, [["pin"], ["today"], ["yesterday"], ["week"], ["month"], ["expired"]])
    XCTAssertEqual(
      HistoryGrouping.sections([record("a", "2026-10-08T01:00:00Z")], now: now, calendar: calendar)
        .map(\.group), [.today])
  }
  func testKeepsStoreOrderInsideAGroup() {
    let sections = HistoryGrouping.sections(
      [record("b", "2026-10-08T09:00:00Z"), record("a", "2026-10-08T10:00:00Z")], now: now,
      calendar: calendar)
    XCTAssertEqual(sections.first?.records.map(\.id), ["b", "a"])
  }
  func testParsesFractionalSecondsAndKeepsInvalidDatesVisible() {
    let sections = HistoryGrouping.sections(
      [record("fraction", "2026-10-08T01:00:00.123Z"), record("invalid", "nope")], now: now,
      calendar: calendar)
    XCTAssertEqual(sections.map(\.group), [.today, .previous30Days])
  }
  func testExpiryStartsAfterThirtyDays() {
    func group(_ date: String) -> HistoryGroup {
      HistoryGrouping.group(for: record("r", date), now: now, calendar: calendar)
    }
    XCTAssertEqual(group("2026-09-08T00:00:00Z"), .previous30Days)
    XCTAssertEqual(group("2026-09-07T23:59:59Z"), .expired)
    XCTAssertTrue(HistoryGroup.expired.isExpired)
    XCTAssertFalse(HistoryGroup.previous30Days.isExpired)
    XCTAssertEqual(
      HistoryGrouping.group(for: record("p", "2020-01-01T00:00:00Z", pinned: true), now: now, calendar: calendar),
      .pinned)
  }
}
