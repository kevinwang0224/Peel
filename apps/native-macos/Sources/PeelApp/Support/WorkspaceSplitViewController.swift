import AppKit
import Combine
import SwiftUI

/// An `NSSplitView` that draws its divider as a single-pixel hairline (0.5pt on Retina), matching
/// the history sidebar's trailing edge, instead of the system's heavier divider.
final class HairlineSplitView: NSSplitView {
  override var dividerColor: NSColor { .clear }
  override func drawDivider(in rect: NSRect) {
    let scale = window?.backingScaleFactor ?? 2
    // Scale the system separator's own alpha (as SwiftUI's `.opacity` does on the sidebar) rather than
    // replacing it: `withAlphaComponent(0.6)` turned the 10% black separator into a dark 60% line.
    guard let context = NSGraphicsContext.current?.cgContext else { return }
    context.saveGState()
    context.setAlpha(0.6)
    NSColor.separatorColor.setFill()
    NSRect(x: rect.minX, y: rect.minY, width: 1 / scale, height: rect.height).fill()
    context.restoreGState()
  }
}

/// Window content: the SwiftUI workspace (history sidebar + editor) beside an AppKit inspector
/// holding the extraction panel.
///
/// The panel used to be a SwiftUI `.inspector`. Its column width was owned by SwiftUI while the
/// surrounding `NSSplitView` constraints were owned by AppKit, so dragging the divider or shrinking
/// the window could leave the two disagreeing: every pass changed the hosting view's safe area,
/// which requested another constraint pass until AppKit threw. Here AppKit alone sizes both panes.
@MainActor
final class WorkspaceSplitViewController: NSSplitViewController {
  let workspace: WorkspaceViewController
  private let contentItem: NSSplitViewItem
  private let inspectorItem: NSSplitViewItem
  private var visibility: AnyCancellable?
  private var positioned = false
  private var animatingInspector = false
  private static let inspectorIdeal: CGFloat = 480
  private static let widthKey = "Peel.extraction.width"
  /// Width to open the panel at: the last width the user dragged it to, else the default.
  private var preferredWidth: CGFloat {
    let saved = UserDefaults.standard.double(forKey: Self.widthKey)
    guard saved > 0 else { return Self.inspectorIdeal }
    return min(max(CGFloat(saved), inspectorItem.minimumThickness), inspectorItem.maximumThickness)
  }
  /// Remembers a user-dragged width. Ignores collapse/expand animation frames, which pass
  /// through widths the user never chose, and scratch windows, which always start closed.
  private func persistWidth() {
    guard positioned, !workspace.model.temporary, !inspectorItem.isCollapsed else { return }
    let width = inspectorItem.viewController.view.frame.width
    guard width >= inspectorItem.minimumThickness, width <= inspectorItem.maximumThickness else { return }
    UserDefaults.standard.set(Double(width), forKey: Self.widthKey)
  }

  init(workspace: WorkspaceViewController) {
    self.workspace = workspace
    let presentation = workspace.presentation
    let panel = NSHostingController(
      rootView: ExtractionPanel(model: workspace.model, presentation: presentation))
    panel.sizingOptions = []
    contentItem = NSSplitViewItem(viewController: workspace)
    // A true inspector item inserts its own toolbar tracking separator and paints a
    // separate titlebar section. A regular split keeps the trailing buttons packed
    // and the titlebar one colour, matching the scratch window.
    inspectorItem = NSSplitViewItem(viewController: panel)
    super.init(nibName: nil, bundle: nil)
    splitView = HairlineSplitView()
    splitView.isVertical = true
    splitView.dividerStyle = .thin

    // Shrinking the window takes width from the editor first, then the panel down to its minimum.
    contentItem.minimumThickness = workspace.model.temporary ? 360 : 600
    contentItem.holdingPriority = .defaultLow
    // 600 + 300 matches the window's 900pt minimum content width; a larger minimum here
    // would fight `contentMinSize` once the panel is open.
    inspectorItem.minimumThickness = 300
    inspectorItem.maximumThickness = 800
    inspectorItem.holdingPriority = NSLayoutConstraint.Priority(NSLayoutConstraint.Priority.defaultLow.rawValue + 10)
    inspectorItem.canCollapse = true
    inspectorItem.isCollapsed = !presentation.resultVisible
    addSplitViewItem(contentItem)
    addSplitViewItem(inspectorItem)

    visibility = presentation.$resultVisible.removeDuplicates().sink { [weak self] visible in
      self?.setInspector(visible: visible)
    }
  }
  @MainActor required dynamic init?(coder: NSCoder) { fatalError("Not supported") }

  override func viewDidLoad() {
    super.viewDidLoad()
    // Width is persisted manually (`persistWidth`): NSSplitView autosave also stores the
    // collapsed state and stale frames, which previously restored a narrow or hidden panel.
    splitView.autosaveName = nil
  }
  override func viewDidAppear() {
    super.viewDidAppear()
    positionInspectorOnce()
  }
  /// Opens the panel at its ideal width the first time it has a real size. `positioned` is only
  /// set once the position was applied, so an early call with zero bounds can't consume it.
  private func positionInspectorOnce() {
    // Wait until the window is on screen: before that the split view is laid out at the window's
    // minimum size, and positioning against it clamps the panel to its minimum thickness.
    guard !positioned, !workspace.model.temporary, !inspectorItem.isCollapsed,
      splitView.window?.isVisible == true, splitView.bounds.width > 0
    else { return }
    positioned = true
    let position = max(
      contentItem.minimumThickness,
      splitView.bounds.width - preferredWidth - splitView.dividerThickness)
    splitView.setPosition(position, ofDividerAt: 0)
  }

  private func setInspector(visible: Bool) {
    guard inspectorItem.isCollapsed == visible else { return }
    guard isViewLoaded, view.window != nil else {
      inspectorItem.isCollapsed = !visible
      return
    }
    animatingInspector = true
    NSAnimationContext.runAnimationGroup { context in
      context.duration = 0.25
      context.allowsImplicitAnimation = true
      inspectorItem.animator().isCollapsed = !visible
    } completionHandler: { [weak self] in
      self?.animatingInspector = false
    }
  }

  override func splitViewDidResizeSubviews(_ notification: Notification) {
    super.splitViewDidResizeSubviews(notification)
    positionInspectorOnce()
    if !animatingInspector { persistWidth() }
    // Keep the model in step when the panel is collapsed by AppKit itself (e.g. dragged shut).
    let visible = !inspectorItem.isCollapsed
    if workspace.presentation.resultVisible != visible {
      workspace.presentation.resultVisible = visible
    }
  }
}
