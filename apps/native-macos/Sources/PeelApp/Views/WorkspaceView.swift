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
  var body: some View {
    Group {
      if model.temporary {
        WorkspaceDetail(model: model, presentation: presentation)
      } else {
        NavigationSplitView(columnVisibility: $presentation.columns) {
          HistorySidebar(model: model, actions: actions)
        } detail: {
          WorkspaceDetail(model: model, presentation: presentation)
        }
        .navigationSplitViewStyle(.balanced)
      }
    }
    .toolbar(removing: .sidebarToggle)
    .navigationTitle(title)
    .disabled(!model.ready || model.transitioning)
    .alert("Rename JSON", isPresented: $presentation.renameVisible) {
      TextField("Title", text: $presentation.renameText)
      Button("Cancel", role: .cancel) {}
      Button("Rename") { model.rename(presentation.renameText) }
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
      if presentation.findVisible { FindBar(presentation: presentation) }
      HSplitView {
        VStack(spacing: 0) {
          PaneHeading(
            title: "Source",
            detail: model.temporary
              ? (model.dirty ? "Unsaved scratch" : "Scratch") : model.dirty ? "Saving…" : "Saved"
          )
          NativeEditor(model: model, presentation: presentation, role: .source)
            .accessibilityLabel("JSON source")
          SourceStatus(model: model)
        }
        .frame(minWidth: 320, idealWidth: 580, maxWidth: .infinity)
        if presentation.resultVisible {
          ExtractionPanel(model: model, presentation: presentation)
            .frame(minWidth: 280, idealWidth: 360, maxWidth: .infinity)
        }
      }
    }
  }
}

struct PaneHeading: View {
  let title: String
  let detail: String
  var body: some View {
    HStack {
      Text(title).font(.system(size: 11, weight: .medium))
      Spacer()
      Text(detail).font(.system(size: 10)).foregroundStyle(.secondary)
    }
    .foregroundStyle(.secondary).padding(.horizontal, 12).frame(height: 28)
    .overlay(alignment: .bottom) { Divider() }
  }
}

@MainActor
private struct SourceStatus: View {
  let model: WorkspaceModel
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
      Spacer(minLength: 0)
    }
    .font(.system(size: 10)).padding(.horizontal, 12).frame(height: 25)
    .overlay(alignment: .top) { Divider() }
  }
}
