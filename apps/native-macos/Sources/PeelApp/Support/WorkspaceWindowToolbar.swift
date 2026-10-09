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
          "wrap", "Wrap Lines", "arrow.turn.down.right",
          #selector(WorkspaceViewController.toggleWordWrap), help: "Wrap Lines (⌥⌘Z)"),
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
    // Keep sidebar items inside the sidebar column and the result toggle over the inspector.
    if let open = identifiers.firstIndex(of: .init("open")) {
      identifiers.insert(Self.spacer, at: open + 1)
    }
    if let last = identifiers.firstIndex(of: .init("extraction")) {
      identifiers.insert(.inspectorTrackingSeparator, at: last)
    }
    return identifiers
  }
  /// SwiftUI's split view isn't an `NSSplitViewController`, so system tracking separators
  /// can't follow the sidebar. A navigational spacer sized to the sidebar width pushes the
  /// title to the detail column's leading edge instead.
  func bindSplitView(in root: NSView) {
    guard !temporary, split == nil, let found = Self.splitView(in: root) else { return }
    split = found
    found.postsFrameChangedNotifications = true
    NotificationCenter.default.addObserver(
      self, selector: #selector(sidebarResized), name: NSSplitView.didResizeSubviewsNotification,
      object: found)
    sidebarResized()
  }
  @objc private func sidebarResized() {
    updateSpacer()
  }
  private func updateSpacer() {
    guard let split, let first = split.arrangedSubviews.first,
      let view = spacerView, view.window != nil
    else { return }
    let edge = first.isHidden ? 0 : first.frame.width
    // The spacer's leading edge depends only on the fixed items before it, never on its own
    // width, so it is stable while the sidebar is dragged. Measure once and reuse it.
    if leadingInset == nil {
      let minX = view.convert(view.bounds, to: nil).minX
      guard minX > 0 else { return }
      leadingInset = minX
    }
    view.currentWidth = max(0, edge - (leadingInset ?? 0) - 8)
  }
  private var spacerView: SpacerView?
  private var leadingInset: CGFloat?
  private final class SpacerView: NSView {
    var currentWidth: CGFloat = 1 {
      didSet { widthConstraint.constant = currentWidth }
    }
    private(set) var widthConstraint: NSLayoutConstraint!
    override init(frame: NSRect) {
      super.init(frame: frame)
      translatesAutoresizingMaskIntoConstraints = false
      widthConstraint = widthAnchor.constraint(equalToConstant: 1)
      widthConstraint.isActive = true
      heightAnchor.constraint(equalToConstant: 24).isActive = true
    }
    required init?(coder: NSCoder) { fatalError() }
  }
  private var split: NSSplitView?
  private static let spacer = NSToolbarItem.Identifier("Peel.sidebarSpacer")
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
    if identifier == Self.spacer {
      let item = NSToolbarItem(itemIdentifier: identifier)
      let view = SpacerView(frame: .zero)
      spacerView = view
      item.view = view
      item.isNavigational = true
      item.visibilityPriority = .high
      return item
    }
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
    if identifier.rawValue == "wrap" {
      wrapItem = item
      applyWrapAppearance(WrapPreference.shared.enabled)
    }
    if #available(macOS 26.0, *), identifier.rawValue == "run" {
      item.style = .prominent
    }
    return item
  }
}
