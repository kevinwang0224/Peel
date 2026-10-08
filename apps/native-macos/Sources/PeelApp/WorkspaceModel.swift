import AppKit
import Combine
import PeelCore

@MainActor
final class WorkspaceModel: ObservableObject {
  @Published var records: [HistorySummary] = []
  @Published var selectedID: String?
  @Published var text = ""
  private(set) var textRevision = 0
  @Published var title = "Untitled"
  @Published var extraction = ExtractionState()
  @Published var result = ExtractionResult(status: "idle", text: "")
  @Published var settings = AppSettings()
  @Published var search = ""
  @Published var issue: JSONIssue?
  @Published var summary: JSONSummary?
  @Published var error: String?
  @Published var dirty = false
  @Published var busy = false
  @Published var revealError = 0
  @Published var hasMore = false
  @Published var transitioning = false
  @Published private(set) var ready = false
  let temporary: Bool
  let store: HistoryStore
  var onSettingsChanged: ((AppSettings) throws -> Void)?
  var onSaved: (() -> Void)?
  var onSettingsSaved: ((AppSettings) -> Void)?
  private var record: HistoryRecord?
  private var revision = 0
  private var analysis: Task<Void, Never>?
  private var extractionTask: Task<Void, Never>?
  private var saveTask: Task<Void, Never>?
  private var searchTask: Task<Void, Never>?
  private let runner: ExtractionRunner

  init(store: HistoryStore, temporary: Bool = false, initialText: String = "") {
    self.store = store
    self.temporary = temporary
    let executable = Bundle.main.executableURL!.deletingLastPathComponent().appendingPathComponent(
      "PeelScript")
    runner = ExtractionRunner(executable: executable)
    if temporary {
      record = HistoryRecord(content: initialText)
      text = initialText
      selectedID = record?.id
    }
  }
  var query: String {
    extraction.queries[extraction.mode.rawValue] ?? (extraction.mode == .javascript ? "data" : "$")
  }

