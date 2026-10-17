import XCTest

@testable import PeelCore

final class ShortcutFormatTests: XCTestCase {
  func testStringUsesTokensAcceptedByTheGlobalShortcutParser() {
    XCTAssertEqual(
      ShortcutFormat.string(command: true, control: false, option: false, shift: true, key: "j"),
      "Shift+Command+J")
    XCTAssertEqual(
      ShortcutFormat.string(command: false, control: true, option: true, shift: false, key: "space"),
      "Control+Option+Space")
  }
  func testDisplayUsesMacModifierOrderAndSymbols() {
    XCTAssertEqual(ShortcutFormat.display("Command+Shift+J"), "⇧⌘J")
    XCTAssertEqual(ShortcutFormat.display("ctrl+alt+f5"), "⌃⌥F5")
    XCTAssertEqual(ShortcutFormat.display("cmdorctrl+space"), "⌘Space")
    XCTAssertEqual(ShortcutFormat.display(""), "")
  }
}
