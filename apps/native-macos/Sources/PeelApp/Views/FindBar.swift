import SwiftUI

@MainActor
struct FindBar: View {
  @ObservedObject var presentation: WorkspacePresentation
  @FocusState private var searchFocused: Bool
  var body: some View {
    VStack(spacing: 7) {
      HStack(spacing: 8) {
        TextField("Find", text: $presentation.findText)
          .focused($searchFocused).onSubmit { presentation.find(backwards: false) }
        Button {
          presentation.find(backwards: true)
        } label: {
          Image(systemName: "chevron.up")
        }
        .help("Previous match")
        Button {
          presentation.find(backwards: false)
        } label: {
          Image(systemName: "chevron.down")
        }
        .help("Next match")
        Button {
          presentation.findVisible = false
          presentation.focusedEditor?.focusEditor()
        } label: {
          Image(systemName: "xmark")
        }.help("Close find")
      }
      HStack(spacing: 8) {
        TextField("Replace", text: $presentation.replaceText)
        Button("Replace") { presentation.replace(all: false) }
        Button("All") { presentation.replace(all: true) }
      }
      .disabled(presentation.focusedRole == .result)
    }
    .controlSize(.small).padding(10)
    .overlay(alignment: .bottom) { Divider() }
    .task(id: presentation.findFocusRequest) {
      await Task.yield()
      guard !Task.isCancelled else { return }
      searchFocused = true
    }
  }
}
