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
    let size = model.temporary ? NSSize(width: 1050, height: 700) : NSSize(width: 1280, height: 820)
    let window = NSWindow(
      contentRect: NSRect(origin: .zero, size: size),
      styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false
    )
    window.title = model.temporary ? "Peel — Scratch" : "Peel"
    window.isReleasedWhenClosed = false
    super.init(window: window)
    workspace.importFile = { [weak self] in self?.openFile() }
    workspace.exportFile = { [weak self] in self?.exportFile() }
    workspace.saveTemporary = { [weak self] in self?.saveScratch() }
    window.contentViewController = workspace
    window.delegate = self
    window.center()
  }
  required init?(coder: NSCoder) { fatalError("Not supported") }
  func present() {
    showWindow(nil)
    window?.makeKeyAndOrderFront(nil)
    NSApp.activate(ignoringOtherApps: true)
  }
  func windowShouldClose(_ sender: NSWindow) -> Bool {
    if mayClose { return true }
    if !model.ready { return false }
    if closing { return false }
    if model.temporary && model.dirty {
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

@MainActor
final class ApplicationController: NSObject, NSApplicationDelegate {
  private var mainWindow: WorkspaceWindow?
  private var scratchWindows: [UUID: WorkspaceWindow] = [:]
  private var statusItem: NSStatusItem?
  private var store: HistoryStore!
  private var hotKey: GlobalHotKey?
  private var legacyFiles: [URL] = []
  private var terminationInProgress = false
  private let launchedAt = ProcessInfo.processInfo.systemUptime

  func applicationDidFinishLaunching(_ notification: Notification) {
    do {
      let support = FileManager.default.urls(
        for: .applicationSupportDirectory, in: .userDomainMask)[0]
      let directory =
        ProcessInfo.processInfo.environment["PEEL_DATA_DIRECTORY"].map { URL(fileURLWithPath: $0) }
        ?? support.appendingPathComponent("PeelNative")
      store = try HistoryStore(url: directory.appendingPathComponent("history.sqlite"))
      if ProcessInfo.processInfo.environment["PEEL_SKIP_MIGRATION"] != "1" {
        legacyFiles = ["peeldesktop", "@peel/desktop", "Peel"].map {
          support.appendingPathComponent($0).appendingPathComponent("peel-data.json")
        }
      }
      hotKey = try GlobalHotKey { [weak self] in self?.quickPaste() }
      setupMenus()
      setupStatusItem()
      showMain(nil)
    } catch {
      let alert = NSAlert()
      alert.messageText = "Peel could not start"
      alert.informativeText = error.localizedDescription
      alert.runModal()
      NSApp.terminate(nil)
    }
  }
  private func connect(_ model: WorkspaceModel) {
    model.onSettingsChanged = { [weak self] settings in
      guard let self else { return }
      try hotKey?.update(settings.quickPasteShortcut)
    }
    model.onSettingsSaved = { [weak self] settings in
      guard let self else { return }
      mainWindow?.model.settings = settings
      for controller in scratchWindows.values { controller.model.settings = settings }
    }
    guard model.temporary else { return }
    model.onSaved = { [weak self] in
      guard let model = self?.mainWindow?.model else { return }
      Task { await model.refresh() }
    }
  }
  @objc func showMain(_ sender: Any?) {
    if let mainWindow {
      mainWindow.present()
      return
    }
    let model = WorkspaceModel(store: store)
    connect(model)
    let controller = WorkspaceWindow(model: model)
    controller.didClose = { [weak self] in self?.mainWindow = nil }
    mainWindow = controller
    controller.present()
    Task {
      await model.bootstrap(legacyFiles: legacyFiles)
      mainWindow?.workspace.renderReady()
      if ProcessInfo.processInfo.environment["PEEL_METRICS"] == "1" {
        print("PEEL_READY_MS=\(Int((ProcessInfo.processInfo.systemUptime - launchedAt) * 1000))")
        fflush(stdout)
      }
      if ProcessInfo.processInfo.environment["PEEL_BENCHMARK"] == "1" {
        Task { await self.benchmark() }
      }
    }
  }
  private func benchmark() async {
    do {
      let unit = "  {\n    \"id\": 7,\n    \"name\": \"中文😀\",\n    \"active\": true\n  }"
      let text =
        "[\n"
        + Array(repeating: unit, count: (1024 * 1024 - 4) / (unit.utf8.count + 2)).joined(
          separator: ",\n") + "\n]"
      await mainWindow?.model.create(content: text, title: "1 MB benchmark")
      try await Task.sleep(for: .seconds(2))
      let p95 = await mainWindow?.workspace.benchmarkEdits() ?? 0
      print("PEEL_DOCUMENT_BYTES=\(text.utf8.count)")
      print("PEEL_EDIT_DRAW_P95_MS=\(p95)")
      fflush(stdout)
      try await Task.sleep(for: .seconds(35))
      print("PEEL_IDLE_FOOTPRINT_BYTES=\(PeelPhysicalFootprint())")
      fflush(stdout)
      mainWindow?.window?.performClose(nil)
      try await Task.sleep(for: .seconds(5))
      print("PEEL_CLOSED_FOOTPRINT_BYTES=\(PeelPhysicalFootprint())")
      fflush(stdout)
      NSApp.terminate(nil)
    } catch {
      print("PEEL_BENCHMARK_ERROR=\(error)")
      fflush(stdout)
      NSApp.terminate(nil)
    }
  }
  @objc func newDocument(_ sender: Any?) {
    showMain(sender)
    if let model = mainWindow?.model, model.ready { Task { await model.create() } }
  }
  @objc func newScratch(_ sender: Any?) { createScratch("") }
  @objc func quickPaste() {
    createScratch(JSONDocument.pasted(NSPasteboard.general.string(forType: .string) ?? ""))
  }
  private func createScratch(_ content: String) {
    let id = UUID()
    let model = WorkspaceModel(store: store, temporary: true, initialText: content)
    connect(model)
    let controller = WorkspaceWindow(model: model)
    controller.didClose = { [weak self] in self?.scratchWindows.removeValue(forKey: id) }
    scratchWindows[id] = controller
    controller.present()
    Task { await model.bootstrap(legacyFiles: []) }
  }
  private var activeWindow: WorkspaceWindow? {
    if let mainWindow, mainWindow.window === NSApp.keyWindow { return mainWindow }
    return scratchWindows.values.first { $0.window === NSApp.keyWindow }
  }
  @objc func openFile(_ sender: Any?) {
    if activeWindow == nil { showMain(sender) }
    activeWindow?.openFile()
  }
  @objc func exportFile(_ sender: Any?) { activeWindow?.exportFile() }
  @objc func format(_ sender: Any?) { activeWindow?.model.format(compact: false) }
  @objc func compact(_ sender: Any?) { activeWindow?.model.format(compact: true) }
  @objc func run(_ sender: Any?) { activeWindow?.model.run() }
  @objc func save(_ sender: Any?) {
    guard let controller = activeWindow else { return }
    if controller.model.temporary {
      controller.saveScratch()
    } else {
      Task { await controller.model.flush() }
    }
  }
  @objc func find(_ sender: Any?) { activeWindow?.workspace.showFind() }
  @objc func settings(_ sender: Any?) {
    if activeWindow == nil { showMain(sender) }
    activeWindow?.workspace.showSettings()
  }
  func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
    showMain(nil)
    return true
  }
  func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
  func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
    if terminationInProgress { return .terminateLater }
    for controller in scratchWindows.values where controller.model.dirty {
      let alert = NSAlert()
      alert.messageText = "Unsaved scratch windows"
      alert.informativeText = "Save each scratch window before quitting, or discard all changes."
      alert.addButton(withTitle: "Cancel")
      alert.addButton(withTitle: "Discard and Quit")
      if alert.runModal() == .alertFirstButtonReturn { return .terminateCancel }
      break
    }
    guard let model = mainWindow?.model, model.dirty else {
      mainWindow?.model.stopTasks()
      for controller in scratchWindows.values { controller.model.stopTasks() }
      return .terminateNow
    }
    terminationInProgress = true
    model.transitioning = true
    Task {
      let saved = await model.flush() && !model.dirty
      model.transitioning = false
      if saved {
        mainWindow?.model.stopTasks()
        for controller in scratchWindows.values { controller.model.stopTasks() }
      }
      terminationInProgress = false
      sender.reply(toApplicationShouldTerminate: saved)
    }
    return .terminateLater
  }
  private func setupStatusItem() {
    let status = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    status.button?.image = NSImage(
      systemSymbolName: "curlybraces", accessibilityDescription: "Peel")
    let menu = NSMenu()
    menu.addItem(item("Open Peel", #selector(showMain(_:))))
    menu.addItem(item("Quick Paste", #selector(quickPaste)))
    menu.addItem(item("New Scratch", #selector(newScratch(_:))))
    menu.addItem(.separator())
    menu.addItem(item("Quit Peel", #selector(NSApplication.terminate(_:)), target: NSApp))
    status.menu = menu
    statusItem = status
  }
  private func setupMenus() {
    let bar = NSMenu()
    let appMenu = NSMenu(title: "Peel")
    appMenu.addItem(
      item("About Peel", #selector(NSApplication.orderFrontStandardAboutPanel(_:)), target: NSApp))
    appMenu.addItem(item("Settings…", #selector(settings(_:)), key: ","))
    appMenu.addItem(.separator())
    appMenu.addItem(item("Hide Peel", #selector(NSApplication.hide(_:)), key: "h", target: NSApp))
    appMenu.addItem(
      item("Quit Peel", #selector(NSApplication.terminate(_:)), key: "q", target: NSApp))
    add(appMenu, to: bar)
    let file = NSMenu(title: "File")
    file.addItem(item("New JSON", #selector(newDocument(_:)), key: "n"))
    file.addItem(
      item("New Scratch", #selector(newScratch(_:)), key: "n", modifiers: [.command, .shift]))
    file.addItem(item("Open…", #selector(openFile(_:)), key: "o"))
    file.addItem(item("Save", #selector(save(_:)), key: "s"))
    file.addItem(
      item("Export…", #selector(exportFile(_:)), key: "s", modifiers: [.command, .shift]))
    file.addItem(item("Close Window", #selector(NSWindow.performClose(_:)), key: "w", target: nil))
    add(file, to: bar)
    let edit = NSMenu(title: "Edit")
    for (title, selector, key, flags) in [
      ("Undo", "undo:", "z", NSEvent.ModifierFlags.command),
      ("Redo", "redo:", "z", [.command, .shift]), ("Cut", "cut:", "x", .command),
      ("Copy", "copy:", "c", .command), ("Paste", "paste:", "v", .command),
      ("Select All", "selectAll:", "a", .command),
    ] {
      edit.addItem(
        item(title, NSSelectorFromString(selector), key: key, modifiers: flags, target: nil))
    }
    edit.addItem(item("Find…", #selector(find(_:)), key: "f"))
    add(edit, to: bar)
    let json = NSMenu(title: "JSON")
    json.addItem(item("Format", #selector(format(_:)), key: "f", modifiers: [.command, .shift]))
    json.addItem(item("Compact", #selector(compact(_:))))
    json.addItem(item("Run Extraction", #selector(run(_:)), key: "\r"))
    add(json, to: bar)
    let window = NSMenu(title: "Window")
    window.addItem(
      item("Minimize", #selector(NSWindow.performMiniaturize(_:)), key: "m", target: nil))
    add(window, to: bar)
    NSApp.windowsMenu = window
    NSApp.mainMenu = bar
  }
  private func add(_ submenu: NSMenu, to menu: NSMenu) {
    let entry = NSMenuItem()
    entry.title = submenu.title
    entry.submenu = submenu
    menu.addItem(entry)
  }
  private func item(
    _ title: String, _ action: Selector, key: String = "",
    modifiers: NSEvent.ModifierFlags = .command, target: AnyObject? = nil
  ) -> NSMenuItem {
    let entry = NSMenuItem(title: title, action: action, keyEquivalent: key)
    entry.keyEquivalentModifierMask = modifiers
    // Editing/window selectors use the responder chain; application actions use this controller.
    let responderSelectors = [
      "undo:", "redo:", "cut:", "copy:", "paste:", "selectAll:", "performClose:",
      "performMiniaturize:",
    ]
    entry.target =
      target ?? (responderSelectors.contains(NSStringFromSelector(action)) ? nil : self)
    return entry
  }
}
