import PeelCore
import SwiftUI

@MainActor
struct WorkspaceView: View {
  let model: WorkspaceModel
  @ObservedObject var presentation: WorkspacePresentation
  let actions: WorkspaceActions

  private var theme: ColorScheme? {
    model.settings.theme == "system" ? nil : model.settings.theme == "dark" ? .dark : .light
  }
  private var title: Binding<String> {
    Binding(
      get: { model.temporary && model.title == "Untitled" ? "Scratch" : model.title },
      set: { model.rename($0) })
  }
  private var subtitle: String {
    guard let summary = model.summary else { return "" }
    return
      "\(summary.rootType) · \(summary.keyCount) keys · \(ByteCountFormatter.string(fromByteCount: Int64(summary.byteSize), countStyle: .file))"
  }
  var body: some View {
    Group {
      if model.temporary {
        WorkspaceDetail(model: model, presentation: presentation)
          .disabled(!model.ready || model.transitioning)
      } else {
        NavigationSplitView(columnVisibility: $presentation.columns) {
          HistorySidebar(model: model, actions: actions)
        } detail: {
          WorkspaceDetail(model: model, presentation: presentation)
            .disabled(!model.ready || model.transitioning)
        }
        .navigationSplitViewStyle(.balanced)
      }
    }
    .toolbar(removing: .sidebarToggle)
    .navigationTitle(title)
    .navigationSubtitle(subtitle)
    .alert("Rename JSON", isPresented: $presentation.renameVisible) {
      TextField("Title", text: $presentation.renameText)
      Button("Cancel", role: .cancel) {}
      Button("Rename") { model.rename(presentation.renameText) }
    }
    .alert("Go to Line", isPresented: $presentation.gotoVisible) {
      TextField("Line number", text: $presentation.gotoText)
      Button("Cancel", role: .cancel) {}
      Button("Go") { presentation.goToLine() }
    }
    .alert(
      "Peel",
      isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })
    ) {
      Button("OK") { model.error = nil }
    } message: {
      Text(model.error ?? "")
    }
    .preferredColorScheme(theme)
  }
}

@MainActor
private struct WorkspaceDetail: View {
  let model: WorkspaceModel
  @ObservedObject var presentation: WorkspacePresentation
  var body: some View {
    VStack(spacing: 0) {
      if presentation.findVisible {
        FindBar(presentation: presentation).transition(.move(edge: .top).combined(with: .opacity))
      }
      NativeEditor(model: model, presentation: presentation, role: .source)
        .accessibilityLabel("JSON source")
      SourceStatus(model: model, cursor: presentation.cursor)
    }
    .animation(.easeOut(duration: 0.15), value: presentation.findVisible)
    .frame(minWidth: 360)
    .inspector(isPresented: $presentation.resultVisible) {
      ExtractionPanel(model: model, presentation: presentation)
        .inspectorColumnWidth(min: 300, ideal: 400, max: 800)
    }
  }
}

@MainActor
private struct SourceStatus: View {
  let model: WorkspaceModel
  @ObservedObject var cursor: CursorState
  private var text: String {
    if let issue = model.issue { return issue.localizedDescription }
    guard let summary = model.summary else { return model.ready ? "JSON" : "Opening…" }
    return
      "\(summary.rootType) · \(summary.keyCount) keys · \(ByteCountFormatter.string(fromByteCount: Int64(summary.byteSize), countStyle: .file))"
  }
  var body: some View {
    HStack {
      Button {
        model.revealError += 1
      } label: {
        Label(
          text, systemImage: model.issue == nil ? "checkmark.circle" : "exclamationmark.triangle"
        )
        .lineLimit(1)
      }
      .buttonStyle(.plain)
      .foregroundStyle(model.issue == nil ? Color.secondary : Color.red)
      .help(model.issue == nil ? "" : "Jump to the error")
      Spacer(minLength: 0)
      Text("Ln \(cursor.line), Col \(cursor.column)")
        .monospacedDigit().foregroundStyle(.secondary)
    }
    .font(.caption).padding(.horizontal, 12).frame(height: 24)
    .background(.bar)
  }
}
