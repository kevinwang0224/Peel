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
  private let documentSplit = NSSplitView()
  private var resultPane: NSView?
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
    let toolbar = NSStackView()
    toolbar.orientation = .horizontal
    toolbar.spacing = 10
    let logo = NSTextField(labelWithString: "{ }")
    logo.font = .monospacedSystemFont(ofSize: 23, weight: .medium)
    logo.textColor = .controlAccentColor
    titleField.placeholderString = "Title"
    titleField.font = .systemFont(ofSize: 15, weight: .semibold)
    titleField.isBordered = false
    titleField.drawsBackground = false
    titleField.delegate = self
    titleField.widthAnchor.constraint(greaterThanOrEqualToConstant: 140).isActive = true
    titleField.widthAnchor.constraint(lessThanOrEqualToConstant: 300).isActive = true
    for item in [
      logo, titleField, spacer(), button("Open", #selector(open)),
      button("Export", #selector(export)), button("Format", #selector(format)),
      button("Compact", #selector(compact)), button("Result", #selector(toggleResult)),
      button("Settings", #selector(showSettings)),
    ] { toolbar.addArrangedSubview(item) }
    if model.temporary {
      toolbar.addArrangedSubview(button("Save to History", #selector(commitScratch)))
    }
    view.addSubview(toolbar)
    toolbar.translatesAutoresizingMaskIntoConstraints = false

    let workspace = NSSplitView()
    workspace.isVertical = true
    workspace.dividerStyle = .thin
    if !model.temporary { workspace.addArrangedSubview(makeSidebar()) }
    let detail = NSView()
    documentSplit.isVertical = true
    documentSplit.dividerStyle = .thin
    documentSplit.addArrangedSubview(editorPane("JSON", editor: raw))
    showResult()
    detail.addSubview(documentSplit)
    documentSplit.translatesAutoresizingMaskIntoConstraints = false
    let controls = NSStackView()
    controls.orientation = .horizontal
    controls.spacing = 10
    controls.addArrangedSubview(NSTextField(labelWithString: "Extraction"))
    mode.target = self
    mode.action = #selector(changeMode)
    controls.addArrangedSubview(mode)
    controls.addArrangedSubview(spacer())
    controls.addArrangedSubview(button("Run  ⌘↵", #selector(run)))
    detail.addSubview(controls)
    detail.addSubview(expression)
    controls.translatesAutoresizingMaskIntoConstraints = false
    expression.translatesAutoresizingMaskIntoConstraints = false
    NSLayoutConstraint.activate([
      documentSplit.topAnchor.constraint(equalTo: detail.topAnchor),
      documentSplit.leadingAnchor.constraint(equalTo: detail.leadingAnchor),
      documentSplit.trailingAnchor.constraint(equalTo: detail.trailingAnchor),
      documentSplit.bottomAnchor.constraint(equalTo: controls.topAnchor, constant: -4),
      controls.leadingAnchor.constraint(equalTo: detail.leadingAnchor, constant: 12),
      controls.trailingAnchor.constraint(equalTo: detail.trailingAnchor, constant: -12),
      controls.heightAnchor.constraint(equalToConstant: 32),
      controls.bottomAnchor.constraint(equalTo: expression.topAnchor, constant: -4),
      expression.leadingAnchor.constraint(equalTo: detail.leadingAnchor),
      expression.trailingAnchor.constraint(equalTo: detail.trailingAnchor),
      expression.heightAnchor.constraint(equalToConstant: 110),
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
    saved.font = .systemFont(ofSize: 11)
    saved.textColor = .secondaryLabelColor
    view.addSubview(status)
    view.addSubview(saved)
    status.translatesAutoresizingMaskIntoConstraints = false
    saved.translatesAutoresizingMaskIntoConstraints = false
    NSLayoutConstraint.activate([
      toolbar.topAnchor.constraint(equalTo: view.topAnchor, constant: 12),
      toolbar.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 14),
      toolbar.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -14),
      toolbar.heightAnchor.constraint(equalToConstant: 30),
      workspace.topAnchor.constraint(equalTo: toolbar.bottomAnchor, constant: 12),
      workspace.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      workspace.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      workspace.bottomAnchor.constraint(equalTo: status.topAnchor, constant: -8),
      status.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 12),
      status.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -8),
      status.heightAnchor.constraint(equalToConstant: 18),
      status.trailingAnchor.constraint(lessThanOrEqualTo: saved.leadingAnchor, constant: -10),
      saved.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -12),
      saved.centerYAnchor.constraint(equalTo: status.centerYAnchor),
    ])
    if !model.temporary { workspace.setPosition(230, ofDividerAt: 0) }
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
  override func viewDidAppear() {
    super.viewDidAppear()
    raw.focusEditor()
  }
  private func makeSidebar() -> NSView {
    let sidebar = NSView()
    sidebar.widthAnchor.constraint(greaterThanOrEqualToConstant: 180).isActive = true
    sidebar.widthAnchor.constraint(lessThanOrEqualToConstant: 340).isActive = true
    let heading = NSStackView(views: [
      NSTextField(labelWithString: "History"), spacer(), button("+", #selector(newRecord)),
    ])
    searchField.placeholderString = "Search title or content"
    searchField.delegate = self
    let scroll = NSScrollView()
    scroll.hasVerticalScroller = true
    scroll.autohidesScrollers = true
    let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("title"))
    column.title = "History"
    table.addTableColumn(column)
    table.headerView = nil
    table.rowHeight = 32
    table.dataSource = self
    table.delegate = self
    table.style = .sourceList
    let menu = NSMenu()
    menu.addItem(menuItem("Pin / Unpin", #selector(pinRecord)))
    menu.addItem(menuItem("Delete…", #selector(deleteRecord)))
    table.menu = menu
    scroll.documentView = table
    let more = button("Load More", #selector(loadMore))
    more.identifier = NSUserInterfaceItemIdentifier("more")
    for item in [heading, searchField, scroll, more] {
      sidebar.addSubview(item)
      item.translatesAutoresizingMaskIntoConstraints = false
    }
    NSLayoutConstraint.activate([
      heading.topAnchor.constraint(equalTo: sidebar.topAnchor, constant: 8),
      heading.leadingAnchor.constraint(equalTo: sidebar.leadingAnchor, constant: 12),
      heading.trailingAnchor.constraint(equalTo: sidebar.trailingAnchor, constant: -12),
      heading.heightAnchor.constraint(equalToConstant: 26),
      searchField.topAnchor.constraint(equalTo: heading.bottomAnchor, constant: 8),
      searchField.leadingAnchor.constraint(equalTo: sidebar.leadingAnchor, constant: 10),
      searchField.trailingAnchor.constraint(equalTo: sidebar.trailingAnchor, constant: -10),
      scroll.topAnchor.constraint(equalTo: searchField.bottomAnchor, constant: 8),
      scroll.leadingAnchor.constraint(equalTo: sidebar.leadingAnchor),
      scroll.trailingAnchor.constraint(equalTo: sidebar.trailingAnchor),
      scroll.bottomAnchor.constraint(equalTo: more.topAnchor, constant: -4),
      more.bottomAnchor.constraint(equalTo: sidebar.bottomAnchor, constant: -6),
      more.centerXAnchor.constraint(equalTo: sidebar.centerXAnchor),
    ])
    return sidebar
  }
  private func editorPane(_ title: String, editor: PeelEditorView, label: NSTextField? = nil)
    -> NSView
  {
    let pane = NSView()
    pane.widthAnchor.constraint(greaterThanOrEqualToConstant: 220).isActive = true
    let heading = label ?? NSTextField(labelWithString: title)
    heading.font = .systemFont(ofSize: 11, weight: .semibold)
    heading.textColor = .secondaryLabelColor
    pane.addSubview(heading)
    pane.addSubview(editor)
    heading.translatesAutoresizingMaskIntoConstraints = false
    editor.translatesAutoresizingMaskIntoConstraints = false
    NSLayoutConstraint.activate([
      heading.leadingAnchor.constraint(equalTo: pane.leadingAnchor, constant: 12),
      heading.topAnchor.constraint(equalTo: pane.topAnchor, constant: 8),
      heading.heightAnchor.constraint(equalToConstant: 18),
      editor.topAnchor.constraint(equalTo: heading.bottomAnchor, constant: 5),
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
    view.appearance =
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
    resultTitle.stringValue = model.busy ? "Result · Running…" : "Result"
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
    let signature = model.records.map { "\($0.id)|\($0.title)|\($0.pinned)" }
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
      tableView.makeView(withIdentifier: identifier, owner: self) as? NSTableCellView
      ?? NSTableCellView()
    cell.identifier = identifier
    if cell.textField == nil {
      let label = NSTextField(labelWithString: "")
      label.lineBreakMode = .byTruncatingTail
      cell.addSubview(label)
      label.translatesAutoresizingMaskIntoConstraints = false
      cell.textField = label
      NSLayoutConstraint.activate([
        label.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 10),
        label.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -6),
        label.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
      ])
    }
    let record = model.records[row]
    cell.textField?.stringValue = (record.pinned ? "📌 " : "") + record.title
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
  @objc private func revealIssue() { model.revealError += 1 }
  @objc private func toggleResult() {
    if let pane = resultPane {
      if focusedEditor === resultEditor { focusedEditor = raw }
      pane.removeFromSuperview()
      resultPane = nil
      resultEditor = nil
      renderedResult = ""
    } else {
      showResult()
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
  @objc func showSettings() {
    guard let window = view.window else { return }
    let appearance = NSPopUpButton()
    appearance.addItems(withTitles: ["System", "Light", "Dark"])
    appearance.selectItem(
      at: ["system", "light", "dark"].firstIndex(of: model.settings.theme) ?? 0)
    let font = NSPopUpButton()
    font.addItems(withTitles: (10...30).map { "\($0) pt" })
    font.selectItem(at: model.settings.editorFontSize - 10)
    let shortcut = NSTextField(string: model.settings.quickPasteShortcut)
    shortcut.placeholderString = "Command+Shift+J (empty disables)"
    let grid = NSGridView(views: [
      [NSTextField(labelWithString: "Appearance"), appearance],
      [NSTextField(labelWithString: "Editor font"), font],
      [NSTextField(labelWithString: "Quick Paste"), shortcut],
    ])
    grid.frame = NSRect(x: 0, y: 0, width: 410, height: 110)
    grid.rowSpacing = 14
    grid.columnSpacing = 12
    let alert = NSAlert()
    alert.messageText = "Settings"
    alert.accessoryView = grid
    alert.addButton(withTitle: "Save")
    alert.addButton(withTitle: "Cancel")
    alert.beginSheetModal(for: window) { [weak self] response in
      guard let self, response == .alertFirstButtonReturn else { return }
      var settings = model.settings
      settings.theme = ["system", "light", "dark"][appearance.indexOfSelectedItem]
      settings.editorFontSize = font.indexOfSelectedItem + 10
      settings.quickPasteShortcut = shortcut.stringValue
      Task { await self.model.updateSettings(settings) }
    }
  }
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
