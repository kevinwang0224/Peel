import Carbon
import Foundation
import PeelCore

@MainActor
final class GlobalHotKey {
  private var key: EventHotKeyRef?
  private var handler: EventHandlerRef?
  private var shortcut = ""
  private let action: () -> Void
  init(action: @escaping () -> Void) throws {
    self.action = action
    var type = EventTypeSpec(
      eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
    let context = Unmanaged.passUnretained(self).toOpaque()
    let status = InstallEventHandler(
      GetApplicationEventTarget(),
      { _, _, context in
        guard let context else { return OSStatus(eventNotHandledErr) }
        let hotKey = Unmanaged<GlobalHotKey>.fromOpaque(context).takeUnretainedValue()
        MainActor.assumeIsolated { hotKey.action() }
        return noErr
      }, 1, &type, context, &handler)
    guard status == noErr else {
      throw StorageError(message: "Cannot install global shortcut handler")
    }
  }
  func update(_ value: String) throws {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed == shortcut { return }
    if trimmed.isEmpty {
      if let key { UnregisterEventHotKey(key) }
      key = nil
      shortcut = ""
      return
    }
    let tokens = trimmed.lowercased().split(separator: "+").map(String.init)
    guard let letter = tokens.last else { throw StorageError(message: "Invalid shortcut") }
    let codes: [String: UInt32] = [
      "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9, "b": 11,
      "q": 12, "w": 13, "e": 14, "r": 15, "y": 16, "t": 17, "1": 18, "2": 19, "3": 20, "4": 21,
      "6": 22, "5": 23, "9": 25, "7": 26, "8": 28, "0": 29, "o": 31, "u": 32, "i": 34, "p": 35,
      "l": 37, "j": 38, "k": 40, "n": 45, "m": 46, "space": 49, "f1": 122, "f2": 120, "f3": 99,
      "f4": 118, "f5": 96, "f6": 97, "f7": 98, "f8": 100, "f9": 101, "f10": 109, "f11": 103,
      "f12": 111,
    ]
    guard let code = codes[letter] else {
      throw StorageError(message: "Unsupported shortcut key: \(letter)")
    }
    var modifiers: UInt32 = 0
    for token in tokens.dropLast() {
      switch token {
      case "command", "cmd", "commandorcontrol", "cmdorctrl": modifiers |= UInt32(cmdKey)
      case "control", "ctrl": modifiers |= UInt32(controlKey)
      case "shift": modifiers |= UInt32(shiftKey)
      case "option", "alt": modifiers |= UInt32(optionKey)
      default: throw StorageError(message: "Invalid shortcut modifier: \(token)")
      }
    }
    guard modifiers & UInt32(cmdKey | controlKey | optionKey) != 0 else {
      throw StorageError(message: "Use Command, Control or Option in a global shortcut")
    }
    var candidate: EventHotKeyRef?
    let status = RegisterEventHotKey(
      code, modifiers, EventHotKeyID(signature: 0x5065_656C, id: 1), GetApplicationEventTarget(), 0,
      &candidate)
    guard status == noErr else {
      throw StorageError(message: "Shortcut is already in use or could not be registered")
    }
    if let key { UnregisterEventHotKey(key) }
    key = candidate
    shortcut = trimmed
  }
  deinit {
    if let key { UnregisterEventHotKey(key) }
    if let handler { RemoveEventHandler(handler) }
  }
}
