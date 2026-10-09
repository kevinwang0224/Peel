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
    let size = model.temporary ? NSSize(width: 940, height: 620) : NSSize(width: 1280, height: 820)
    let window = NSWindow(
      contentRect: NSRect(origin: .zero, size: size),
      styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false
    )
    window.title = model.temporary ? "Peel — Scratch" : "Peel"
    window.isReleasedWhenClosed = false
    window.contentMinSize = NSSize(width: model.temporary ? 720 : 900, height: model.temporary ? 360 : 500)
    super.init(window: window)
    workspace.importFile = { [weak self] in self?.openFile() }
    workspace.openURL = { [weak self] url in self?.open(url) }
    workspace.exportFile = { [weak self] in self?.exportFile() }
    workspace.saveTemporary = { [weak self] in self?.saveScratch() }
    window.contentViewController = workspace
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

@MainActor
final class ApplicationController: NSObject, NSApplicationDelegate {
  private var mainWindow: WorkspaceWindow?
  private var scratchWindows: [UUID: WorkspaceWindow] = [:]
  private var statusItem: NSStatusItem?
  private var store: HistoryStore!
  private var hotKey: GlobalHotKey?
  private var settingsWindow: SettingsWindow?
  private var currentSettings = AppSettings()
  private var settingsReady = false
  private var settingsRequested = false
  private var memoryCleanup: Task<Void, Never>?
  private var legacyFiles: [URL] = []
  private var terminationInProgress = false
  private var selectionPreferenceKey = ""
  private let launchedAt = ProcessInfo.processInfo.systemUptime

