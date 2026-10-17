import Foundation

/// Text form shared by the recorder and `GlobalHotKey`, e.g. `Shift+Command+J`.
public enum ShortcutFormat {
  public static func string(
    command: Bool, control: Bool, option: Bool, shift: Bool, key: String
  ) -> String {
    var parts: [String] = []
    if control { parts.append("Control") }
    if option { parts.append("Option") }
    if shift { parts.append("Shift") }
    if command { parts.append("Command") }
    parts.append(keyTitle(key))
    return parts.joined(separator: "+")
  }

  /// Mac-style symbols in the system order: ⌃ ⌥ ⇧ ⌘.
  public static func display(_ shortcut: String) -> String {
    let tokens = shortcut.lowercased().split(separator: "+").map(String.init)
    guard let key = tokens.last else { return "" }
    let modifiers = Set(tokens.dropLast())
    var result = ""
    if !modifiers.isDisjoint(with: ["control", "ctrl"]) { result += "⌃" }
    if !modifiers.isDisjoint(with: ["option", "alt"]) { result += "⌥" }
    if modifiers.contains("shift") { result += "⇧" }
    if !modifiers.isDisjoint(with: ["command", "cmd", "commandorcontrol", "cmdorctrl"]) {
      result += "⌘"
    }
    return result + keyTitle(key)
  }

  private static func keyTitle(_ key: String) -> String {
    key.lowercased() == "space" ? "Space" : key.uppercased()
  }
}
