import AppKit

/// A menu row carrying a real switch, for the things that are genuinely
/// on/off. A verb ("Stop tsmux") makes the reader work out the current state
/// from the word; a switch shows it.
final class ToggleRowView: NSView {
  private let onToggle: (Bool) -> Void
  private let toggle = NSSwitch()

  init(
    title: String,
    isOn: Bool,
    enabled: Bool = true,
    leading: NSImage? = nil,
    detail: String? = nil,
    submenu: Bool = false,
    onToggle: @escaping (Bool) -> Void
  ) {
    self.onToggle = onToggle
    // A menu item view is sized from its frame, not from its constraints: with
    // an empty frame AppKit lays out a zero-height row and the item vanishes.
    super.init(frame: NSRect(x: 0, y: 0, width: 264, height: 26))

    let label = NSTextField(labelWithString: title)
    label.font = .menuFont(ofSize: 0)
    label.lineBreakMode = .byTruncatingTail
    label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

    let icon = NSImageView(image: leading ?? NSImage())
    icon.isHidden = leading == nil
    icon.imageScaling = .scaleProportionallyDown

    toggle.state = isOn ? .on : .off
    toggle.isEnabled = enabled
    toggle.target = self
    toggle.action = #selector(flipped)
    toggle.controlSize = .mini

    let row = NSStackView(views: [icon, label])
    row.orientation = .horizontal
    row.spacing = 6
    row.alignment = .centerY

    if let detail {
      let d = NSTextField(labelWithString: detail)
      d.font = .menuFont(ofSize: NSFont.menuFont(ofSize: 0).pointSize - 2)
      d.textColor = .secondaryLabelColor
      row.addArrangedSubview(d)
    }
    row.addArrangedSubview(NSView())
    row.addArrangedSubview(toggle)
    if submenu {
      // A custom view suppresses AppKit's own disclosure arrow, and a row that
      // opens a submenu has to look like one.
      let chev = NSTextField(labelWithString: "\u{203A}")
      chev.font = .menuFont(ofSize: 0)
      chev.textColor = .tertiaryLabelColor
      row.addArrangedSubview(chev)
    }

    row.translatesAutoresizingMaskIntoConstraints = false
    addSubview(row)
    NSLayoutConstraint.activate([
      row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
      row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
      row.centerYAnchor.constraint(equalTo: centerYAnchor),
    ])
    label.setAccessibilityLabel(title)
  }

  required init?(coder: NSCoder) { fatalError("not used") }

  @objc private func flipped() {
    onToggle(toggle.state == .on)
    // Acting on the switch is a decision; leaving the menu open afterwards
    // invites a second, contradictory click while the first is still applying.
    enclosingMenuItem?.menu?.cancelTracking()
  }
}

extension NSMenuItem {
  /// Builds a menu item whose entire row is a switch.
  static func toggle(
    title: String,
    isOn: Bool,
    enabled: Bool = true,
    leading: NSImage? = nil,
    detail: String? = nil,
    submenu: Bool = false,
    onToggle: @escaping (Bool) -> Void
  ) -> NSMenuItem {
    let mi = NSMenuItem()
    mi.view = ToggleRowView(
      title: title, isOn: isOn, enabled: enabled, leading: leading, detail: detail,
      submenu: submenu, onToggle: onToggle)
    return mi
  }
}
