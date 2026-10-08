import Foundation

public enum HistoryGroup: Hashable, Sendable {
  case pinned, today, yesterday, previous7Days, earlier
  public var title: String {
    switch self {
    case .pinned: "Pinned"
    case .today: "Today"
    case .yesterday: "Yesterday"
    case .previous7Days: "Previous 7 Days"
    case .earlier: "Earlier"
    }
  }
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
    return [.pinned, .today, .yesterday, .previous7Days, .earlier].compactMap { group in
      buckets[group].map { HistorySection(group: group, records: $0) }
    }
  }
  private static func group(for record: HistorySummary, today: Date, calendar: Calendar)
    -> HistoryGroup
  {
    if record.pinned { return .pinned }
    guard let date = record.updatedDate else { return .earlier }
    let days =
      calendar.dateComponents([.day], from: calendar.startOfDay(for: date), to: today).day ?? 0
    switch days {
    case ..<1: return .today
    case 1: return .yesterday
    case 2...7: return .previous7Days
    default: return .earlier
    }
  }
}
