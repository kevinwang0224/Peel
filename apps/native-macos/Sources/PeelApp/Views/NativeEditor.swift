import PeelCore
import PeelEditor
import Combine
import SwiftUI

enum EditorRole { case source, expression, result }

/// SwiftUI owns layout and state; the coordinator owns only text-system wiring.
@MainActor
struct NativeEditor: NSViewRepresentable {
  let model: WorkspaceModel
  let presentation: WorkspacePresentation
  let role: EditorRole
  @Environment(\.colorScheme) private var colorScheme

  func makeCoordinator() -> Coordinator {
    Coordinator(model: model, role: role)
  }
  func makeNSView(context: Context) -> PeelEditorView {
    let editor = PeelEditorView(frame: .zero)
    let coordinator = context.coordinator
    coordinator.editor = editor
    switch role {
    case .source: presentation.source = coordinator
    case .expression: presentation.expression = coordinator
    case .result: presentation.result = coordinator
    }
    editor.onFocus = { [weak presentation] in presentation?.focus(role) }
    editor.onRun = { [weak model] in model?.run() }
    editor.onChange = { [weak coordinator] text in coordinator?.edited(text) }
    if role == .source {
      editor.transformPaste = { JSONDocument.pasted($0) }
      editor.onCursor = { [weak presentation] line, column in
        presentation?.cursor.update(line: line, column: column)
      }
      editor.onDropFile = { [weak presentation] path in
        presentation?.openURL?(URL(fileURLWithPath: path))
      }
    }
    if role == .expression {
      editor.completionProvider = { [weak coordinator] text in coordinator?.completions(before: text) }
    }
    editor.recessed = role == .result
    return editor
  }
  func updateNSView(_ editor: PeelEditorView, context: Context) {
    context.coordinator.dark = colorScheme == .dark
    context.coordinator.wraps = role != .expression && presentation.wordWrap
    context.coordinator.synchronize()
  }
  static func dismantleNSView(_ editor: PeelEditorView, coordinator: Coordinator) {
    editor.onChange = nil
    editor.onFocus = nil
    editor.onRun = nil
    editor.transformPaste = nil
    editor.onCursor = nil
    editor.onDropFile = nil
    editor.completionProvider = nil
  }

  @MainActor
  final class Coordinator {
    weak var editor: PeelEditorView?
    var dark = false
    var wraps = false
    private let model: WorkspaceModel
    private let role: EditorRole
    private var document: String?
    private var textRevision = -1
    private var query = ""
    private var mode: ExtractionMode?
    private var output = ""
    private var reveal = -1

    private var parsedDocument: (id: String?, revision: Int, value: Any?)?
    private var wrapObserver: AnyCancellable?
    init(model: WorkspaceModel, role: EditorRole) {
      self.model = model
      self.role = role
      // SwiftUI doesn't re-run updateNSView for this preference, so apply it directly.
      wrapObserver = WrapPreference.shared.$enabled.sink { [weak self] enabled in
        guard let self, self.role != .expression else { return }
        self.wraps = enabled
        self.editor?.wrapsLines = enabled
      }
    }
    /// Suggestions for the access, subscript or name being typed at the end of `text`.
    /// The source is parsed once per revision, and only after the expression looks completable.
    func completions(before text: String) -> PeelCompletionList? {
      let javascript = model.extraction.mode == .javascript
      guard let site = ExpressionCompletion.site(in: text, root: javascript ? "data" : "$")
      else { return nil }
      var document: Any?
      if site.kind != .root {
        if parsedDocument?.id != model.selectedID || parsedDocument?.revision != model.textRevision {
          parsedDocument = (
            model.selectedID, model.textRevision, ExpressionCompletion.parse(model.text)
          )
        }
        document = parsedDocument?.value
      }
      let items = ExpressionCompletion.candidates(for: site, in: document, javascript: javascript)
      return PeelCompletionList(items: items, prefixLength: site.prefix.utf8.count)
    }
    func edited(_ text: String) {
      switch role {
      case .source:
        model.edit(text)
        textRevision = model.textRevision
      case .expression:
        model.setQuery(text)
        query = model.query
      case .result: break
      }
    }
    func synchronize() {
      guard let editor else { return }
      editor.wrapsLines = wraps
      editor.syntaxTheme = model.settings.editorTheme
      let language =
        role == .source
        ? "json"
        : role == .expression
          ? (model.extraction.mode == .javascript ? "javascript" : "plaintext")
          : (model.result.structured ? "json" : "plaintext")
      editor.configureLanguage(
        language, dark: dark, fontSize: model.settings.editorFontSize,
        readOnly: role == .result || !model.ready || model.transitioning || model.selectedID == nil)
      switch role {
      case .source:
        if document != model.selectedID {
          editor.loadDocument(model.text)
          document = model.selectedID
          textRevision = model.textRevision
        } else if textRevision != model.textRevision {
          editor.text = model.text
          textRevision = model.textRevision
        }
        editor.markError(
          atByte: model.issue?.byteOffset ?? -1, message: model.issue?.message,
          reveal: reveal != model.revealError)
        reveal = model.revealError
      case .expression:
        if document != model.selectedID || mode != model.extraction.mode {
          editor.loadDocument(model.query)
          document = model.selectedID
          mode = model.extraction.mode
          query = model.query
        } else if query != model.query {
          editor.text = model.query
          query = model.query
        }
      case .result:
        if output != model.result.text {
          editor.loadDocument(model.result.text)
          output = model.result.text
        }
      }
    }
  }
}
