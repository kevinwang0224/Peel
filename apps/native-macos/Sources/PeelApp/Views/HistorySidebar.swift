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
      ForEach(HistoryGrouping.sections(model.records)) { section in
        Section(section.group.title) { records(section.records) }
      }
      if model.hasMore {
        // Sentinel row: reaching the bottom of the list loads the next page.
        HStack {
          Spacer()
          ProgressView().controlSize(.small)
          Spacer()
        }
        .listRowSeparator(.hidden)
        .onAppear { Task { await model.refresh(more: true) } }
      }
    }
    .listStyle(.sidebar)
    // Native list gestures: double-click renames, right-click shows the menu, and plain
    // clicks keep selecting the row anywhere (text included).
    .contextMenu(forSelectionType: String.self) { ids in
      if let id = ids.first, let record = model.records.first(where: { $0.id == id }) {
        Button("Rename…", systemImage: "pencil") { rename(id) }
        Button(record.pinned ? "Unpin" : "Pin", systemImage: record.pinned ? "pin.slash" : "pin") {
          Task { await model.pin(id) }
        }
        Divider()
        Button("Delete…", systemImage: "trash", role: .destructive) {
          actions.deleteRecord?(id)
        }
      }
    } primaryAction: { ids in
      if let id = ids.first { rename(id) }
    }
    .onDeleteCommand {
      if let id = model.selectedID { actions.deleteRecord?(id) }
    }
    .searchable(text: search, placement: .sidebar, prompt: "Search history")
    .overlay {
      if model.records.isEmpty && model.ready {
        if model.search.isEmpty {
          ContentUnavailableView(
            "No History", systemImage: "clock", description: Text("JSON you edit appears here."))
        } else {
          ContentUnavailableView.search(text: model.search)
        }
      }
    }
    .disabled(!model.ready)
    .navigationSplitViewColumnWidth(min: 210, ideal: 240, max: 320)
  }
  private func records(_ values: [HistorySummary]) -> some View {
    ForEach(values) { record in
      HistoryRow(record: record).tag(record.id)
    }
  }
  private func rename(_ id: String) {
    Task {
      await model.select(id)
      actions.renameCurrent?()
    }
  }
}

private struct HistoryRow: View {
  let record: HistorySummary
  private var detail: String {
    guard let date = record.updatedDate else { return "" }
    return Calendar.current.isDateInToday(date) || Calendar.current.isDateInYesterday(date)
      ? date.formatted(date: .omitted, time: .shortened)
      : date.formatted(date: .abbreviated, time: .omitted)
  }
  var body: some View {
    VStack(alignment: .leading, spacing: 2) {
      HStack(spacing: 4) {
        if record.pinned {
          Image(systemName: "pin.fill").font(.system(size: 9)).foregroundStyle(.orange)
        }
        Text(record.title).lineLimit(1)
      }
      Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
    }
    .padding(.vertical, 2)
    .help(record.title)
  }
}
