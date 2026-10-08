import PeelCore
import SwiftUI

@MainActor
struct HistorySidebar: View {
  let model: WorkspaceModel
  let actions: WorkspaceActions

  private var selection: Binding<String?> {
    Binding(
      get: { model.selectedID },
      set: { id in
        guard model.ready, let id else { return }
        Task { await model.select(id) }
      })
  }
  private var search: Binding<String> {
    Binding(get: { model.search }, set: { model.searchChanged($0) })
  }
  var body: some View {
    List(selection: selection) {
      if model.records.contains(where: \.pinned) {
        Section("Pinned") { records(model.records.filter(\.pinned)) }
      }
      Section("Recent") { records(model.records.filter { !$0.pinned }) }
    }
    .listStyle(.sidebar)
    .searchable(text: search, placement: .sidebar, prompt: "Search history")
    .safeAreaInset(edge: .bottom) {
      if model.hasMore {
        Button("Load more history") { Task { await model.refresh(more: true) } }
          .buttonStyle(.borderless).font(.caption).padding(10)
      }
    }
    .disabled(!model.ready || model.transitioning)
    .navigationSplitViewColumnWidth(min: 210, ideal: 240, max: 320)
  }
  private func records(_ values: [HistorySummary]) -> some View {
    ForEach(values) { record in
      HistoryRow(record: record).tag(record.id)
        .contextMenu {
          Button(record.pinned ? "Unpin" : "Pin", systemImage: record.pinned ? "pin.slash" : "pin")
          {
            Task { await model.pin(record.id) }
          }
          Divider()
          Button("Delete…", systemImage: "trash", role: .destructive) {
            actions.deleteRecord?(record.id)
          }
        }
    }
  }
}

private struct HistoryRow: View {
  let record: HistorySummary
  private static let iso = ISO8601DateFormatter()
  private static let fractional: ISO8601DateFormatter = {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter
  }()
  private var date: String {
    guard
      let date = Self.iso.date(from: record.updatedAt)
        ?? Self.fractional.date(from: record.updatedAt)
    else { return "" }
    if Calendar.current.isDateInToday(date) {
      return "Today · " + date.formatted(date: .omitted, time: .shortened)
    }
    return date.formatted(date: .abbreviated, time: .omitted)
  }
  var body: some View {
    HStack(spacing: 9) {
      Image(systemName: record.pinned ? "pin.fill" : "doc.text")
        .foregroundStyle(.secondary).frame(width: 16)
      VStack(alignment: .leading, spacing: 3) {
        Text(record.title).font(.system(size: 12)).lineLimit(1)
        Text(date).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
      }
    }
    .padding(.vertical, 3)
    .help(record.title)
  }
}
