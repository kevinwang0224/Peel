import AppKit
import PeelCore
import SwiftUI

@MainActor
final class SettingsDraft: ObservableObject {
  @Published var value: AppSettings
  @Published var saving = false
  init(_ settings: AppSettings) { value = settings }
}

@MainActor
final class SettingsWindow: NSWindowController, NSWindowDelegate {
  private let draft: SettingsDraft
  private let apply: (AppSettings) async -> Bool
  var isSaving: Bool { draft.saving }
  init(settings: AppSettings, apply: @escaping (AppSettings) async -> Bool) {
    draft = SettingsDraft(settings)
    self.apply = apply
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 480, height: 355),
      styleMask: [.titled, .closable], backing: .buffered, defer: false)
    window.title = "Peel Settings"
    window.isReleasedWhenClosed = false
    super.init(window: window)
    window.delegate = self
    window.contentViewController = NSHostingController(
      rootView: SettingsView(
        draft: draft,
        save: { [weak self] in self?.save() }, cancel: { [weak self] in self?.cancel() }))
    window.center()
  }
  required init?(coder: NSCoder) { fatalError("Not supported") }
  func windowShouldClose(_ sender: NSWindow) -> Bool { !draft.saving }
  private func cancel() { if !draft.saving { close() } }
  private func save() {
    guard !draft.saving else { return }
    draft.saving = true
    let value = draft.value
    Task {
      let succeeded = await apply(value)
      draft.saving = false
      if succeeded { close() }
    }
  }
}
