import AppKit

/// NSHostingController doesn't preserve SwiftUI sidebar/spacer placement consistently.
/// Own just the window toolbar here so both pane toggles stay at the window edges.
@MainActor
final class WorkspaceWindowToolbar: NSObject, NSToolbarDelegate {
  private struct Action {
    let id: NSToolbarItem.Identifier
    let title: String
    let symbol: String
    let selector: Selector
    let help: String
    let spacingBefore: NSToolbarItem.Identifier?
    let navigational: Bool

    init(
      _ id: String, _ title: String, _ symbol: String, _ selector: Selector,
      help: String? = nil, spacingBefore: NSToolbarItem.Identifier? = nil,
      navigational: Bool = false
    ) {
      self.id = .init(id)
      self.title = title
      self.symbol = symbol
      self.selector = selector
      self.help = help ?? title
      self.spacingBefore = spacingBefore
      self.navigational = navigational
    }
  }

  let toolbar: NSToolbar
  private weak var target: WorkspaceViewController?
  private let actions: [Action]

  init(target: WorkspaceViewController, temporary: Bool) {
    self.target = target
    toolbar = NSToolbar(identifier: temporary ? "Peel.scratch.fixed" : "Peel.workspace.fixed")
    actions =
      (temporary
        ? []
        : [
          Action(
            "history", "Show / Hide History", "sidebar.left",
            #selector(WorkspaceViewController.toggleSidebar), help: "Show / Hide History (⌃⌘S)",
            navigational: true),
          Action(
            "new", "New JSON", "square.and.pencil", #selector(WorkspaceViewController.newDocument),
            help: "New JSON (⌘N)", navigational: true),
        ]) + [
        Action(
          "open", "Open…", "folder", #selector(WorkspaceViewController.openDocument),
          help: "Open (⌘O)", navigational: true),
        Action(
          "format", "Format JSON", "text.alignleft",
          #selector(WorkspaceViewController.formatDocument), help: "Format JSON (⇧⌘F)",
          spacingBefore: .flexibleSpace),
        Action(
          "compact", "Compact JSON", "text.justify",
          #selector(WorkspaceViewController.compactDocument)),
        Action(
          "run", "Run Extraction", "play.fill", #selector(WorkspaceViewController.runExtraction),
          help: "Run (⌘Return)"),
      ]
      + (temporary
        ? [
          Action(
            "save", "Save to History", "tray.and.arrow.down",
            #selector(WorkspaceViewController.saveScratch), help: "Save to history (⌘S)")
        ] : []) + [
        Action(
          "extraction", "Show / Hide Extraction", "sidebar.right",
          #selector(WorkspaceViewController.toggleExtraction),
          help: "Show / Hide Result and Extraction")
      ]
    super.init()
    toolbar.delegate = self
    toolbar.displayMode = .iconOnly
    toolbar.allowsUserCustomization = false
    toolbar.autosavesConfiguration = false
  }

  func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
    actions.flatMap { ($0.spacingBefore.map { [$0] } ?? []) + [$0.id] }
  }
  func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
    toolbarDefaultItemIdentifiers(toolbar)
  }
  func toolbar(
    _ toolbar: NSToolbar, itemForItemIdentifier identifier: NSToolbarItem.Identifier,
    willBeInsertedIntoToolbar flag: Bool
  ) -> NSToolbarItem? {
    guard let action = actions.first(where: { $0.id == identifier }) else { return nil }
    let item = NSToolbarItem(itemIdentifier: identifier)
    item.label = action.title
    item.paletteLabel = action.title
    item.toolTip = action.help
    item.image = NSImage(systemSymbolName: action.symbol, accessibilityDescription: action.title)
    item.target = target
    item.action = action.selector
    item.visibilityPriority = .high
    item.isNavigational = action.navigational
    return item
  }
}
