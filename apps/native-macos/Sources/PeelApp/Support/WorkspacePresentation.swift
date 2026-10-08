import AppKit
import PeelEditor
import SwiftUI

/// Window-local UI state. Editor references are weak so hidden panes release their buffers.
@MainActor
final class WorkspacePresentation: ObservableObject {
  @Published var resultVisible = true
  @Published var findVisible = false
  @Published var findFocusRequest = 0
  @Published var renameVisible = false
  @Published var renameText = ""
  @Published var findText = ""
  @Published var replaceText = ""
  @Published var columns: NavigationSplitViewVisibility = .all
  @Published private(set) var focusedRole: EditorRole = .source
  weak var source: NativeEditor.Coordinator?
  weak var expression: NativeEditor.Coordinator?
  weak var result: NativeEditor.Coordinator?

  var focusedEditor: PeelEditorView? {
    switch focusedRole {
    case .source: source?.editor
    case .expression: expression?.editor ?? source?.editor
    case .result: result?.editor ?? source?.editor
    }
  }
  func focus(_ role: EditorRole) {
    if focusedRole != role { focusedRole = role }
  }
  func toggleExtraction() {
    if resultVisible, focusedRole != .source {
      focus(.source)
      source?.editor?.focusEditor()
    }
    resultVisible.toggle()
  }
  func synchronizeEditors() {
    source?.synchronize()
    expression?.synchronize()
    result?.synchronize()
  }
  func find(backwards: Bool) {
    guard !findText.isEmpty else { return }
    _ = focusedEditor?.findText(findText, backwards: backwards)
  }
  func replace(all: Bool) {
    guard !findText.isEmpty, focusedRole != .result else { return }
    _ = focusedEditor?.replaceText(findText, withText: replaceText, all: all)
  }
}

/// Closures connect SwiftUI commands to the existing window and file lifecycle.
@MainActor
final class WorkspaceActions {
  var importFile: (() -> Void)?
  var exportFile: (() -> Void)?
  var saveTemporary: (() -> Void)?
  var presentSettings: (() -> Void)?
  var deleteRecord: ((String) -> Void)?
}
