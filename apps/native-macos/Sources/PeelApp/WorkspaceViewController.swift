import AppKit
import Combine
import PeelCore
import PeelEditor

@MainActor
final class WorkspaceViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate,
  NSTextFieldDelegate, NSSearchFieldDelegate
{
  let model: WorkspaceModel
  var importFile: (() -> Void)?
  var exportFile: (() -> Void)?
  var saveTemporary: (() -> Void)?
  var presentSettings: (() -> Void)?
  private let titleField = NSTextField()
  private let searchField = NSSearchField()
  private let table = NSTableView()
  private let status = NSButton()
  private let saved = NSTextField(labelWithString: "Saved")
  private let mode = NSSegmentedControl(
    labels: ["JavaScript", "JSONPath"], trackingMode: .selectOne, target: nil, action: nil)
  private let raw = PeelEditorView(frame: .zero)
  private let expression = PeelEditorView(frame: .zero)
  private var resultEditor: PeelEditorView?
  private let resultTitle = NSTextField(labelWithString: "Result")
  private let resultState = NSTextField(labelWithString: "Read only")
  private let extractionHint = NSTextField(labelWithString: "Runs automatically after editing")
  private let runButton = NSButton()
  private let loadMoreButton = NSButton()
  private var toolbarCoordinator: WorkspaceToolbar?
  private let documentSplit = NSSplitView()
  private let workspaceSplit = NSSplitView()
  private var needsInitialSplitLayout = true
  private var resultPane: NSView?
  private var resultSplitFraction: CGFloat = 0.55
  private let findField = NSSearchField()
  private let replaceField = NSTextField()
  private var findPanel: NSPanel?
  private weak var focusedEditor: PeelEditorView?
  private var renderedDocument = ""
  private var renderedTextRevision = -1
  private var renderedResult = ""
  private var renderedQuery = ""
  private var renderedMode: ExtractionMode?
  private var renderedReveal = 0
  private var renderedRecords: [String] = []
  private var subscription: AnyCancellable?
  private var refreshQueued = false
  private var rendering = false
  private var themeObserver: NSObjectProtocol?

  init(model: WorkspaceModel) {
    self.model = model
    super.init(nibName: nil, bundle: nil)
  }
  required init?(coder: NSCoder) { fatalError("Not supported") }
  override func loadView() {
    view = NSView(frame: NSRect(x: 0, y: 0, width: 1280, height: 820))
    titleField.placeholderString = "Untitled"
    titleField.font = .systemFont(ofSize: 17, weight: .semibold)
    titleField.isBordered = false
    titleField.drawsBackground = false
    titleField.delegate = self
    titleField.lineBreakMode = .byTruncatingTail
    titleField.setContentHuggingPriority(.defaultLow, for: .horizontal)
    saved.font = .systemFont(ofSize: 11)
    saved.textColor = .secondaryLabelColor

    let workspace = workspaceSplit
    workspace.isVertical = true
    workspace.dividerStyle = .thin
    if !model.temporary { workspace.addArrangedSubview(makeSidebar()) }
    let detail = NSView()
    let documentHeader = WorkspaceChrome.header(
      [
        WorkspaceChrome.symbol("curlybraces", size: 18), titleField, spacer(), saved,
      ], height: 58)
    detail.addSubview(documentHeader)
    documentHeader.translatesAutoresizingMaskIntoConstraints = false
    documentSplit.isVertical = true
    documentSplit.dividerStyle = .thin
    documentSplit.addArrangedSubview(editorPane("Source", editor: raw))
    showResult()
    detail.addSubview(documentSplit)
    documentSplit.translatesAutoresizingMaskIntoConstraints = false
    mode.target = self
    mode.action = #selector(extractionModeChanged(_:))
    mode.controlSize = .small
    mode.segmentStyle = .rounded
    let extractionLabel = WorkspaceChrome.label("Extraction", weight: .semibold)
    runButton.title = "Run"
    runButton.image = NSImage(systemSymbolName: "play.fill", accessibilityDescription: nil)
    runButton.imagePosition = .imageLeading
    runButton.bezelStyle = .rounded
    runButton.controlSize = .small
    runButton.target = self
    runButton.action = #selector(run)
    runButton.toolTip = "Run extraction (⌘Return)"
    extractionHint.font = .systemFont(ofSize: 11)
    extractionHint.textColor = .tertiaryLabelColor
    let controls = WorkspaceChrome.header(
      [
        WorkspaceChrome.symbol("line.3.horizontal.decrease", size: 13), extractionLabel, mode,
        spacer(), extractionHint, runButton,
      ], height: 40)
    detail.addSubview(controls)
    detail.addSubview(expression)
    controls.translatesAutoresizingMaskIntoConstraints = false
    expression.translatesAutoresizingMaskIntoConstraints = false
    NSLayoutConstraint.activate([
      documentHeader.topAnchor.constraint(equalTo: detail.topAnchor),
      documentHeader.leadingAnchor.constraint(equalTo: detail.leadingAnchor),
      documentHeader.trailingAnchor.constraint(equalTo: detail.trailingAnchor),
      documentSplit.topAnchor.constraint(equalTo: documentHeader.bottomAnchor),
      documentSplit.leadingAnchor.constraint(equalTo: detail.leadingAnchor),
      documentSplit.trailingAnchor.constraint(equalTo: detail.trailingAnchor),
      documentSplit.bottomAnchor.constraint(equalTo: controls.topAnchor),
      controls.leadingAnchor.constraint(equalTo: detail.leadingAnchor),
      controls.trailingAnchor.constraint(equalTo: detail.trailingAnchor),
      controls.bottomAnchor.constraint(equalTo: expression.topAnchor),
      expression.leadingAnchor.constraint(equalTo: detail.leadingAnchor),
      expression.trailingAnchor.constraint(equalTo: detail.trailingAnchor),
      expression.heightAnchor.constraint(equalToConstant: 96),
      expression.bottomAnchor.constraint(equalTo: detail.bottomAnchor),
    ])
    workspace.addArrangedSubview(detail)
    workspace.setHoldingPriority(.defaultLow, forSubviewAt: model.temporary ? 0 : 1)
    if !model.temporary { workspace.setHoldingPriority(.defaultHigh, forSubviewAt: 0) }
    view.addSubview(workspace)
    workspace.translatesAutoresizingMaskIntoConstraints = false
    status.bezelStyle = .inline
    status.isBordered = false
    status.alignment = .left
    status.target = self
    status.action = #selector(revealIssue)
    status.font = .systemFont(ofSize: 11)
    status.lineBreakMode = .byTruncatingTail
    let footer = WorkspaceChrome.header([status, spacer()], height: 28)
    view.addSubview(footer)
    footer.translatesAutoresizingMaskIntoConstraints = false
    NSLayoutConstraint.activate([
      workspace.topAnchor.constraint(equalTo: view.topAnchor),
      workspace.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      workspace.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      workspace.bottomAnchor.constraint(equalTo: footer.topAnchor),
      footer.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      footer.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      footer.bottomAnchor.constraint(equalTo: view.bottomAnchor),
      status.widthAnchor.constraint(lessThanOrEqualTo: footer.widthAnchor, constant: -28),
    ])
    raw.onChange = { [weak self] text in
      guard let self else { return }
      self.model.edit(text)
      self.renderedTextRevision = self.model.textRevision
    }
    raw.transformPaste = { JSONDocument.pasted($0) }
    expression.onChange = { [weak self] text in self?.model.setQuery(text) }
    for editor in [raw, expression] {
      editor.onRun = { [weak self] in self?.model.run() }
      editor.onFocus = { [weak self, weak editor] in self?.focusedEditor = editor }
    }
    focusedEditor = raw
    subscription = model.objectWillChange.sink { [weak self] _ in
      guard let self, !self.refreshQueued else { return }
      self.refreshQueued = true
      DispatchQueue.main.async { [weak self] in
        self?.refreshQueued = false
        self?.render()
      }
    }
    themeObserver = DistributedNotificationCenter.default().addObserver(
      forName: NSNotification.Name("AppleInterfaceThemeChangedNotification"), object: nil,
      queue: .main
    ) { [weak self] _ in
      Task { @MainActor in self?.render() }
    }
    render()
  }
  override func viewDidLayout() {
    super.viewDidLayout()
    extractionHint.isHidden = documentSplit.bounds.width < 760
    if needsInitialSplitLayout, documentSplit.bounds.width > 500 {
      needsInitialSplitLayout = false
      if !model.temporary { workspaceSplit.setPosition(264, ofDividerAt: 0) }
      documentSplit.setPosition(documentSplit.bounds.width * 0.55, ofDividerAt: 0)
    }
  }
  override func viewDidAppear() {
    super.viewDidAppear()
    raw.focusEditor()
  }
  func installToolbar(on window: NSWindow) {
    let actions: [WorkspaceToolbar.Action] = [
      .init("new", "New JSON", "square.and.pencil", #selector(newRecord), shortcut: "⌘N"),
      .init("open", "Open", "folder", #selector(open), shortcut: "⌘O"),
      .init(
        "format", "Format JSON", "text.alignleft", #selector(format), shortcut: "⇧⌘F",
        spacingBefore: .flexibleSpace),
      .init("compact", "Compact JSON", "text.justify", #selector(compact)),
      .init("find", "Find", "magnifyingglass", #selector(showFind), shortcut: "⌘F"),
      .init(
        "export", "Export", "square.and.arrow.up", #selector(export), shortcut: "⇧⌘S",
        spacingBefore: .space),
      .init("result", "Show / Hide Result", "sidebar.right", #selector(toggleResult)),
      .init("settings", "Settings", "gearshape", #selector(showSettings), shortcut: "⌘,"),
    ]
    let windowActions =
      model.temporary
      ? Array(actions.dropFirst()) + [
        .init(
          "save", "Save to History", "tray.and.arrow.down", #selector(commitScratch), shortcut: "⌘S"
        )
      ]
      : actions
    let coordinator = WorkspaceToolbar(
      target: self, identifier: model.temporary ? "Peel.scratch" : "Peel.workspace",
      actions: windowActions)
    toolbarCoordinator = coordinator
    window.toolbar = coordinator.toolbar
    window.toolbarStyle = .unifiedCompact
    window.titleVisibility = .hidden
  }
  private func makeSidebar() -> NSView {
    let sidebar = NSVisualEffectView()
    sidebar.material = .sidebar
    sidebar.blendingMode = .withinWindow
    sidebar.widthAnchor.constraint(greaterThanOrEqualToConstant: 240).isActive = true
    sidebar.widthAnchor.constraint(lessThanOrEqualToConstant: 360).isActive = true
    let label = WorkspaceChrome.label("History", weight: .semibold)
    label.textColor = .secondaryLabelColor
    let heading = WorkspaceChrome.header([label, spacer()], height: 38, separator: false)
    searchField.placeholderString = "Search history"
    searchField.delegate = self
    searchField.controlSize = .regular
    let scroll = NSScrollView()
    scroll.hasVerticalScroller = true
    scroll.autohidesScrollers = true
    scroll.drawsBackground = false
    let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("title"))
    table.addTableColumn(column)
    table.headerView = nil
    table.rowHeight = 48
    table.intercellSpacing = NSSize(width: 0, height: 2)
    table.dataSource = self
    table.delegate = self
    table.style = .sourceList
    table.backgroundColor = .clear
    let menu = NSMenu()
    menu.addItem(menuItem("Pin / Unpin", #selector(pinRecord)))
    menu.addItem(menuItem("Delete…", #selector(deleteRecord)))
    table.menu = menu
    scroll.documentView = table
    loadMoreButton.title = "Load more history"
    loadMoreButton.bezelStyle = .inline
    loadMoreButton.controlSize = .small
    loadMoreButton.target = self
    loadMoreButton.action = #selector(loadMore)
    for item in [heading, searchField, scroll, loadMoreButton] {
      sidebar.addSubview(item)
      item.translatesAutoresizingMaskIntoConstraints = false
    }
    NSLayoutConstraint.activate([
      heading.topAnchor.constraint(equalTo: sidebar.topAnchor, constant: 6),
      heading.leadingAnchor.constraint(equalTo: sidebar.leadingAnchor),
      heading.trailingAnchor.constraint(equalTo: sidebar.trailingAnchor),
      searchField.topAnchor.constraint(equalTo: heading.bottomAnchor),
      searchField.leadingAnchor.constraint(equalTo: sidebar.leadingAnchor, constant: 14),
      searchField.trailingAnchor.constraint(equalTo: sidebar.trailingAnchor, constant: -14),
      scroll.topAnchor.constraint(equalTo: searchField.bottomAnchor, constant: 12),
      scroll.leadingAnchor.constraint(equalTo: sidebar.leadingAnchor, constant: 6),
      scroll.trailingAnchor.constraint(equalTo: sidebar.trailingAnchor, constant: -6),
      scroll.bottomAnchor.constraint(equalTo: loadMoreButton.topAnchor, constant: -6),
      loadMoreButton.bottomAnchor.constraint(equalTo: sidebar.bottomAnchor, constant: -10),
      loadMoreButton.centerXAnchor.constraint(equalTo: sidebar.centerXAnchor),
    ])
    return sidebar
  }
  private func editorPane(_ title: String, editor: PeelEditorView, label: NSTextField? = nil)
    -> NSView
  {
    let pane = NSView()
    pane.widthAnchor.constraint(greaterThanOrEqualToConstant: 220).isActive = true
    let heading = label ?? WorkspaceChrome.label(title, weight: .medium)
    heading.font = .systemFont(ofSize: 12, weight: .medium)
    heading.textColor = .secondaryLabelColor
    let metadata = label == nil ? WorkspaceChrome.label("JSON", weight: .regular) : resultState
    metadata.font = .systemFont(ofSize: 10, weight: .medium)
    metadata.textColor = .tertiaryLabelColor
    let header = WorkspaceChrome.header([heading, spacer(), metadata], height: 34)
    pane.addSubview(header)
    pane.addSubview(editor)
    header.translatesAutoresizingMaskIntoConstraints = false
    editor.translatesAutoresizingMaskIntoConstraints = false
    NSLayoutConstraint.activate([
      header.topAnchor.constraint(equalTo: pane.topAnchor),
      header.leadingAnchor.constraint(equalTo: pane.leadingAnchor),
      header.trailingAnchor.constraint(equalTo: pane.trailingAnchor),
      editor.topAnchor.constraint(equalTo: header.bottomAnchor),
      editor.leadingAnchor.constraint(equalTo: pane.leadingAnchor),
      editor.trailingAnchor.constraint(equalTo: pane.trailingAnchor),
      editor.bottomAnchor.constraint(equalTo: pane.bottomAnchor),
    ])
    return pane
  }
  private func showResult() {
    let editor = PeelEditorView(frame: .zero)
    editor.onFocus = { [weak self, weak editor] in self?.focusedEditor = editor }
    resultEditor = editor
    let pane = editorPane("Result", editor: editor, label: resultTitle)
    resultPane = pane
    documentSplit.addArrangedSubview(pane)
    renderedResult = ""
  }
  private func render() {
    guard isViewLoaded else { return }
    rendering = true
    defer { rendering = false }
    view.window?.appearance =
      model.settings.theme == "system"
      ? nil : NSAppearance(named: model.settings.theme == "dark" ? .darkAqua : .aqua)
    let dark = view.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
    raw.configureLanguage(
      "json", dark: dark, fontSize: model.settings.editorFontSize,
      readOnly: !model.ready || model.transitioning || model.selectedID == nil)
    expression.configureLanguage(
      model.extraction.mode == .javascript ? "javascript" : "plaintext", dark: dark,
      fontSize: model.settings.editorFontSize,
      readOnly: !model.ready || model.transitioning || model.selectedID == nil)
    if renderedDocument != model.selectedID ?? "" {
      renderedDocument = model.selectedID ?? ""
      raw.loadDocument(model.text)
      expression.loadDocument(model.query)
      renderedTextRevision = model.textRevision
      renderedQuery = model.query
    } else {
      if renderedTextRevision != model.textRevision {
        raw.text = model.text
        renderedTextRevision = model.textRevision
      }
      if renderedQuery != model.query {
        expression.text = model.query
        renderedQuery = model.query
      }
    }
    if renderedMode != model.extraction.mode {
      expression.loadDocument(model.query)
      renderedMode = model.extraction.mode
    }
    raw.markError(
      atByte: model.issue?.byteOffset ?? -1, reveal: renderedReveal != model.revealError)
    renderedReveal = model.revealError
    titleField.isEnabled = model.ready && !model.transitioning && model.selectedID != nil
    mode.isEnabled = model.ready && !model.transitioning
    if titleField.stringValue != model.title { titleField.stringValue = model.title }
    mode.selectedSegment = model.extraction.mode == .javascript ? 0 : 1
    if let editor = resultEditor {
      editor.configureLanguage(
        model.result.structured ? "json" : "plaintext", dark: dark,
        fontSize: model.settings.editorFontSize, readOnly: true)
      if renderedResult != model.result.text {
        editor.loadDocument(model.result.text)
        renderedResult = model.result.text
      }
    }
    resultTitle.stringValue = "Result"
    resultState.stringValue =
      model.busy ? "Running…" : model.result.status == "error" ? "Extraction error" : "Read only"
    resultState.textColor = model.result.status == "error" ? .systemRed : .tertiaryLabelColor
    runButton.isEnabled = model.ready && !model.transitioning
    extractionHint.stringValue =
      (model.summary?.byteSize ?? 0) > 1024 * 1024
      ? "Large document · run manually" : "Auto-run · ⌘Return to run now"
    loadMoreButton.isHidden = !model.hasMore
    toolbarCoordinator?.setEnabled(model.ready && !model.transitioning)
    view.window?.title = model.temporary ? "Peel — Scratch" : model.title + " — Peel"
    if let issue = model.issue {
      status.title = issue.localizedDescription
      status.contentTintColor = .systemRed
    } else if let summary = model.summary {
      status.title =
        "\(summary.rootType) · \(summary.keyCount) keys · \(ByteCountFormatter.string(fromByteCount: Int64(summary.byteSize), countStyle: .file))"
      status.contentTintColor = .secondaryLabelColor
    }
    saved.stringValue =
      !model.ready
      ? "Initializing…"
      : model.temporary
        ? (model.dirty ? "Unsaved scratch" : "Scratch") : (model.dirty ? "Saving…" : "Saved")
    // Reload row titles as well as IDs: renaming/pinning must update the sidebar.
    let signature = model.records.map { "\($0.id)|\($0.title)|\($0.pinned)|\($0.updatedAt)" }
    if signature != renderedRecords {
      table.reloadData()
      renderedRecords = signature
    }
    if let index = model.records.firstIndex(where: { $0.id == model.selectedID }),
      table.selectedRow != index
    {
      table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
    }
    if let error = model.error, view.window?.attachedSheet == nil {
      model.error = nil
      let alert = NSAlert()
      alert.messageText = "Peel"
      alert.informativeText = error
      if let window = view.window { alert.beginSheetModal(for: window) }
    }
  }
  func numberOfRows(in tableView: NSTableView) -> Int { model.records.count }
  func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView?
  {
    let identifier = NSUserInterfaceItemIdentifier("history")
    let cell =
      tableView.makeView(withIdentifier: identifier, owner: self) as? HistoryCellView
      ?? HistoryCellView()
    cell.identifier = identifier
    cell.configure(model.records[row])
    return cell
  }
  func tableViewSelectionDidChange(_ notification: Notification) {
    guard !rendering, table.selectedRow >= 0, table.selectedRow < model.records.count else {
      return
    }
    let id = model.records[table.selectedRow].id
    Task { await model.select(id) }
  }
  func controlTextDidChange(_ notification: Notification) {
    if notification.object as? NSTextField === titleField {
      model.rename(titleField.stringValue)
    } else if notification.object as? NSTextField === searchField {
      model.searchChanged(searchField.stringValue)
    }
  }
  @objc private func newRecord() { if model.ready { Task { await model.create() } } }
  @objc private func loadMore() { Task { await model.refresh(more: true) } }
  @objc private func pinRecord() {
    let index = table.clickedRow >= 0 ? table.clickedRow : table.selectedRow
    if model.records.indices.contains(index) {
      let id = model.records[index].id
      Task { await model.pin(id) }
    }
  }
  @objc private func deleteRecord() {
    let index = table.clickedRow >= 0 ? table.clickedRow : table.selectedRow
    guard model.records.indices.contains(index), let window = view.window else { return }
    let id = model.records[index].id
    let alert = NSAlert()
    alert.messageText = "Delete this history record?"
    alert.addButton(withTitle: "Delete")
    alert.addButton(withTitle: "Cancel")
    alert.beginSheetModal(for: window) { [weak self] response in
      if response == .alertFirstButtonReturn { Task { await self?.model.remove(id) } }
    }
  }
  @objc private func open() { importFile?() }
  @objc private func export() { exportFile?() }
  @objc private func commitScratch() { saveTemporary?() }
  @objc private func format() { model.format(compact: false) }
  @objc private func compact() { model.format(compact: true) }
  @objc private func run() { model.run() }
  @objc private func extractionModeChanged(_ sender: NSSegmentedControl) {
    model.setMode(sender.selectedSegment == 0 ? .javascript : .jsonpath)
  }
  @objc private func revealIssue() { model.revealError += 1 }
  @objc private func toggleResult() {
    if let pane = resultPane {
      if documentSplit.bounds.width > 0, let source = documentSplit.arrangedSubviews.first {
        resultSplitFraction = source.frame.width / documentSplit.bounds.width
      }
      if focusedEditor === resultEditor { focusedEditor = raw }
      pane.removeFromSuperview()
      resultPane = nil
      resultEditor = nil
      renderedResult = ""
    } else {
      showResult()
      view.layoutSubtreeIfNeeded()
      documentSplit.setPosition(documentSplit.bounds.width * resultSplitFraction, ofDividerAt: 0)
      render()
    }
  }
  func renderReady() {
    render()
    raw.focusEditor()
    view.window?.displayIfNeeded()
  }
  func dismissFind() {
    findPanel?.close()
    findPanel = nil
  }
  @objc func showFind() {
    if let findPanel {
      findPanel.makeKeyAndOrderFront(nil)
      return
    }
    let panel = NSPanel(
      contentRect: NSRect(x: 0, y: 0, width: 510, height: 120),
      styleMask: [.titled, .closable, .utilityWindow], backing: .buffered, defer: false)
    panel.title = "Find and Replace"
    panel.isReleasedWhenClosed = false
    findField.placeholderString = "Find"
    replaceField.placeholderString = "Replace"
    findField.target = self
    findField.action = #selector(findNext)
    let actions = NSStackView(views: [
      button("Previous", #selector(findPrevious)), button("Next", #selector(findNext)),
      button("Replace", #selector(replaceOne)), button("Replace All", #selector(replaceAll)),
    ])
    let stack = NSStackView(views: [findField, replaceField, actions])
    stack.orientation = .vertical
    stack.spacing = 8
    stack.frame = NSRect(x: 12, y: 12, width: 486, height: 96)
    stack.autoresizingMask = [.width, .height]
    findField.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
    replaceField.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
    panel.contentView?.addSubview(stack)
    panel.center()
    findPanel = panel
    view.window?.addChildWindow(panel, ordered: .above)
    panel.makeKeyAndOrderFront(nil)
  }
  @objc private func findNext() {
    if !findField.stringValue.isEmpty {
      _ = focusedEditor?.findText(findField.stringValue, backwards: false)
    }
  }
  @objc private func findPrevious() {
    if !findField.stringValue.isEmpty {
      _ = focusedEditor?.findText(findField.stringValue, backwards: true)
    }
  }
  @objc private func replaceOne() { replace(all: false) }
  @objc private func replaceAll() { replace(all: true) }
  private func replace(all: Bool) {
    if !findField.stringValue.isEmpty {
      _ = focusedEditor?.replaceText(
        findField.stringValue, withText: replaceField.stringValue, all: all)
    }
  }
  @objc func showSettings() { presentSettings?() }
  /// Measures insertion through the actual editor and synchronous AppKit redraw.
  /// It does not measure keyboard-event dispatch or physical display scan-out.
  func benchmarkEdits(samples: Int = 60) async -> Double {
    var times: [Double] = []
    var insertion: [Double] = []
    var renderingTimes: [Double] = []
    var drawing: [Double] = []
    for _ in 0..<samples {
      let start = ProcessInfo.processInfo.systemUptime
      raw.insertText(atEnd: " ")
      let inserted = ProcessInfo.processInfo.systemUptime
      render()
      let rendered = ProcessInfo.processInfo.systemUptime
      view.window?.displayIfNeeded()
      let drawn = ProcessInfo.processInfo.systemUptime
      insertion.append((inserted - start) * 1000)
      renderingTimes.append((rendered - inserted) * 1000)
      drawing.append((drawn - rendered) * 1000)
      times.append((ProcessInfo.processInfo.systemUptime - start) * 1000)
      try? await Task.sleep(for: .milliseconds(30))
    }
    let index = min(times.count - 1, Int(Double(times.count) * 0.95))
    print("PEEL_INSERT_P95_MS=\(insertion.sorted()[index])")
    print("PEEL_RENDER_P95_MS=\(renderingTimes.sorted()[index])")
    print("PEEL_DRAW_P95_MS=\(drawing.sorted()[index])")
    return times.sorted()[index]
  }
  private func button(_ title: String, _ action: Selector) -> NSButton {
    let button = NSButton(title: title, target: self, action: action)
    button.bezelStyle = .rounded
    return button
  }
  private func spacer() -> NSView {
    let spacer = NSView()
    spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
    return spacer
  }
  private func menuItem(_ title: String, _ action: Selector) -> NSMenuItem {
    let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
    item.target = self
    return item
  }
  deinit {
    if let themeObserver { DistributedNotificationCenter.default().removeObserver(themeObserver) }
  }
}
