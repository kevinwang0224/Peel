import SwiftUI

@MainActor
struct FindBar: View {
  @ObservedObject var presentation: WorkspacePresentation
  @FocusState private var searchFocused: Bool
  private var summary: String {
    guard !presentation.findText.isEmpty else { return "" }
    if presentation.matchCount == 0 { return "No results" }
    let total = presentation.matchCount >= 10_000 ? "10,000+" : "\(presentation.matchCount)"
    return presentation.matchIndex > 0 ? "\(presentation.matchIndex) of \(total)" : total
  }
  var body: some View {
    VStack(spacing: 6) {
      HStack(spacing: 6) {
        Button {
          withAnimation(.snappy(duration: 0.18)) { presentation.replaceVisible.toggle() }
        } label: {
          Image(systemName: "chevron.right")
            .rotationEffect(.degrees(presentation.replaceVisible ? 90 : 0))
            .frame(width: 14)
        }
        .buttonStyle(.borderless).help("Show / Hide Replace")
        .accessibilityLabel("Toggle replace")
        HStack(spacing: 5) {
          Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
          TextField("Find", text: $presentation.findText)
            .textFieldStyle(.plain).focused($searchFocused)
            .onSubmit { presentation.find(backwards: NSEvent.modifierFlags.contains(.shift)) }
          Text(summary)
            .font(.caption).monospacedDigit()
            .foregroundStyle(
              presentation.matchCount == 0 && !presentation.findText.isEmpty
                ? Color.red : Color.secondary)
          option("Aa", "Match Case", $presentation.matchCase)
          option("W", "Whole Word", $presentation.wholeWord)
          option(".*", "Regular Expression", $presentation.useRegex)
        }
        .padding(.horizontal, 7).padding(.vertical, 4)
        .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 6))
        .overlay(
          RoundedRectangle(cornerRadius: 6)
            .strokeBorder(Color.accentColor.opacity(searchFocused ? 0.7 : 0), lineWidth: 1.5))
        ControlGroup {
          Button {
            presentation.find(backwards: true)
          } label: {
            Image(systemName: "chevron.up")
          }
          .help("Previous Match (⇧⌘G)")
          Button {
            presentation.find(backwards: false)
          } label: {
            Image(systemName: "chevron.down")
          }
          .help("Next Match (⌘G)")
        }
        .fixedSize().disabled(presentation.findText.isEmpty)
        Button("Done") { presentation.closeFind() }
      }
      if presentation.replaceVisible {
        HStack(spacing: 6) {
          Color.clear.frame(width: 14, height: 1)
          TextField("Replace", text: $presentation.replaceText)
            .textFieldStyle(.roundedBorder)
          Button("Replace") { presentation.replace(all: false) }
          Button("Replace All") { presentation.replace(all: true) }
        }
        .disabled(presentation.focusedRole == .result)
        .transition(.opacity)
      }
    }
    .controlSize(.small).padding(.horizontal, 10).padding(.vertical, 7)
    .background(.bar)
    .overlay(alignment: .bottom) { Divider() }
    .onExitCommand { presentation.closeFind() }
    .onChange(of: presentation.findText) {
      presentation.find(backwards: false, inclusive: true)
    }
    .onChange(of: presentation.matchCase) { presentation.refreshMatches() }
    .onChange(of: presentation.wholeWord) { presentation.refreshMatches() }
    .onChange(of: presentation.useRegex) { presentation.refreshMatches() }
    .task(id: presentation.findFocusRequest) {
      await Task.yield()
      guard !Task.isCancelled else { return }
      searchFocused = true
    }
  }
  private func option(_ label: String, _ help: String, _ isOn: Binding<Bool>) -> some View {
    Toggle(isOn: isOn) {
      Text(label).font(.system(size: 10, weight: .semibold, design: .monospaced))
        .frame(minWidth: 16)
    }
    .toggleStyle(.button).buttonStyle(.borderless)
    .background(isOn.wrappedValue ? Color.accentColor.opacity(0.25) : .clear, in: RoundedRectangle(cornerRadius: 4))
    .help(help).accessibilityLabel(help)
  }
}
