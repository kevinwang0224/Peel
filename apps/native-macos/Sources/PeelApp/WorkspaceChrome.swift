import AppKit
import PeelCore

@MainActor
enum WorkspaceChrome {
  static func label(_ title: String, weight: NSFont.Weight) -> NSTextField {
    let label = NSTextField(labelWithString: title)
    label.font = .systemFont(ofSize: 12, weight: weight)
    return label
  }

  static func symbol(_ name: String, size: CGFloat) -> NSImageView {
    let image = NSImageView(image: NSImage(systemSymbolName: name, accessibilityDescription: nil)!)
    image.symbolConfiguration = .init(pointSize: size, weight: .medium)
    image.contentTintColor = .secondaryLabelColor
    return image
  }

  static func header(_ items: [NSView], height: CGFloat, separator: Bool = true) -> NSView {
    let header = NSView()
    let stack = NSStackView(views: items)
    stack.orientation = .horizontal
    stack.spacing = 10
    stack.alignment = .centerY
    header.addSubview(stack)
    stack.translatesAutoresizingMaskIntoConstraints = false
    NSLayoutConstraint.activate([
      header.heightAnchor.constraint(equalToConstant: height),
      stack.leadingAnchor.constraint(equalTo: header.leadingAnchor, constant: 16),
      stack.trailingAnchor.constraint(equalTo: header.trailingAnchor, constant: -16),
      stack.centerYAnchor.constraint(equalTo: header.centerYAnchor),
    ])
    if separator {
      let line = NSBox()
      line.boxType = .separator
      header.addSubview(line)
      line.translatesAutoresizingMaskIntoConstraints = false
      NSLayoutConstraint.activate([
        line.leadingAnchor.constraint(equalTo: header.leadingAnchor),
        line.trailingAnchor.constraint(equalTo: header.trailingAnchor),
        line.bottomAnchor.constraint(equalTo: header.bottomAnchor),
      ])
    }
    return header
  }
}

@MainActor
final class HistoryCellView: NSTableCellView {
  private let detail = NSTextField(labelWithString: "")
  private static let isoDate = ISO8601DateFormatter()
  private static let fractionalDate: ISO8601DateFormatter = {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter
  }()
  private static let displayDate: DateFormatter = {
    let formatter = DateFormatter()
    formatter.dateStyle = .medium
    formatter.timeStyle = .short
    return formatter
  }()

  override init(frame: NSRect) {
    super.init(frame: frame)
    let title = WorkspaceChrome.label("", weight: .medium)
    title.lineBreakMode = .byTruncatingTail
    detail.font = .systemFont(ofSize: 10)
    detail.textColor = .secondaryLabelColor
    detail.lineBreakMode = .byTruncatingTail
    let icon = WorkspaceChrome.symbol("doc.text", size: 14)
    for item in [title, detail, icon] {
      addSubview(item)
      item.translatesAutoresizingMaskIntoConstraints = false
    }
    textField = title
    imageView = icon
    NSLayoutConstraint.activate([
      icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 9),
      icon.centerYAnchor.constraint(equalTo: centerYAnchor),
      icon.widthAnchor.constraint(equalToConstant: 16),
      title.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 10),
      title.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
      title.topAnchor.constraint(equalTo: topAnchor, constant: 8),
      detail.leadingAnchor.constraint(equalTo: title.leadingAnchor),
      detail.trailingAnchor.constraint(equalTo: title.trailingAnchor),
      detail.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 3),
    ])
  }
  convenience init() { self.init(frame: .zero) }
  required init?(coder: NSCoder) { fatalError("Not supported") }

  func configure(_ record: HistorySummary) {
    textField?.stringValue = record.title
    imageView?.image = NSImage(
      systemSymbolName: record.pinned ? "pin.fill" : "doc.text",
      accessibilityDescription: record.pinned ? "Pinned" : nil)
    let date =
      Self.isoDate.date(from: record.updatedAt) ?? Self.fractionalDate.date(from: record.updatedAt)
    detail.stringValue = date.map { Self.displayDate.string(from: $0) } ?? record.updatedAt
    toolTip = record.title
  }
}
