import PeelCore
import SwiftUI

/// Inspector content: read the result on top, write the expression below. Each editor sits in
/// a rounded card that follows the window's Liquid Glass chrome instead of full-bleed panes
/// divided by flat status bars.
@MainActor
struct ExtractionPanel: View {
  let model: WorkspaceModel
  @ObservedObject var presentation: WorkspacePresentation
  private var mode: Binding<ExtractionMode> {
    Binding(get: { model.extraction.mode }, set: { model.setMode($0) })
  }
  private var failed: Bool { model.result.status == "error" }
  private var idle: Bool { model.result.status == "idle" }
  private var disabled: Bool { !model.ready || model.transitioning }
  private var status: String {
    if model.busy { return "Running…" }
    switch model.result.status {
    case "idle": return "No result yet"
    case "error": return "Extraction failed"
    default: return "Extraction complete"
    }
  }
  private var statusSymbol: String {
    failed ? "exclamationmark.triangle.fill" : idle ? "circle.dashed" : "checkmark.circle.fill"
  }

  var body: some View {
    VStack(spacing: 14) {
      VStack(alignment: .leading, spacing: 8) {
        resultHeader
        EditorCard {
          NativeEditor(model: model, presentation: presentation, role: .result)
            .accessibilityLabel("Extraction result")
        }
        .frame(minHeight: 120, maxHeight: .infinity)
      }
      VStack(alignment: .leading, spacing: 8) {
        expressionHeader
        EditorCard {
          NativeEditor(model: model, presentation: presentation, role: .expression)
            .accessibilityLabel("Extraction expression")
        }
        .frame(minHeight: 72, idealHeight: 120, maxHeight: 200)
      }
    }
    .padding(.horizontal, 12).padding(.top, 8).padding(.bottom, 12)
  }

  private var expressionHeader: some View {
    HStack(spacing: 10) {
      Picker("Mode", selection: mode) {
        Text("JS").tag(ExtractionMode.javascript)
        Text("JSONPath").tag(ExtractionMode.jsonpath)
      }
      .pickerStyle(.segmented).labelsHidden().fixedSize()
      .disabled(disabled)
      Spacer(minLength: 4)
      if (model.summary?.byteSize ?? 0) > 1024 * 1024 {
        Text("Large file: run manually").font(.caption).foregroundStyle(.secondary).lineLimit(1)
      }
      Button { model.run() } label: { Label("Run", systemImage: "play.fill") }
        .glassButton().disabled(disabled)
        .help("Run (⌘Return)")
    }
    .controlSize(.small)
  }

  private var resultHeader: some View {
    HStack(spacing: 6) {
      if model.busy {
        ProgressView().controlSize(.mini)
      } else {
        Image(systemName: statusSymbol)
          .foregroundStyle(failed ? Color.red : idle ? Color.secondary : Color.green)
      }
      Text(status).lineLimit(1)
      Spacer(minLength: 0)
    }
    .font(.caption).foregroundStyle(failed ? Color.red : Color.secondary)
    .padding(.horizontal, 2)
  }
}

/// Rounded, hairline-stroked container for an AppKit editor.
private struct EditorCard<Content: View>: View {
  @ViewBuilder let content: Content
  var body: some View {
    let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
    content
      .clipShape(shape)
      .overlay(shape.strokeBorder(Color.primary.opacity(0.1), lineWidth: 1))
  }
}

extension View {
  /// Liquid Glass button where available, standard bordered button before macOS 26.
  @ViewBuilder fileprivate func glassButton() -> some View {
    if #available(macOS 26.0, *) {
      self.buttonStyle(.glass)
    } else {
      self.buttonStyle(.bordered)
    }
  }
}
