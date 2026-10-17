import AppKit
import PeelCore
import PeelEditor

@MainActor
final class WorkspaceWindow: NSWindowController, NSWindowDelegate {
  let model: WorkspaceModel
  var didClose: (() -> Void)?
  let workspace: WorkspaceViewController
  private var mayClose = false
  private var closing = false
  init(model: WorkspaceModel) {
    self.model = model
    workspace = WorkspaceViewController(model: model)
    let size = model.temporary ? NSSize(width: 1100, height: 720) : NSSize(width: 1280, height: 820)
    let window = NSWindow(
      contentRect: NSRect(origin: .zero, size: size),
      // fullSizeContentView lets the SwiftUI split view own the safe area under the toolbar; without it
      // the system's titlebar scroll pocket is drawn over the first 52pt of the detail content.
      styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
      backing: .buffered, defer: false
    )
    window.title = model.temporary ? "Peel — Scratch" : "Peel"
    window.isReleasedWhenClosed = false
    super.init(window: window)
    workspace.importFile = { [weak self] in self?.openFile() }
    workspace.openURL = { [weak self] url in self?.open(url) }
    workspace.exportFile = { [weak self] in self?.exportFile() }
    workspace.saveTemporary = { [weak self] in self?.saveScratch() }
    let content = WorkspaceSplitViewController(workspace: workspace)
    // contentViewController adopts the view's size, so give it the window's size up front.
    content.view.frame = NSRect(origin: .zero, size: size)
    window.contentViewController = content
    window.contentMinSize = NSSize(width: model.temporary ? 800 : 900, height: model.temporary ? 420 : 500)
    workspace.installToolbar(on: window)
    window.toolbarStyle = .unified
    window.delegate = self
    window.center()
    if !model.temporary, ProcessInfo.processInfo.environment["PEEL_DATA_DIRECTORY"] == nil {
      window.setFrameAutosaveName("Peel.main")
      window.setFrameUsingName("Peel.main")
    }
  }
  required init?(coder: NSCoder) { fatalError("Not supported") }
  func present() {
    if model.temporary {
      // Center before the window is ordered in; centering afterwards makes it visibly jump.
      window?.layoutIfNeeded()
      window?.center()
    }
    showWindow(nil)
    window?.makeKeyAndOrderFront(nil)
    NSApp.activate(ignoringOtherApps: true)
  }
  func windowShouldClose(_ sender: NSWindow) -> Bool {
    if mayClose { return true }
    if !model.ready { return false }
    if closing { return false }
    if model.temporary && model.dirty && !model.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      let alert = NSAlert()
      alert.messageText = "Save scratch to history?"
      alert.informativeText = "Your changes have not been saved."
      alert.addButton(withTitle: "Save")
      alert.addButton(withTitle: "Cancel")
      alert.addButton(withTitle: "Discard")
      switch alert.runModal() {
      case .alertFirstButtonReturn: saveScratch()
      case .alertThirdButtonReturn: finishClose()
      default: break
      }
    } else {
      closing = true
      model.transitioning = true
      Task { [weak self] in
        guard let self else { return }
        // Keep the window alive if persistence fails, or edits arrive during the flush.
        if await model.flush(), !model.dirty || model.temporary { finishClose() }
        model.transitioning = false
        closing = false
      }
    }
    return false
  }
  func windowWillClose(_ notification: Notification) {
    model.stopTasks()
    window?.contentViewController = nil
    workspace.dismissFind()
    didClose?()
  }
  private func finishClose() {
    mayClose = true
    window?.close()
  }
  func saveScratch() {
    guard !closing, model.ready else { return }
    closing = true
    model.transitioning = true
    Task { [weak self] in
      guard let self else { return }
      if await model.flush(commitTemporary: true), !model.dirty { finishClose() }
      model.transitioning = false
      closing = false
    }
  }
  func openFile() {
    let panel = NSOpenPanel()
    panel.allowedContentTypes = [.json, .plainText]
    panel.allowsMultipleSelection = false
    guard panel.runModal() == .OK, let url = panel.url else { return }
    open(url)
  }
  func open(_ url: URL) {
    Task {
      do {
        let contents = try await Task.detached { try String(contentsOf: url, encoding: .utf8) }
          .value
        if model.temporary {
          model.edit(contents)
          model.rename(url.deletingPathExtension().lastPathComponent)
        } else {
          await model.create(
            content: contents, title: url.deletingPathExtension().lastPathComponent)
        }
      } catch { model.error = error.localizedDescription }
    }
  }
  func exportFile() {
    let panel = NSSavePanel()
    panel.allowedContentTypes = [.json]
    panel.nameFieldStringValue = "\(model.title).json"
    guard panel.runModal() == .OK, let url = panel.url else { return }
    let contents = model.text
    Task {
      do {
        try await Task.detached { try contents.write(to: url, atomically: true, encoding: .utf8) }
          .value
      } catch { model.error = error.localizedDescription }
    }
  }
}
