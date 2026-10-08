import PeelCore
import PeelEditor
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
    if role == .source { editor.transformPaste = { JSONDocument.pasted($0) } }
    return editor
  }
  func updateNSView(_ editor: PeelEditorView, context: Context) {
    context.coordinator.dark = colorScheme == .dark
    context.coordinator.synchronize()
  }
  static func dismantleNSView(_ editor: PeelEditorView, coordinator: Coordinator) {
    editor.onChange = nil
    editor.onFocus = nil
    editor.onRun = nil
    editor.transformPaste = nil
  }

  @MainActor
  final class Coordinator {
    weak var editor: PeelEditorView?
    var dark = false
    private let model: WorkspaceModel
    private let role: EditorRole
    private var document: String?
    private var textRevision = -1
    private var query = ""
    private var mode: ExtractionMode?
    private var output = ""
    private var reveal = -1

    init(model: WorkspaceModel, role: EditorRole) {
      self.model = model
      self.role = role
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
        editor.markError(atByte: model.issue?.byteOffset ?? -1, reveal: reveal != model.revealError)
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
