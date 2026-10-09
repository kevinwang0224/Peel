import PeelCore
import SwiftUI

@MainActor
struct ExtractionPanel: View {
  let model: WorkspaceModel
  @ObservedObject var presentation: WorkspacePresentation
  private var mode: Binding<ExtractionMode> {
    Binding(get: { model.extraction.mode }, set: { model.setMode($0) })
  }
  private var failed: Bool { model.result.status == "error" }
  private var status: String {
    if model.busy { return "Running…" }
    switch model.result.status {
    case "idle": return "No result yet"
    case "error": return "Extraction failed"
    default: return "Extraction complete"
    }
  }
  var body: some View {
    VSplitView {
      VStack(spacing: 0) {
        NativeEditor(model: model, presentation: presentation, role: .result)
          .accessibilityLabel("Extraction result")
        HStack(spacing: 6) {
          if model.busy { ProgressView().controlSize(.mini) }
          Text(status).lineLimit(1)
          Spacer(minLength: 0)
          Text("Read only")
        }
        .font(.caption)
        .foregroundStyle(failed ? Color.red : Color.secondary)
        .padding(.horizontal, 12).frame(height: 24)
        .background(.bar)
      }
      .frame(minHeight: 120)
      VStack(spacing: 0) {
        HStack(spacing: 10) {
          Picker("Mode", selection: mode) {
            Text("JS").tag(ExtractionMode.javascript)
            Text("JSONPath").tag(ExtractionMode.jsonpath)
          }
          .pickerStyle(.segmented).labelsHidden().fixedSize()
          .disabled(!model.ready || model.transitioning)
          Spacer(minLength: 4)
          if (model.summary?.byteSize ?? 0) > 1024 * 1024 {
            Text("Large file: run manually").font(.caption).foregroundStyle(.secondary).lineLimit(1)
          }
          Button("Run", systemImage: "play.fill") { model.run() }
            .controlSize(.small).disabled(!model.ready || model.transitioning)
            .help("Run (⌘Return)")
        }
        .controlSize(.small).padding(.horizontal, 12).frame(height: 32)
        .background(.bar)
        NativeEditor(model: model, presentation: presentation, role: .expression)
          .accessibilityLabel("Extraction expression")
      }
      .frame(minHeight: 100, idealHeight: 150)
    }
  }
}
