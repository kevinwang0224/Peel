import AppKit
import PeelEditor
import SwiftUI

/// Cursor position lives apart from `WorkspacePresentation` so arrow keys only redraw the status bar.
@MainActor
final class CursorState: ObservableObject {
  @Published private(set) var line = 1
  @Published private(set) var column = 1
  func update(line: Int, column: Int) {
    if self.line != line { self.line = line }
    if self.column != column { self.column = column }
  }
}

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
  @Published var replaceVisible = false
  @Published var matchCase = false
  @Published var wholeWord = false
  @Published var useRegex = false
  @Published private(set) var matchCount = 0
  @Published private(set) var matchIndex = 0
  @Published var gotoVisible = false
  @Published var gotoText = ""
  let cursor = CursorState()
  var openURL: ((URL) -> Void)?
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
  func toggleSidebar() {
    columns = columns == .detailOnly ? .all : .detailOnly
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
  private var options: PeelFindOptions {
    var value: PeelFindOptions = []
    if matchCase { value.insert(.matchCase) }
    if wholeWord { value.insert(.wholeWord) }
    if useRegex { value.insert(.regex) }
    return value
  }
  /// Moves to the next/previous match. `inclusive` keeps the match under the caret (incremental search).
  func find(backwards: Bool, inclusive: Bool = false) {
    guard !findText.isEmpty, let editor = focusedEditor else { return }
    if !editor.findText(findText, backwards: backwards, options: options, inclusive: inclusive) {
      NSSound.beep()
    }
    refreshMatches()
  }
  func replace(all: Bool) {
    guard !findText.isEmpty, focusedRole != .result, let editor = focusedEditor else { return }
    if all {
      let count = editor.replaceAllText(findText, withText: replaceText, options: options)
      if count == 0 { NSSound.beep() }
    } else if !editor.replaceText(findText, withText: replaceText, options: options) {
      NSSound.beep()
    }
    refreshMatches()
  }
  func refreshMatches() {
    guard findVisible, !findText.isEmpty, let editor = focusedEditor else {
      matchCount = 0
      matchIndex = 0
      return
    }
    var current = 0
    matchCount = editor.countMatches(forText: findText, options: options, current: &current)
    matchIndex = current
  }
  func showFind(replace: Bool = false) {
    if let selected = focusedEditor?.selectedText(), !selected.isEmpty, !selected.contains("\n") {
      findText = selected
    }
    if replace { replaceVisible = true }
    findVisible = true
    findFocusRequest += 1
    refreshMatches()
  }
  func closeFind() {
    findVisible = false
    matchCount = 0
    matchIndex = 0
    focusedEditor?.focusEditor()
  }
  func useSelectionForFind() {
    guard let selected = focusedEditor?.selectedText(), !selected.isEmpty else { return }
    findText = selected
    refreshMatches()
  }
  func goToLine() {
    guard let line = Int(gotoText.trimmingCharacters(in: .whitespaces)), line > 0 else {
      NSSound.beep()
      return
    }
    gotoVisible = false
    source?.editor?.go(toLine: line)
  }
  func fold(contract: Bool) { source?.editor?.foldAll(contract) }
}

/// Closures connect SwiftUI commands to the existing window and file lifecycle.
@MainActor
final class WorkspaceActions {
  var importFile: (() -> Void)?
  var exportFile: (() -> Void)?
  var saveTemporary: (() -> Void)?
  var presentSettings: (() -> Void)?
  var deleteRecord: ((String) -> Void)?
  var openURL: ((URL) -> Void)?
}
