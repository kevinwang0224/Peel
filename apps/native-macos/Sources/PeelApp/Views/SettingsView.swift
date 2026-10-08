import PeelCore
import SwiftUI

@MainActor
struct SettingsView: View {
  @ObservedObject var draft: SettingsDraft
  let save: () -> Void
  let cancel: () -> Void
  private var theme: ColorScheme? {
    draft.value.theme == "system" ? nil : draft.value.theme == "dark" ? .dark : .light
  }
  var body: some View {
    VStack(spacing: 0) {
      Form {
        Section("Editor") {
          Picker("Appearance", selection: $draft.value.theme) {
            Text("System").tag("system")
            Text("Light").tag("light")
            Text("Dark").tag("dark")
          }
          Picker("Font size", selection: $draft.value.editorFontSize) {
            ForEach(10...30, id: \.self) { Text("\($0) pt").tag($0) }
          }
        }
        Section {
          TextField(
            "Shortcut", text: $draft.value.quickPasteShortcut, prompt: Text("Command+Shift+J"))
        } header: {
          Text("Quick Paste")
        } footer: {
          Text("Open clipboard content while the main window is closed. Leave empty to disable.")
        }
      }
      .formStyle(.grouped)
      HStack {
        Spacer()
        Button("Cancel", action: cancel).keyboardShortcut(.cancelAction)
        Button(draft.saving ? "Saving…" : "Save", action: save).keyboardShortcut(.defaultAction)
      }
      .padding(.horizontal, 24).padding(.bottom, 18)
    }
    .disabled(draft.saving)
    .preferredColorScheme(theme)
    .frame(width: 480, height: 355)
  }
}
