import AppKit

@main
enum PeelApplication {
  @MainActor static func main() {
    let application = NSApplication.shared
    let delegate = ApplicationController()
    application.delegate = delegate
    application.setActivationPolicy(.regular)
    withExtendedLifetime(delegate) { application.run() }
  }
}
