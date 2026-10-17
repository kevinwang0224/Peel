import AppKit
import PeelCore
import SwiftUI

/// Click to record a global shortcut. Esc cancels, ⌫ clears.
@MainActor
struct ShortcutRecorder: View {
  @Binding var shortcut: String
  @State private var recording = false
  @State private var monitor: Any?
  @State private var hint: String?

  // Keys `GlobalHotKey` can register, keyed by `NSEvent.keyCode`.
  private static let functionKeys: [UInt16: String] = [
    122: "f1", 120: "f2", 99: "f3", 118: "f4", 96: "f5", 97: "f6", 98: "f7", 100: "f8", 101: "f9",
    109: "f10", 103: "f11", 111: "f12", 49: "space",
  ]
  var body: some View {
    HStack(spacing: 8) {
      Button {
        recording ? stop() : start()
      } label: {
        Text(label).monospacedDigit().frame(minWidth: 130)
      }
      .buttonStyle(.bordered)
      .tint(recording ? .accentColor : nil)
      if !shortcut.isEmpty && !recording {
        Button {
          shortcut = ""
        } label: {
          Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
        }
        .buttonStyle(.borderless).help("Clear shortcut").accessibilityLabel("Clear shortcut")
      }
      if let hint {
        Text(hint).font(.caption).foregroundStyle(.secondary)
      }
    }
    .onDisappear { stop() }
  }
  private var label: String {
    if recording { return "Type shortcut…" }
    return shortcut.isEmpty ? "Click to record" : ShortcutFormat.display(shortcut)
  }
  private func start() {
    hint = nil
    recording = true
    monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
      MainActor.assumeIsolated { handle(event) } ? nil : event
    }
  }
  private func stop() {
    recording = false
    if let monitor { NSEvent.removeMonitor(monitor) }
    monitor = nil
  }
  /// Returns true when the event was consumed.
  private func handle(_ event: NSEvent) -> Bool {
    switch event.keyCode {
    case 53:  // Escape
      stop()
      return true
    case 51, 117:  // Delete / forward delete
      shortcut = ""
      stop()
      return true
    default: break
    }
    let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
    let key: String
    if let named = Self.functionKeys[event.keyCode] {
      key = named
    } else if let characters = event.charactersIgnoringModifiers?.lowercased(),
      characters.count == 1, characters.range(of: "^[a-z0-9]$", options: .regularExpression) != nil
    {
      key = characters
    } else {
      NSSound.beep()
      hint = "Unsupported key"
      return true
    }
    guard !flags.isDisjoint(with: [.command, .control, .option]) else {
      NSSound.beep()
      hint = "Include ⌘, ⌃ or ⌥"
      return true
    }
    shortcut = ShortcutFormat.string(
      command: flags.contains(.command), control: flags.contains(.control),
      option: flags.contains(.option), shift: flags.contains(.shift), key: key)
    hint = nil
    stop()
    return true
  }
}
