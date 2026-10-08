import AppKit
import PeelCore
import PeelEditor
import SwiftUI

/// Hosting boundary keeps the existing save/close lifecycle, while SwiftUI owns the interface.
@MainActor
final class WorkspaceViewController: NSHostingController<WorkspaceView> {
  let model: WorkspaceModel
  private let presentation = WorkspacePresentation()
  private let actions = WorkspaceActions()
  private var windowToolbar: WorkspaceWindowToolbar?
  var importFile: (() -> Void)? {
    get { actions.importFile }
    set { actions.importFile = newValue }
  }
  var exportFile: (() -> Void)? {
    get { actions.exportFile }
    set { actions.exportFile = newValue }
  }
  var saveTemporary: (() -> Void)? {
    get { actions.saveTemporary }
    set { actions.saveTemporary = newValue }
  }
  var presentSettings: (() -> Void)? {
    get { actions.presentSettings }
    set { actions.presentSettings = newValue }
  }
  init(model: WorkspaceModel) {
    self.model = model
    super.init(rootView: WorkspaceView(model: model, presentation: presentation, actions: actions))
    sizingOptions = []
    sceneBridgingOptions = [.title]
    actions.deleteRecord = { [weak self] id in self?.confirmDelete(id) }

  }
  @MainActor required dynamic init?(coder: NSCoder) { fatalError("Not supported") }
  func installToolbar(on window: NSWindow) {
    let toolbar = WorkspaceWindowToolbar(target: self, temporary: model.temporary)
    windowToolbar = toolbar
    window.toolbar = toolbar.toolbar
  }
  @objc func newDocument() {
    guard model.ready, !model.temporary else { return }
    Task { await model.create() }
  }
  @objc func openDocument() { actions.importFile?() }
  @objc func formatDocument() { model.format(compact: false) }
  @objc func compactDocument() { model.format(compact: true) }
  @objc func runExtraction() { model.run() }
  @objc func saveScratch() { actions.saveTemporary?() }
  func renderReady() async {
    for _ in 0..<100 {
      view.layoutSubtreeIfNeeded()
      if presentation.source?.editor != nil { break }
      try? await Task.sleep(for: .milliseconds(10))
    }
    presentation.synchronizeEditors()
    presentation.source?.editor?.focusEditor()
    view.window?.toolbar?.validateVisibleItems()
    view.window?.displayIfNeeded()
  }
  func dismissFind() { presentation.findVisible = false }
  @objc func showFind() {
    presentation.findVisible = true
    presentation.findFocusRequest += 1
  }
  func showRename() {
    guard model.ready, !model.transitioning else { return }
    presentation.renameText = model.title
    presentation.renameVisible = true
  }
  @objc func toggleSidebar() {
    presentation.toggleSidebar()
  }
  @objc func toggleExtraction() { presentation.toggleExtraction() }
  private func confirmDelete(_ id: String) {
    guard let window = view.window else { return }
    let alert = NSAlert()
    alert.messageText = "Delete this history record?"
    alert.addButton(withTitle: "Delete")
    alert.addButton(withTitle: "Cancel")
    alert.beginSheetModal(for: window) { [weak self] response in
      guard response == .alertFirstButtonReturn, let self else { return }
      Task { await self.model.remove(id) }
    }
  }
  /// Diagnostic insertion + AppKit redraw, excluding keyboard dispatch/display scan-out.
  func benchmarkEdits(samples: Int = 60) async -> Double {
    guard let editor = presentation.source?.editor else { return .infinity }
    var times: [Double] = []
    var insertions: [Double] = []
    var synchronizations: [Double] = []
    var layouts: [Double] = []
    for _ in 0..<samples {
      let start = ProcessInfo.processInfo.systemUptime
      editor.insertText(atEnd: " ")
      let inserted = ProcessInfo.processInfo.systemUptime
      presentation.synchronizeEditors()
      let synchronized = ProcessInfo.processInfo.systemUptime
      view.layoutSubtreeIfNeeded()
      let laidOut = ProcessInfo.processInfo.systemUptime
      view.window?.displayIfNeeded()
      insertions.append((inserted - start) * 1000)
      synchronizations.append((synchronized - inserted) * 1000)
      layouts.append((laidOut - synchronized) * 1000)
      times.append((ProcessInfo.processInfo.systemUptime - start) * 1000)
      try? await Task.sleep(for: .milliseconds(30))
    }
    let index = min(times.count - 1, Int(Double(times.count) * 0.95))
    print("PEEL_INSERT_P95_MS=\(insertions.sorted()[index])")
    print("PEEL_SYNC_P95_MS=\(synchronizations.sorted()[index])")
    print("PEEL_LAYOUT_P95_MS=\(layouts.sorted()[index])")
    return times.sorted()[index]
  }
}

// Standard AppKit validation follows the same readiness boundary as the SwiftUI content.
extension WorkspaceViewController: NSToolbarItemValidation {
  func validateToolbarItem(_ item: NSToolbarItem) -> Bool { model.ready && !model.transitioning }
}
