import AppKit

@MainActor
final class WorkspaceToolbar: NSObject, NSToolbarDelegate {
  struct Action {
    let id: NSToolbarItem.Identifier
    let title: String
    let symbol: String
    let selector: Selector
    let shortcut: String?
    let spacingBefore: NSToolbarItem.Identifier?
    init(
      _ id: String, _ title: String, _ symbol: String, _ selector: Selector,
      shortcut: String? = nil, spacingBefore: NSToolbarItem.Identifier? = nil
    ) {
      self.id = .init(id)
      self.title = title
      self.symbol = symbol
      self.selector = selector
      self.shortcut = shortcut
      self.spacingBefore = spacingBefore
    }
  }
  let toolbar: NSToolbar
  private weak var target: NSObject?
  private let actions: [Action]
  private var enabled = false

  init(target: NSObject, identifier: NSToolbar.Identifier, actions: [Action]) {
    toolbar = NSToolbar(identifier: identifier)
    self.target = target
    self.actions = actions
    super.init()
    toolbar.delegate = self
    toolbar.displayMode = .iconOnly
    toolbar.allowsUserCustomization = true
    toolbar.autosavesConfiguration = true
  }

  func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
    actions.map(\.id) + [.flexibleSpace, .space]
  }
  func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
    actions.flatMap { action in
      (action.spacingBefore.map { [$0] } ?? []) + [action.id]
    }
  }
  func toolbar(
    _ toolbar: NSToolbar, itemForItemIdentifier identifier: NSToolbarItem.Identifier,
    willBeInsertedIntoToolbar flag: Bool
  ) -> NSToolbarItem? {
    guard let action = actions.first(where: { $0.id == identifier }) else { return nil }
    let item = NSToolbarItem(itemIdentifier: identifier)
    item.label = action.title
    item.paletteLabel = action.title
    item.toolTip = action.title + (action.shortcut.map { " (\($0))" } ?? "")
    item.image = NSImage(systemSymbolName: action.symbol, accessibilityDescription: action.title)
    item.target = target
    item.action = action.selector
    item.autovalidates = false
    item.isEnabled = enabled
    return item
  }
  func setEnabled(_ enabled: Bool) {
    self.enabled = enabled
    for item in toolbar.items { item.isEnabled = enabled }
  }
}
