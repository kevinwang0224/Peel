import PeelCore
import SwiftUI

@MainActor
struct SettingsView: View {
  @ObservedObject var draft: SettingsDraft
  let changed: () -> Void
  var body: some View {
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
        LabeledContent("Shortcut") {
          ShortcutRecorder(shortcut: $draft.value.quickPasteShortcut)
        }
      } header: {
        Text("Quick Paste")
      } footer: {
        Text(
          "Opens the clipboard as a scratch window from anywhere. Click the field and press a key combination; ⌫ clears it."
        )
      }
    }
    .formStyle(.grouped)
    .onChange(of: draft.value) { changed() }
    .frame(width: 460, height: 300)
  }
}
