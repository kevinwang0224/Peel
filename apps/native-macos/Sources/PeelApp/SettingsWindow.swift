import AppKit
import PeelCore
import SwiftUI

@MainActor
final class SettingsDraft: ObservableObject {
  @Published var value: AppSettings
  @Published var saving = false
  init(_ settings: AppSettings) { value = settings }
}

/// Settings apply as soon as a control changes. Changes are serialized; a failed write is
/// reported by `apply` and the controls roll back to the last value that was saved.
@MainActor
final class SettingsWindow: NSWindowController, NSWindowDelegate {
  private let draft: SettingsDraft
  private let apply: (AppSettings) async -> Bool
  private var applied: AppSettings
  var isSaving: Bool { draft.saving }
  init(settings: AppSettings, apply: @escaping (AppSettings) async -> Bool) {
    draft = SettingsDraft(settings)
    applied = settings
    self.apply = apply
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 460, height: 300),
      styleMask: [.titled, .closable], backing: .buffered, defer: false)
    window.title = "Settings"
    window.isReleasedWhenClosed = false
    super.init(window: window)
    window.delegate = self
    window.contentViewController = NSHostingController(
      rootView: SettingsView(draft: draft, changed: { [weak self] in self?.commit() }))
    window.center()
  }
  required init?(coder: NSCoder) { fatalError("Not supported") }
  func windowShouldClose(_ sender: NSWindow) -> Bool { !draft.saving }
  private func commit() {
    guard !draft.saving, draft.value != applied else { return }
    draft.saving = true
    let value = draft.value
    Task {
      if await apply(value) {
        applied = value
      } else {
        draft.value = applied
      }
      draft.saving = false
      // A control changed while the write was in flight.
      commit()
    }
  }
}