  func bootstrap(legacyFiles: [URL]) async {
    defer { ready = true }
    do {
      if !temporary {
        do { try await store.migrateLegacy(files: legacyFiles) } catch {
          self.error = error.localizedDescription
        }
      }
      settings = try await store.settings()
      do { try onSettingsChanged?(settings) } catch { self.error = error.localizedDescription }
      onSettingsSaved?(settings)
      if !temporary {
        await refresh()
        if let first = records.first { await select(first.id) } else { await create() }
      } else {
        scheduleAnalysis()
        scheduleExtraction()
      }
    } catch { self.error = error.localizedDescription }
  }
  func refresh(more: Bool = false) async {
    let expected = search
    do {
      let offset = more ? records.count : 0
      let page = try await store.list(search: expected, limit: 100, offset: offset)
      guard expected == search else { return }
      if more { records += page } else { records = page }
      hasMore = page.count == 100
    } catch { self.error = error.localizedDescription }
  }
  func searchChanged(_ value: String) {
    search = value
    searchTask?.cancel()
    searchTask = Task { [weak self] in
      do { try await Task.sleep(for: .milliseconds(200)) } catch { return }
      await self?.refresh()
    }
  }
  func select(_ id: String) async {
    guard id != selectedID, !transitioning else { return }
    transitioning = true
    defer { transitioning = false }
    guard await flush() else { return }
    do {
      guard let next = try await store.record(id: id) else { return }
      load(next)
    } catch { self.error = error.localizedDescription }
  }
  func create(content: String = "", title: String = "Untitled") async {
    guard !transitioning else { return }
    transitioning = true
    defer { transitioning = false }
    guard await flush() else { return }
    let next = HistoryRecord(title: title, content: content)
    do {
      try await store.save(next)
      load(next)
      await refresh()
    } catch { self.error = error.localizedDescription }
  }
  private func load(_ record: HistoryRecord) {
    stopTasks()
    self.record = record
    selectedID = record.id
    text = record.content
    textRevision += 1
    title = record.title
    extraction = record.extraction
    dirty = false
    result = ExtractionResult(status: "idle", text: "")
    revision += 1
    scheduleAnalysis()
    scheduleExtraction()
  }
  func edit(_ value: String) {
    guard ready, !transitioning, record != nil else { return }
    text = value
    textRevision += 1
    changed()
    scheduleAnalysis()
    scheduleExtraction()
  }
  func rename(_ value: String) {
    guard ready, !transitioning, record != nil else { return }
    title = value
    changed()
  }
  func setMode(_ mode: ExtractionMode) {
    guard ready, !transitioning, record != nil else { return }
    extraction.mode = mode
    changed()
    scheduleExtraction()
  }
  func setQuery(_ value: String) {
    guard ready, !transitioning, record != nil else { return }
    extraction.queries[extraction.mode.rawValue] = value
    changed()
    scheduleExtraction()
  }
  private func changed() {
    revision += 1
    dirty = true
    if temporary { return }
    saveTask?.cancel()
    saveTask = Task { [weak self] in
      do { try await Task.sleep(for: .milliseconds(320)) } catch { return }
      _ = await self?.flush()
    }
  }
  @discardableResult
  func flush(commitTemporary: Bool = false) async -> Bool {
    guard dirty || (temporary && commitTemporary) else { return true }
    if temporary && !commitTemporary { return true }
    guard var next = record else { return false }
    let version = revision
    next.content = text
    next.title = title.trimmingCharacters(in: .whitespacesAndNewlines)
    if next.title.isEmpty { next.title = "Untitled" }
    next.extraction = extraction
    next.updatedAt = ISO8601DateFormatter().string(from: Date())
    do {
      try await store.save(next)
      guard version == revision else { return false }
      record = next
      dirty = false
      if !temporary { await refresh() }
      onSaved?()
      return !dirty
    } catch {
      self.error = error.localizedDescription
      return false
    }
  }
  func remove(_ id: String) async {
    guard ready, !transitioning else { return }
    do {
      if selectedID == id {
        stopTasks()
        dirty = false
        selectedID = nil
        record = nil
        text = ""
      }
      try await store.delete(id: id)
      await refresh()
      if selectedID == nil {
        if let next = records.first { await select(next.id) } else { await create() }
      }
    } catch { self.error = error.localizedDescription }
  }
  func pin(_ id: String) async {
    guard ready, !transitioning else { return }
    guard await flush() else { return }
    do {
      guard var value = try await store.record(id: id) else { return }
      value.pinned.toggle()
      try await store.save(value)
      if id == selectedID { record = value }
      await refresh()
    } catch { self.error = error.localizedDescription }
  }
  func updateSettings(_ value: AppSettings) async {
    let old = settings
    do {
      try onSettingsChanged?(value)
      try await store.saveSettings(value)
      settings = value
      onSettingsSaved?(value)
    } catch {
      try? onSettingsChanged?(old)
      self.error = error.localizedDescription
    }
  }
  func format(compact: Bool) {
    guard ready, !transitioning, record != nil else { return }
    let source = text
    let version = revision
    Task {
      let result = await Task.detached(priority: .userInitiated) {
        Result { try JSONDocument.formatInput(source, compact: compact) }
      }.value
      guard version == revision else { return }
      switch result {
      case .success(let output): edit(output)
      case .failure(let error): self.error = error.localizedDescription
      }
    }
  }
  private func scheduleAnalysis() {
    analysis?.cancel()
    let source = text
    let version = revision
    analysis = Task { [weak self] in
      do { try await Task.sleep(for: .milliseconds(180)) } catch { return }
      let value = await Task.detached(priority: .userInitiated) {
        Result { try JSONDocument.summary(source) }
      }.value
      guard !Task.isCancelled, let self, version == self.revision else { return }
      switch value {
      case .success(let summary):
        self.summary = summary
        self.issue = nil
      case .failure(let error):
        self.summary = nil
        self.issue = error as? JSONIssue
      }
    }
  }
  private func scheduleExtraction() {
    extractionTask?.cancel()
    busy = false
    result = ExtractionResult(status: "idle", text: "")
    guard text.utf8.count <= 1024 * 1024, !text.isEmpty,
      !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    else { return }
    extractionTask = Task { [weak self] in
      do { try await Task.sleep(for: .milliseconds(400)) } catch { return }
      await self?.evaluate()
    }
  }
  func run() {
    extractionTask?.cancel()
    extractionTask = Task { [weak self] in await self?.evaluate() }
  }
  private func evaluate() async {
    let version = revision
    let request = ExtractionRequest(mode: extraction.mode, query: query, text: text)
    busy = true
    do {
      let value = try await runner.run(request)
      guard !Task.isCancelled, version == revision else { return }
      result = value
      busy = false
    } catch {
      guard !Task.isCancelled, version == revision else { return }
      result = ExtractionResult(status: "error", text: error.localizedDescription)
      busy = false
    }
  }
  func stopTasks() {
    analysis?.cancel()
    extractionTask?.cancel()
    saveTask?.cancel()
    searchTask?.cancel()
    analysis = nil
    extractionTask = nil
    saveTask = nil
    searchTask = nil
    busy = false
  }
  deinit {
    analysis?.cancel()
    extractionTask?.cancel()
    saveTask?.cancel()
    searchTask?.cancel()
  }
}