  func applicationDidFinishLaunching(_ notification: Notification) {
    if let icon = Bundle.main.url(forResource: "AppIcon", withExtension: "icns") {
      NSApp.applicationIconImage = NSImage(contentsOf: icon)
    }
    if ProcessInfo.processInfo.environment["PEEL_METRICS"] == "1" {
      print("PEEL_DID_FINISH_MS=\((ProcessInfo.processInfo.systemUptime - launchedAt) * 1000)")
      fflush(stdout)
    }
    do {
      let support = FileManager.default.urls(
        for: .applicationSupportDirectory, in: .userDomainMask)[0]
      let directory =
        ProcessInfo.processInfo.environment["PEEL_DATA_DIRECTORY"].map { URL(fileURLWithPath: $0) }
        ?? support.appendingPathComponent("PeelNative")
      store = try HistoryStore(url: directory.appendingPathComponent("history.sqlite"))
      selectionPreferenceKey = "PeelNative.lastRecord:\(directory.standardizedFileURL.path)"
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
    model.onSaved = { [weak self, weak model] in
      guard let self else { return }
      scheduleMemoryCleanup()
      if model?.temporary == true, let mainModel = mainWindow?.model {
        Task { await mainModel.refresh() }
      }
    }
    model.onSettingsChanged = { [weak self] settings in
      guard let self else { return }
      try hotKey?.update(settings.quickPasteShortcut)
    }
    model.onSettingsSaved = { [weak self] settings in
      guard let self else { return }
      publishSettings(settings)
    }
    if !model.temporary {
      model.onSelectionChanged = { [weak self] id in
        guard let self else { return }
        UserDefaults.standard.set(id, forKey: self.selectionPreferenceKey)
      }
      return
    }
  }
  private func scheduleMemoryCleanup() {
    memoryCleanup?.cancel()
    memoryCleanup = Task.detached(priority: .utility) {
      do { try await Task.sleep(for: .seconds(3)) } catch { return }
      guard !Task.isCancelled else { return }
      PeelReleaseUnusedMemory()
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
    if ProcessInfo.processInfo.environment["PEEL_METRICS"] == "1" {
      print("PEEL_CONSTRUCTED_MS=\((ProcessInfo.processInfo.systemUptime - launchedAt) * 1000)")
      fflush(stdout)
    }
    controller.workspace.presentSettings = { [weak self] in self?.settings(nil) }
    controller.didClose = { [weak self] in
      self?.mainWindow = nil
      self?.scheduleMemoryCleanup()
    }
    mainWindow = controller
    controller.present()
    if ProcessInfo.processInfo.environment["PEEL_METRICS"] == "1" {
      print("PEEL_PRESENTED_MS=\((ProcessInfo.processInfo.systemUptime - launchedAt) * 1000)")
      fflush(stdout)
    }
    Task {
      let bootstrapStart = ProcessInfo.processInfo.systemUptime
      await model.bootstrap(
        legacyFiles: legacyFiles,
        preferredRecordID: UserDefaults.standard.string(forKey: selectionPreferenceKey))
      let installedAt = ProcessInfo.processInfo.systemUptime
      await mainWindow?.workspace.renderReady()
      if ProcessInfo.processInfo.environment["PEEL_METRICS"] == "1" {
        print("PEEL_BOOTSTRAP_MS=\((installedAt - bootstrapStart) * 1000)")
        print(
          "PEEL_INITIAL_RENDER_MS=\((ProcessInfo.processInfo.systemUptime - installedAt) * 1000)")
        print("PEEL_READY_MS=\(Int((ProcessInfo.processInfo.systemUptime - launchedAt) * 1000))")
        fflush(stdout)
      }
      if ProcessInfo.processInfo.environment["PEEL_STARTUP_ONLY"] == "1" { NSApp.terminate(nil) }
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
        + Array(repeating: unit, count: (1024 * 1024 - 128) / (unit.utf8.count + 2)).joined(
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
    guard let model = mainWindow?.model else { return }
    Task {
      while !model.ready { try? await Task.sleep(for: .milliseconds(10)) }
      await model.create()
    }
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
    controller.workspace.presentSettings = { [weak self] in self?.settings(nil) }
    controller.didClose = { [weak self] in
      self?.scratchWindows.removeValue(forKey: id)
      self?.scheduleMemoryCleanup()
    }
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
    guard let controller = activeWindow else { return }
    Task {
      while !controller.model.ready { try? await Task.sleep(for: .milliseconds(10)) }
      controller.openFile()
    }
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
  @objc func findAndReplace(_ sender: Any?) { activeWindow?.workspace.showReplace() }
  @objc func findNext(_ sender: Any?) { activeWindow?.workspace.findNext() }
  @objc func findPrevious(_ sender: Any?) { activeWindow?.workspace.findPrevious() }
  @objc func useSelectionForFind(_ sender: Any?) { activeWindow?.workspace.useSelectionForFind() }
  @objc func goToLine(_ sender: Any?) { activeWindow?.workspace.showGoToLine() }
  @objc func focusSource(_ sender: Any?) { activeWindow?.workspace.focusSource() }
  @objc func focusExpression(_ sender: Any?) { activeWindow?.workspace.focusExpression() }
  @objc func focusResult(_ sender: Any?) { activeWindow?.workspace.focusResult() }
  @objc func foldAll(_ sender: Any?) { activeWindow?.workspace.foldAll() }
  @objc func unfoldAll(_ sender: Any?) { activeWindow?.workspace.unfoldAll() }
  @objc func rename(_ sender: Any?) { activeWindow?.workspace.showRename() }
  @objc func toggleSidebar(_ sender: Any?) { activeWindow?.workspace.toggleSidebar() }
  @objc func toggleExtraction(_ sender: Any?) { activeWindow?.workspace.toggleExtraction() }
  @objc func toggleWordWrap(_ sender: Any?) { WrapPreference.shared.enabled.toggle() }
  private func publishSettings(_ settings: AppSettings) {
    scheduleMemoryCleanup()
    currentSettings = settings
    settingsReady = true
    mainWindow?.model.settings = settings
    for controller in scratchWindows.values { controller.model.settings = settings }
    if settingsRequested {
      settingsRequested = false
      self.settings(nil)
    }
  }
  @objc func settings(_ sender: Any?) {
    guard settingsReady else {
      settingsRequested = true
      return
    }
    if let settingsWindow, settingsWindow.window?.isVisible == true {
      settingsWindow.window?.makeKeyAndOrderFront(nil)
      return
    }
    let controller = SettingsWindow(settings: currentSettings) { [weak self] settings in
      guard let self else { return false }
      return await self.saveSettings(settings)
    }
    settingsWindow = controller
    controller.showWindow(nil)
    controller.window?.makeKeyAndOrderFront(nil)
  }
  private func saveSettings(_ settings: AppSettings) async -> Bool {
    let previous = currentSettings
    do {
      try hotKey?.update(settings.quickPasteShortcut)
      try await store.saveSettings(settings)
      publishSettings(settings)
      return true
    } catch {
      try? hotKey?.update(previous.quickPasteShortcut)
      let alert = NSAlert()
      alert.messageText = "Could not save settings"
      alert.informativeText = error.localizedDescription
      alert.runModal()
      return false
    }
  }
  func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
    showMain(nil)
    return true
  }
  func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
  func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
    if settingsWindow?.isSaving == true { return .terminateCancel }
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
    file.addItem(item("Rename…", #selector(rename(_:))))
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
    edit.addItem(.separator())
    edit.addItem(item("Find…", #selector(find(_:)), key: "f"))
    edit.addItem(
      item("Find and Replace…", #selector(findAndReplace(_:)), key: "f", modifiers: [.command, .option]))
    edit.addItem(item("Find Next", #selector(findNext(_:)), key: "g"))
    edit.addItem(
      item("Find Previous", #selector(findPrevious(_:)), key: "g", modifiers: [.command, .shift]))
    edit.addItem(item("Use Selection for Find", #selector(useSelectionForFind(_:)), key: "e"))
    edit.addItem(.separator())
    edit.addItem(item("Go to Line…", #selector(goToLine(_:)), key: "l"))
    add(edit, to: bar)
    let json = NSMenu(title: "JSON")
    json.addItem(item("Format", #selector(format(_:)), key: "f", modifiers: [.command, .shift]))
    json.addItem(item("Compact", #selector(compact(_:))))
    json.addItem(item("Run Extraction", #selector(run(_:)), key: "\r"))
    add(json, to: bar)
    let view = NSMenu(title: "View")
    view.addItem(
      item(
        "Show / Hide Sidebar", #selector(toggleSidebar(_:)), key: "s",
        modifiers: [.command, .control]))
    view.addItem(item("Show / Hide Extraction", #selector(toggleExtraction(_:))))
    view.addItem(
      item("Wrap Lines", #selector(toggleWordWrap(_:)), key: "z", modifiers: [.command, .option]))
    view.addItem(.separator())
    view.addItem(item("Focus Source", #selector(focusSource(_:)), key: "1"))
    view.addItem(item("Focus Expression", #selector(focusExpression(_:)), key: "2"))
    view.addItem(item("Focus Result", #selector(focusResult(_:)), key: "3"))
    view.addItem(.separator())
    view.addItem(
      item("Collapse All", #selector(foldAll(_:)), key: "\u{F702}", modifiers: [.command, .option]))
    view.addItem(
      item("Expand All", #selector(unfoldAll(_:)), key: "\u{F703}", modifiers: [.command, .option]))
    add(view, to: bar)
    let window = NSMenu(title: "Window")
    window.addItem(
      item("Minimize", #selector(NSWindow.performMiniaturize(_:)), key: "m", target: nil))
    window.addItem(item("Zoom", #selector(NSWindow.performZoom(_:)), target: nil))
    window.addItem(.separator())
    window.addItem(
      item("Bring All to Front", #selector(NSApplication.arrangeInFront(_:)), target: NSApp))
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

extension ApplicationController: NSMenuItemValidation {
  func validateMenuItem(_ item: NSMenuItem) -> Bool {
    if item.action == #selector(toggleWordWrap(_:)) {
      item.state = WrapPreference.shared.enabled ? .on : .off
    }
    return true
  }
}
