import AppKit

/// A menu row carrying a real switch, for the things that are genuinely
/// on/off. A verb ("Stop tsmux") makes the reader work out the current state
/// from the word; a switch shows it.
final class ToggleRowView: NSView {
  private let onToggle: (Bool) -> Void
  private let toggle = NSSwitch()
  private let icon = NSImageView()
  private let detailLabel = NSTextField(labelWithString: "")
  private let titleLabel = NSTextField(labelWithString: "")
  private let chevron = NSTextField(labelWithString: "\u{203A}")

  private var highlighted = false

  /// Driven by the controller: a menu runs its own event-tracking loop and
  /// never delivers `mouseEntered`/`mouseExited` to a tracking area inside it,
  /// so the row cannot work out its own hover state.
  func setHighlighted(_ on: Bool) {
    guard highlighted != on else { return }
    highlighted = on
    needsDisplay = true
  }

  /// Whether the pointer, in screen coordinates, is over this row.
  func contains(screenPoint: NSPoint) -> Bool {
    guard let window else { return false }
    return bounds.contains(convert(window.convertPoint(fromScreen: screenPoint), from: nil))
  }

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
    // The menu is as wide as its widest item; without this the row keeps its
    // own width and the selection stops short of the menu's edge.
    autoresizingMask = [.width]

    let label = titleLabel
    label.stringValue = title
    label.font = .menuFont(ofSize: 0)
    label.lineBreakMode = .byTruncatingTail
    label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

    icon.image = leading
    icon.isHidden = leading == nil
    icon.imageScaling = .scaleProportionallyDown
    // A fixed image column, so the titles of custom rows line up with the
    // titles of ordinary NSMenuItems rather than shifting per glyph width.
    icon.translatesAutoresizingMaskIntoConstraints = false
    icon.widthAnchor.constraint(equalToConstant: 16).isActive = true
    // Left-aligned, so a narrow glyph (a status dot) starts at the same x as
    // a wide one (a globe) instead of being centred a couple of points in.
    icon.imageAlignment = .alignLeft

    toggle.state = isOn ? .on : .off
    toggle.isEnabled = enabled
    toggle.target = self
    toggle.action = #selector(flipped)
    toggle.controlSize = .mini

    let row = NSStackView(views: [icon, label])
    row.orientation = .horizontal
    row.spacing = 5
    row.alignment = .centerY

    detailLabel.stringValue = detail ?? ""
    detailLabel.isHidden = detail == nil
    detailLabel.font = .menuFont(ofSize: NSFont.menuFont(ofSize: 0).pointSize - 2)
    detailLabel.textColor = .secondaryLabelColor
    row.addArrangedSubview(detailLabel)
    row.addArrangedSubview(NSView())
    row.addArrangedSubview(toggle)
    // A custom view suppresses AppKit's own disclosure arrow, so rows that
    // open a submenu draw their own. The column is always reserved, visible
    // or not, otherwise the switches sit at two different x positions
    // depending on whether a row happens to have a submenu.
    chevron.font = .menuFont(ofSize: 0)
    chevron.alphaValue = submenu ? 1 : 0
    chevron.translatesAutoresizingMaskIntoConstraints = false
    chevron.widthAnchor.constraint(equalToConstant: 8).isActive = true
    row.addArrangedSubview(chevron)

    row.translatesAutoresizingMaskIntoConstraints = false
    addSubview(row)
    NSLayoutConstraint.activate([
      // Matches where AppKit indents an ordinary menu item's image. Measured
      // against the neighbouring rows rather than derived — there is no
      // public metric for it.
      row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 23),
      row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
      row.centerYAnchor.constraint(equalTo: centerYAnchor),
    ])
    label.setAccessibilityLabel(title)
  }

  required init?(coder: NSCoder) { fatalError("not used") }

  /// A custom view draws none of AppKit's row chrome, so the selection
  /// background and the white-on-blue text have to be drawn here or the row
  /// stays stubbornly plain while every other item highlights.
  override func draw(_ dirtyRect: NSRect) {
    let on = highlighted
    if on {
      NSColor.selectedContentBackgroundColor.setFill()
      NSBezierPath(
        roundedRect: bounds.insetBy(dx: 5, dy: 1), xRadius: 5, yRadius: 5
      ).fill()
    }
    titleLabel.textColor = on ? .selectedMenuItemTextColor : .labelColor
    chevron.textColor = on ? .selectedMenuItemTextColor : .labelColor
    detailLabel.textColor =
      on ? NSColor.selectedMenuItemTextColor.withAlphaComponent(0.75) : .secondaryLabelColor
    super.draw(dirtyRect)
  }

  /// Re-renders in place. The menu stays open across a toggle, so a row that
  /// only rendered at open time would keep showing the state the tailnet was
  /// in before you touched it.
  func apply(isOn: Bool, enabled: Bool, leading: NSImage?, detail: String?) {
    // Through the animator, so a switch moved by something else — "All
    // tailnets" driving the individual ones — slides like one the user
    // touched instead of snapping. Guarded, or every status poll would
    // restart the animation.
    if toggle.state != (isOn ? .on : .off) {
      toggle.animator().state = isOn ? .on : .off
    }
    toggle.isEnabled = enabled
    icon.image = leading
    icon.isHidden = leading == nil
    detailLabel.stringValue = detail ?? ""
    detailLabel.isHidden = detail == nil
  }

  @objc private func flipped() {
    // The menu stays open: flipping one tailnet is rarely the only thing you
    // came to do, and closing it forces a reopen to see the result or to
    // touch the next one. The switch already shows the new state, and the
    // row is disabled until the daemon confirms so the click cannot be
    // repeated into a contradiction.
    toggle.isEnabled = false
    onToggle(toggle.state == .on)
    toggle.isEnabled = true
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
