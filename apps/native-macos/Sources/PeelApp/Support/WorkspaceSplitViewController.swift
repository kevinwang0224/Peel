import AppKit
import Combine
import SwiftUI

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
  private static let inspectorIdeal: CGFloat = 400

  init(workspace: WorkspaceViewController) {
    self.workspace = workspace
    let presentation = workspace.presentation
    let panel = NSHostingController(
      rootView: ExtractionPanel(model: workspace.model, presentation: presentation))
    panel.sizingOptions = []
    contentItem = NSSplitViewItem(viewController: workspace)
    inspectorItem = NSSplitViewItem(inspectorWithViewController: panel)
    super.init(nibName: nil, bundle: nil)

    // Shrinking the window takes width from the editor first, then the panel down to its minimum.
    contentItem.minimumThickness = workspace.model.temporary ? 360 : 600
    contentItem.holdingPriority = .defaultLow
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
    splitView.autosaveName = workspace.model.temporary ? "Peel.scratch.split" : "Peel.workspace.split"
  }
  override func viewDidAppear() {
    super.viewDidAppear()
    guard !positioned else { return }
    positioned = true
    // First launch has no autosaved frames; open the panel at its ideal width.
    let key = "NSSplitView Subview Frames \(splitView.autosaveName ?? "")"
    guard UserDefaults.standard.object(forKey: key) == nil, !inspectorItem.isCollapsed else { return }
    splitView.setPosition(splitView.bounds.width - Self.inspectorIdeal - splitView.dividerThickness, ofDividerAt: 0)
  }

  /// The native inspector divider, for the toolbar's tracking separator.
  var inspectorSplitView: NSSplitView { splitView }

  private func setInspector(visible: Bool) {
    guard inspectorItem.isCollapsed == visible else { return }
    guard isViewLoaded, view.window != nil else {
      inspectorItem.isCollapsed = !visible
      return
    }
    NSAnimationContext.runAnimationGroup { context in
      context.duration = 0.25
      context.allowsImplicitAnimation = true
      inspectorItem.animator().isCollapsed = !visible
    }
  }

  override func splitViewDidResizeSubviews(_ notification: Notification) {
    super.splitViewDidResizeSubviews(notification)
    // Keep the model in step when the panel is collapsed by AppKit itself (e.g. dragged shut).
    let visible = !inspectorItem.isCollapsed
    if workspace.presentation.resultVisible != visible {
      workspace.presentation.resultVisible = visible
    }
  }
}
