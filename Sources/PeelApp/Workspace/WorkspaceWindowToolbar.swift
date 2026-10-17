import AppKit
import Combine

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
    self.temporary = temporary
    toolbar = NSToolbar(identifier: temporary ? "Peel.scratch.fixed" : "Peel.workspace.fixed")
    actions =
      (temporary
        ? []
        : [
          Action(
            "history", "Show / Hide History", "sidebar.left",
            #selector(WorkspaceViewController.toggleSidebar), help: "Show / Hide History (⌃⌘S)",
            navigational: false),
          Action(
            "new", "New JSON", "square.and.pencil", #selector(WorkspaceViewController.newDocument),
            help: "New JSON (⌘N)", navigational: false),
        ]) + [
        Action(
          "open", "Open…", "folder", #selector(WorkspaceViewController.openDocument),
          help: "Open (⌘O)", navigational: false),
        Action(
          "format", "Format JSON", "text.alignleft",
          #selector(WorkspaceViewController.formatDocument), help: "Format JSON (⇧⌘F)",
          spacingBefore: .flexibleSpace),
        Action(
          "compact", "Compact JSON", "text.justify",
          #selector(WorkspaceViewController.compactDocument)),
        Action(
          "wrap", "Wrap Lines", "arrow.turn.down.right",
          #selector(WorkspaceViewController.toggleWordWrap), help: "Wrap Lines (⌥⌘Z)"),
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
    wrapObserver = WrapPreference.shared.$enabled.sink { [weak self] enabled in
      self?.applyWrapAppearance(enabled)
    }
  }

  private var wrapObserver: AnyCancellable?
  private weak var wrapItem: NSToolbarItem?
  /// Toolbar items have no "on" state; tint the glyph with the accent colour while wrapping.
  private func applyWrapAppearance(_ enabled: Bool) {
    guard let item = wrapItem else { return }
    let base = NSImage(
      systemSymbolName: "arrow.turn.down.right", accessibilityDescription: "Wrap Lines")
    item.image =
      enabled
      ? base?.withSymbolConfiguration(.init(paletteColors: [.controlAccentColor])) : base
    item.toolTip = enabled ? "Don't Wrap Lines (⌥⌘Z)" : "Wrap Lines (⌥⌘Z)"
  }

  private let temporary: Bool
  func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
    var identifiers = actions.flatMap { ($0.spacingBefore.map { [$0] } ?? []) + [$0.id] }
    guard !temporary else { return identifiers }
    // Keep the sidebar trio inside the sidebar column, pinned to the sidebar's divider.
    if let open = identifiers.firstIndex(of: .init("open")) {
      identifiers.insert(.sidebarTrackingSeparator, at: open + 1)
    }
    return identifiers
  }
  func bindSplitView(in root: NSView) {
    guard !temporary, split == nil, let found = Self.splitView(in: root) else { return }
    split = found
    for item in toolbar.items {
      guard let separator = item as? NSTrackingSeparatorToolbarItem,
        item.itemIdentifier == .sidebarTrackingSeparator
      else { continue }
      separator.splitView = found
      separator.dividerIndex = 0
    }
  }
  private var split: NSSplitView?
  private static func splitView(in view: NSView) -> NSSplitView? {
    if let split = view as? NSSplitView, split.arrangedSubviews.count >= 2 { return split }
    for subview in view.subviews { if let found = splitView(in: subview) { return found } }
    return nil
  }
  func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
    toolbarDefaultItemIdentifiers(toolbar)
  }
  func toolbar(
    _ toolbar: NSToolbar, itemForItemIdentifier identifier: NSToolbarItem.Identifier,
    willBeInsertedIntoToolbar flag: Bool
  ) -> NSToolbarItem? {
    if identifier == .sidebarTrackingSeparator {
      return NSTrackingSeparatorToolbarItem(itemIdentifier: identifier)
    }
    guard let action = actions.first(where: { $0.id == identifier }) else { return nil }
    let item = NSToolbarItem(itemIdentifier: identifier)
    item.label = action.title
    item.paletteLabel = action.title
    item.toolTip = action.help
    item.image = NSImage(systemSymbolName: action.symbol, accessibilityDescription: action.title)
    item.target = target
    item.action = action.selector
    // The sidebar trio must never be the first thing pushed into the overflow menu.
    item.visibilityPriority = ["history", "new", "open"].contains(identifier.rawValue) ? .user : .high
    item.isNavigational = action.navigational
    if identifier.rawValue == "wrap" {
      wrapItem = item
      applyWrapAppearance(WrapPreference.shared.enabled)
    }
    return item
  }
}
