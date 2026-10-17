import Foundation
import PeelCore

@main
enum PeelBench {
  static func main() async throws {
    let args = Array(CommandLine.arguments.dropFirst())
    if args.first == "seed", args.count == 4, let count = Int(args[2]), let size = Int(args[3]),
      (1...10000).contains(count), (2...10_485_760).contains(size)
    {
      let directory = URL(fileURLWithPath: args[1])
      let store = try HistoryStore(url: directory.appendingPathComponent("history.sqlite"))
      let body = "[\"" + String(repeating: "x", count: max(0, size - 4)) + "\"]"
      for index in 0..<count {
        var record = HistoryRecord(
          id: "benchmark-\(index)", title: "Benchmark \(index)", content: body)
        record.extraction.queries["javascript"] = "data[0].length"
        try await store.save(record)
      }
      print("Seeded \(count) records × \(body.utf8.count) bytes")
      return
    }
    let unit = "{\"id\":7,\"name\":\"中文😀\",\"active\":true}"
    for megabytes in [1, 10] {
      let count = (megabytes * 1024 * 1024 - 2) / (unit.utf8.count + 1)
      let text = "[" + Array(repeating: unit, count: count).joined(separator: ",") + "]"
      let start = ProcessInfo.processInfo.systemUptime
      let summary = try JSONDocument.summary(text)
      let validation = (ProcessInfo.processInfo.systemUptime - start) * 1000
      let formattingStart = ProcessInfo.processInfo.systemUptime
      let formatted = try JSONDocument.format(text)
      let formatting = (ProcessInfo.processInfo.systemUptime - formattingStart) * 1000
      let compact = try JSONDocument.format(formatted, compact: true)
      guard compact == text else { throw StorageError(message: "Formatting round trip failed") }
      print(
        "JSON bytes=\(text.utf8.count) keys=\(summary.keyCount) validate_ms=\(validation) format_ms=\(formatting)"
      )
    }
  }
}
