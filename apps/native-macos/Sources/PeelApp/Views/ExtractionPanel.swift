import PeelCore
import SwiftUI

@MainActor
struct ExtractionPanel: View {
  let model: WorkspaceModel
  let presentation: WorkspacePresentation
  private var mode: Binding<ExtractionMode> {
    Binding(get: { model.extraction.mode }, set: { model.setMode($0) })
  }
  var body: some View {
    VStack(spacing: 0) {
      PaneHeading(
        title: "Result",
        detail: model.busy ? "Running…" : model.result.status == "error" ? "Error" : "Read only")
      NativeEditor(model: model, presentation: presentation, role: .result)
        .accessibilityLabel("Extraction result")
      HStack {
        Text(
          model.result.status == "idle"
            ? "No result yet"
            : model.result.status == "error" ? "Extraction failed" : "Extraction complete")
        Spacer()
      }
      .font(.system(size: 10)).foregroundStyle(.secondary)
      .padding(.horizontal, 12).frame(height: 25)
      .overlay(alignment: .top) { Divider() }
      Divider()
      HStack(spacing: 10) {
        Text("Extraction").font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
        Spacer(minLength: 4)
        Picker("Mode", selection: mode) {
          Text("JavaScript").tag(ExtractionMode.javascript)
          Text("JSONPath").tag(ExtractionMode.jsonpath)
        }
        .pickerStyle(.menu).labelsHidden().fixedSize()
        .disabled(!model.ready || model.transitioning)
      }
      .controlSize(.small).padding(.horizontal, 12).frame(height: 28)
      Divider()
      NativeEditor(model: model, presentation: presentation, role: .expression)
        .accessibilityLabel("Extraction expression").frame(height: 120)
      HStack {
        Text((model.summary?.byteSize ?? 0) > 1024 * 1024 ? "Run manually" : "Runs automatically")
          .font(.system(size: 10)).foregroundStyle(.secondary)
        Spacer()
        Button("Run", systemImage: "play.fill") { model.run() }
          .controlSize(.small).disabled(!model.ready || model.transitioning)
      }
      .padding(.horizontal, 12).frame(height: 32)
    }
  }
}
