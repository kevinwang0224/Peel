import AppKit
import PeelCore

@MainActor
final class SettingsWindow: NSWindowController, NSWindowDelegate {
  private let appearance = NSPopUpButton()
  private let font = NSPopUpButton()
  private let shortcut = NSTextField()
  private let saveButton = NSButton()
  private let cancelButton = NSButton()
  private var saving = false
  var isSaving: Bool { saving }
  private let original: AppSettings
  private let apply: (AppSettings) async -> Bool

  init(settings: AppSettings, apply: @escaping (AppSettings) async -> Bool) {
    original = settings
    self.apply = apply
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 480, height: 340),
      styleMask: [.titled, .closable], backing: .buffered, defer: false)
    window.title = "Peel Settings"
    window.isReleasedWhenClosed = false
    super.init(window: window)
    window.delegate = self
    window.appearance =
      settings.theme == "system"
      ? nil : NSAppearance(named: settings.theme == "dark" ? .darkAqua : .aqua)
    buildContent()
    window.center()
  }
  required init?(coder: NSCoder) { fatalError("Not supported") }

  private func buildContent() {
    guard let content = window?.contentView else { return }
    appearance.addItems(withTitles: ["System", "Light", "Dark"])
    appearance.selectItem(at: ["system", "light", "dark"].firstIndex(of: original.theme) ?? 0)
    font.addItems(withTitles: (10...30).map { "\($0) pt" })
    font.selectItem(at: original.editorFontSize - 10)
    let heading = WorkspaceChrome.label("Editor", weight: .semibold)
    let grid = NSGridView(views: [
      [WorkspaceChrome.label("Appearance", weight: .regular), appearance],
      [WorkspaceChrome.label("Font size", weight: .regular), font],
    ])
    grid.rowSpacing = 14
    grid.columnSpacing = 22
    grid.column(at: 0).xPlacement = .trailing
    grid.column(at: 1).xPlacement = .leading
    let divider = NSBox()
    divider.boxType = .separator
    let shortcutTitle = WorkspaceChrome.label("Quick Paste", weight: .semibold)
    let explanation = WorkspaceChrome.label(
      "Open a scratch window from the clipboard while the main window is closed.", weight: .regular)
    explanation.textColor = .secondaryLabelColor
    explanation.font = .systemFont(ofSize: 11)
    explanation.maximumNumberOfLines = 2
    shortcut.stringValue = original.quickPasteShortcut
    shortcut.bezelStyle = .roundedBezel
    shortcut.placeholderString = "Command+Shift+J"
    let hint = WorkspaceChrome.label(
      "Leave empty to disable the global shortcut.", weight: .regular)
    hint.textColor = .secondaryLabelColor
    hint.font = .systemFont(ofSize: 11)
    let cancel = cancelButton
    cancel.title = "Cancel"
    cancel.target = self
    cancel.action = #selector(SettingsWindow.cancel)
    cancel.bezelStyle = .rounded
    cancel.keyEquivalent = "\u{1b}"
    let save = saveButton
    save.title = "Save"
    save.target = self
    save.action = #selector(SettingsWindow.save)
    save.bezelStyle = .rounded
    save.keyEquivalent = "\r"
    let actions = NSStackView(views: [cancel, save])
    actions.spacing = 10
    for item in [heading, grid, divider, shortcutTitle, explanation, shortcut, hint, actions] {
      content.addSubview(item)
      item.translatesAutoresizingMaskIntoConstraints = false
    }
    NSLayoutConstraint.activate([
      heading.topAnchor.constraint(equalTo: content.topAnchor, constant: 24),
      heading.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 28),
      grid.topAnchor.constraint(equalTo: heading.bottomAnchor, constant: 16),
      grid.leadingAnchor.constraint(equalTo: heading.leadingAnchor),
      divider.topAnchor.constraint(equalTo: grid.bottomAnchor, constant: 22),
      divider.leadingAnchor.constraint(equalTo: heading.leadingAnchor),
      divider.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -28),
      shortcutTitle.topAnchor.constraint(equalTo: divider.bottomAnchor, constant: 20),
      shortcutTitle.leadingAnchor.constraint(equalTo: heading.leadingAnchor),
      explanation.topAnchor.constraint(equalTo: shortcutTitle.bottomAnchor, constant: 6),
      explanation.leadingAnchor.constraint(equalTo: heading.leadingAnchor),
      explanation.trailingAnchor.constraint(equalTo: divider.trailingAnchor),
      shortcut.topAnchor.constraint(equalTo: explanation.bottomAnchor, constant: 12),
      shortcut.leadingAnchor.constraint(equalTo: heading.leadingAnchor),
      shortcut.trailingAnchor.constraint(equalTo: divider.trailingAnchor),
      hint.topAnchor.constraint(equalTo: shortcut.bottomAnchor, constant: 6),
      hint.leadingAnchor.constraint(equalTo: heading.leadingAnchor),
      actions.trailingAnchor.constraint(equalTo: divider.trailingAnchor),
      actions.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -20),
    ])
  }
  func windowShouldClose(_ sender: NSWindow) -> Bool { !saving }
  @objc private func cancel() { if !saving { close() } }
  @objc private func save() {
    guard !saving else { return }
    var settings = original
    settings.theme = ["system", "light", "dark"][appearance.indexOfSelectedItem]
    settings.editorFontSize = font.indexOfSelectedItem + 10
    settings.quickPasteShortcut = shortcut.stringValue
    saving = true
    for control in [appearance, font, shortcut, saveButton, cancelButton] as [NSControl] {
      control.isEnabled = false
    }
    Task {
      let succeeded = await apply(settings)
      saving = false
      for control in [appearance, font, shortcut, saveButton, cancelButton] as [NSControl] {
        control.isEnabled = true
      }
      if succeeded { close() }
    }
  }
}
