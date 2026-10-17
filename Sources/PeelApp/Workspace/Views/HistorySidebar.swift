import PeelCore
import SwiftUI

@MainActor
struct HistorySidebar: View {
  @Environment(\.displayScale) private var displayScale
  let model: WorkspaceModel
  let actions: WorkspaceActions
  /// Rows highlighted in the list. One row is the open document; ⌘/⇧-click can add more.
  @State private var selection: Set<String> = []
  @State private var showExpired = false

  private var selectionBinding: Binding<Set<String>> {
    Binding(
      get: { selection },
      set: { next in
        selection = next
        // Only a single selection opens a document; multiple rows are for batch actions.
        guard next.count == 1, let id = next.first, model.ready, id != model.selectedID else {
          return
        }
        Task {
          await model.select(id)
          if model.selectedID != id, selection == [id] {
            selection = model.selectedID.map { [$0] } ?? []
          }
        }
      })
  }
  private var search: Binding<String> {
    Binding(get: { model.search }, set: { model.searchChanged($0) })
  }
  private var searching: Bool {
    !model.search.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }
  /// Search results are never hidden behind a collapsed section.
  private var expiredExpanded: Binding<Bool> {
    Binding(get: { showExpired || searching }, set: { showExpired = $0 })
  }
  /// While the expired section is folded, nothing past the loaded tail is worth fetching.
  private var needsMore: Bool {
    guard model.hasMore else { return false }
    if expiredExpanded.wrappedValue { return true }
    guard let last = model.records.last else { return true }
    return !HistoryGrouping.group(for: last).isExpired
  }

  var body: some View {
    List(selection: selectionBinding) {
      ForEach(HistoryGrouping.sections(model.records)) { section in
        if section.group.isExpired {
          Section(isExpanded: expiredExpanded) {
            records(section.records)
          } header: {
            Text("\(section.group.title) · \(section.records.count)")
          }
        } else {
          Section(section.group.title) { records(section.records) }
        }
      }
      if needsMore {
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
    .scrollContentBackground(.hidden)
    .background(Color(nsColor: .textBackgroundColor).ignoresSafeArea(.container, edges: .top))
    // Same hairline as the extraction divider so both sides of the editor match.
    .overlay(alignment: .trailing) {
      Rectangle()
        .fill(Color(nsColor: .separatorColor).opacity(0.6))
        .frame(width: 1 / displayScale)
        .ignoresSafeArea(.container, edges: .top)
        .allowsHitTesting(false)
    }
    // Native list gestures: double-click renames, right-click shows the menu, and plain
    // clicks keep selecting the row anywhere (text included).
    .contextMenu(forSelectionType: String.self) { ids in
      menu(for: ids)
    } primaryAction: { ids in
      if ids.count == 1, let id = ids.first { rename(id) }
    }
    .onDeleteCommand {
      let ids = selection.isEmpty ? model.selectedID.map { [$0] } ?? [] : Array(selection)
      if !ids.isEmpty { actions.deleteRecords?(ids) }
    }
    .onAppear { selection = model.selectedID.map { [$0] } ?? [] }
    .onChange(of: model.selectedID) { _, id in
      guard let id else { return }
      // Opening a document from elsewhere (new, import, delete) resets the highlight to it,
      // and reveals it if it sits in the folded section.
      if !selection.contains(id) { selection = [id] }
      if let record = model.records.first(where: { $0.id == id }),
        HistoryGrouping.group(for: record).isExpired
      {
        showExpired = true
      }
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
    .navigationSplitViewColumnWidth(min: 240, ideal: 260, max: 320)
  }
  @ViewBuilder
  private func menu(for ids: Set<String>) -> some View {
    let targets = model.records.filter { ids.contains($0.id) }
    if targets.count == 1, let record = targets.first {
      Button("Rename…", systemImage: "pencil") { rename(record.id) }
      Button(record.pinned ? "Unpin" : "Pin", systemImage: record.pinned ? "pin.slash" : "pin") {
        Task { await model.pin(record.id) }
      }
      Divider()
      Button("Delete…", systemImage: "trash", role: .destructive) {
        actions.deleteRecords?([record.id])
      }
    } else if targets.count > 1 {
      let unpin = targets.allSatisfy(\.pinned)
      Button(
        unpin ? "Unpin \(targets.count) Items" : "Pin \(targets.count) Items",
        systemImage: unpin ? "pin.slash" : "pin"
      ) {
        Task { await model.setPinned(targets.map(\.id), pinned: !unpin) }
      }
      Divider()
      Button("Delete \(targets.count) Items…", systemImage: "trash", role: .destructive) {
        actions.deleteRecords?(targets.map(\.id))
      }
    }
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
