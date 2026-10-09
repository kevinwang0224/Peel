import Foundation

public enum HistoryGroup: Hashable, Sendable {
  case pinned, today, yesterday, previous7Days, previous30Days, expired
  public var title: String {
    switch self {
    case .pinned: "Pinned"
    case .today: "Today"
    case .yesterday: "Yesterday"
    case .previous7Days: "Previous 7 Days"
    case .previous30Days: "Previous 30 Days"
    case .expired: "Older Than 30 Days"
    }
  }
  /// Records in this group are old enough to be folded away by default.
  public var isExpired: Bool { self == .expired }
}

public struct HistorySection: Identifiable, Sendable {
  public let group: HistoryGroup
  public let records: [HistorySummary]
  public var id: HistoryGroup { group }
}

extension HistorySummary {
  private static let plain = ISO8601DateFormatter()
  private static let fractional: ISO8601DateFormatter = {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter
  }()
  public var updatedDate: Date? {
    Self.plain.date(from: updatedAt) ?? Self.fractional.date(from: updatedAt)
  }
}

public enum HistoryGrouping {
  /// Pinned records first, then date buckets. Order inside a bucket is the store order.
  public static func sections(
    _ records: [HistorySummary], now: Date = Date(), calendar: Calendar = .current
  ) -> [HistorySection] {
    let today = calendar.startOfDay(for: now)
    var buckets: [HistoryGroup: [HistorySummary]] = [:]
    for record in records {
      buckets[group(for: record, today: today, calendar: calendar), default: []].append(record)
    }
    return [.pinned, .today, .yesterday, .previous7Days, .previous30Days, .expired].compactMap { group in
      buckets[group].map { HistorySection(group: group, records: $0) }
    }
  }
  public static func group(
    for record: HistorySummary, now: Date = Date(), calendar: Calendar = .current
  ) -> HistoryGroup {
    group(for: record, today: calendar.startOfDay(for: now), calendar: calendar)
  }
  private static func group(for record: HistorySummary, today: Date, calendar: Calendar)
    -> HistoryGroup
  {
    if record.pinned { return .pinned }
    // An unreadable date must never hide a record inside a collapsed section.
    guard let date = record.updatedDate else { return .previous30Days }
    let days =
      calendar.dateComponents([.day], from: calendar.startOfDay(for: date), to: today).day ?? 0
    switch days {
    case ..<1: return .today
    case 1: return .yesterday
    case 2...7: return .previous7Days
    case 8...30: return .previous30Days
    default: return .expired
    }
  }
}
