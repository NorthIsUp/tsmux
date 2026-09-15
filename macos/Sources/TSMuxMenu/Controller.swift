import AppKit
import Foundation

// AppKit NSStatusItem + NSMenu, not SwiftUI MenuBarExtra: MenuBarExtra offers no
// menuWillOpen hook and no per-item tooltips, which this whole UI is built on.
// The Settings window is SwiftUI; the menu is not.

@MainActor
final class Controller: NSObject, NSMenuDelegate {
  let model = AppModel()
  private var item: NSStatusItem?
  private let menu = NSMenu()
  private var timer: Timer?

  // MARK: launch

  func install() {
    model.onChange = { [weak self] in
      self?.updateIcon()
      self?.scheduleTimer()
    }
    menu.delegate = self
    // Automatic validation re-enables any item with a target+action, discarding
    // every `isEnabled = false` below.
    menu.autoenablesItems = false
    let i = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    i.menu = menu
    i.isVisible = true
    i.button?.imagePosition = .imageLeading
    if i.button == nil {
      NSLog("tsmux: NSStatusItem has no button — menu bar item will not appear")
    }
    item = i
    model.launchProbe()
    updateIcon()
    scheduleTimer()
    if CLI.path == nil {
      Alert.show("tsmux CLI not found", "TSMux could not find the tsmux executable to talk to.")
    }
  }

  // MARK: refresh

  private func scheduleTimer() {
    let interval: TimeInterval
    switch model.ui {
    case .starting: interval = 1
    case .ok(let ps): interval = ps.contains { $0.condition == .needsLogin } ? 1 : 5
    default: interval = 15
    }
    if let t = timer, t.timeInterval == interval, t.isValid { return }
    timer?.invalidate()
    let t = Timer(timeInterval: interval, repeats: true) { _ in
      MainActor.assumeIsolated { self.model.refresh() }
    }
    t.tolerance = 1
    // .common so the badge keeps ticking while the menu is tracking.
    RunLoop.main.add(t, forMode: .common)
    timer = t
  }

  @objc private func refresh() { model.refresh() }

  // MARK: status item

  private func updateIcon() {
    guard let button = item?.button else { return }
    let ps = model.profiles
    let up = ps.filter { $0.condition == .running }.count
    let total = ps.count

    let label: String
    var badge: String?
    var dimmed = false

    if case .firstRun = model.configState {
      button.image = Self.gridImage(connected: 0, total: 0)
      button.appearsDisabled = true
      button.title = ""
      button.toolTip = "tsmux — no tailnets set up yet"
      button.setAccessibilityLabel(button.toolTip)
      return
    }

    switch model.ui {
    case .ok:
      let needLogin = ps.filter { $0.condition == .needsLogin }.count
      let failed = ps.filter { $0.condition == .failed }.count
      if needLogin > 0 {
        label = "tsmux, \(needLogin) of \(total) tailnets need login"
      } else if failed > 0 {
        label = "tsmux, \(failed) of \(total) tailnets have errors"
      } else {
        label = "tsmux, \(up) of \(total) tailnets connected"
      }
      // "5/5" is noise when everything is fine — the grid already says so.
      // The count earns its space the moment a tailnet is not up.
      if total > 0, up < total || model.alwaysShowCount {
        badge = "\(up)/\(total)"
      }
    case .starting:
      badge = "…"
      label = "tsmux, starting"
    case .down:
      dimmed = true
      label = "tsmux, not running"
    case .failed, .crashed, .cliMissing:
      dimmed = true
      label = "tsmux, can't read status"
    }

    // Always the grid. Swapping in a warning symbol makes the app stop
    // looking like itself exactly when the user is trying to find it; the
    // unlit dots and the count already say something needs attention.
    button.image = Self.gridImage(connected: up, total: total)
    button.appearsDisabled = dimmed
    button.toolTip = label
    button.setAccessibilityLabel(label)

    if let badge {
      button.attributedTitle = NSAttributedString(
        string: " \(badge)",
        attributes: [
          .font: NSFont.monospacedDigitSystemFont(
            ofSize: NSFont.systemFontSize(for: .small), weight: .medium)
        ])
    } else {
      button.title = ""
    }

    // Invariant: the item is never contentless, whatever SF Symbols does.
    if button.image == nil {
      button.title = up > 0 ? "tsmux \(up)/\(total)" : "tsmux"
    }
    assert(button.image != nil || !button.title.isEmpty)
  }

  private static func barImage(_ symbol: String) -> NSImage? {
    let image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
      .withSymbolConfiguration(
        NSImage.SymbolConfiguration(pointSize: 15, weight: .medium, scale: .medium))
    image?.isTemplate = true
    return image
  }

  /// The menu bar mark: a dot grid with an arrow rising through the middle —
  /// Tailscale's family resemblance, plus the one thing tsmux adds, which is
  /// traffic being routed up through several tailnets at once.
  ///
  /// Filled dots count the connected tailnets, so the icon carries the state
  /// that a "2/3" text badge used to. Drawn rather than an asset: it has to
  /// change with the count, and a template image tints itself in both menu
  /// bar appearances for free.
  static func gridImage(connected: Int, total: Int) -> NSImage {
    let size = NSSize(width: 16, height: 14)
    let image = NSImage(size: size, flipped: false) { _ in
      guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
      let r: CGFloat = 1.45
      let cols: [CGFloat] = [3, 8, 13]
      let rows: [CGFloat] = [2.6, 7, 11.4]

      // A 3x3 grid with the top-middle dot promoted to a chevron: the grid is
      // the tailnets, the chevron is traffic leaving through them. No stem —
      // a shaft through the middle reads as something else entirely.
      var slots: [(CGFloat, CGFloat)] = []
      for y in rows {
        for x in cols where !(y == rows[2] && x == cols[1]) {
          slots.append((x, y))
        }
      }
      slots.sort { a, b in a.1 == b.1 ? a.0 < b.0 : a.1 < b.1 }

      let dimAll = total == 0
      let lit = max(0, min(connected, slots.count))
      for (i, p) in slots.enumerated() {
        let on = !dimAll && i < lit
        ctx.setFillColor(NSColor.black.withAlphaComponent(on ? 1 : 0.32).cgColor)
        ctx.fillEllipse(in: CGRect(x: p.0 - r, y: p.1 - r, width: r * 2, height: r * 2))
      }

      ctx.setStrokeColor(NSColor.black.withAlphaComponent(dimAll ? 0.32 : 1).cgColor)
      ctx.setLineWidth(1.7)
      ctx.setLineCap(.round)
      ctx.setLineJoin(.round)
      let cx = cols[1]
      let tip: CGFloat = 13.1
      let wing: CGFloat = 3.0
      ctx.move(to: CGPoint(x: cx - wing, y: tip - wing))
      ctx.addLine(to: CGPoint(x: cx, y: tip))
      ctx.addLine(to: CGPoint(x: cx + wing, y: tip - wing))
      ctx.strokePath()
      return true
    }
    image.isTemplate = true
    return image
  }

  private func disabled(_ title: String) -> NSMenuItem {
    let mi = NSMenuItem(title: title, action: nil, keyEquivalent: "")
    mi.isEnabled = false
    return mi
  }

  private func action(_ title: String, _ sel: Selector, key: String = "") -> NSMenuItem {
    let mi = NSMenuItem(title: title, action: sel, keyEquivalent: key)
    mi.target = self
    return mi
  }

  // MARK: actions

  @objc private func start() { model.start() }
  @objc private func stop() { model.stop() }
  @objc private func togglePAC() { model.togglePAC() }
  @objc private func quit() { NSApp.terminate(nil) }

  @objc private func openSettings() {
    SettingsWindow.shared.show(model)
  }

  @objc private func addTailnet() {
    model.selectedTab = .accounts
    SettingsWindow.shared.show(model, addTailnet: true)
  }

  @objc private func openProfileSettings(_ sender: NSMenuItem) {
    model.selectedTab = .accounts
    model.selectedProfile = sender.representedObject as? String
    SettingsWindow.shared.show(model)
  }

  @objc private func copyPAC() {
    guard let url = CLI.pacURL() else {
      Alert.show("Could not get the PAC URL", "tsmux reported no details.")
      return
    }
    copy(url)
  }

  @objc private func openLogin(_ sender: NSMenuItem) {
    guard let s = sender.representedObject as? String, let url = URL(string: s) else { return }
    if !NSWorkspace.shared.open(url) { Alert.show("Could not open the login page", s) }
  }

  @objc private func copyValue(_ sender: NSMenuItem) {
    guard let s = sender.representedObject as? String else { return }
    copy(s)
  }

  /// Never invents a file: with no config the Add-tailnet sheet is the answer.
  @objc private func openConfig() {
    let file = ConfigPath.file
    guard FileManager.default.fileExists(atPath: file.path) else {
      addTailnet()
      return
    }
    if !NSWorkspace.shared.open(file) {
      Alert.show("Could not open the configuration file", file.path)
    }
  }

  @objc private func runDoctor() {
    let (data, err, code) = CLI.run(["--json", "doctor"], timeout: 30)
    // doctor exits 1 when it merely found problems, so read the JSON not the code.
    if let report = try? JSONDecoder().decode(DoctorReport.self, from: data) {
      let problems = report.problems ?? []
      Alert.show(
        problems.isEmpty ? "No problems found" : "\(problems.count) problem(s) found",
        ([report.config] + problems).joined(separator: "\n\n"))
      return
    }
    Alert.show("Diagnostics failed", code == 0 ? "tsmux produced no report." : CLI.message(err))
  }

  func shutdown() {
    timer?.invalidate()
    model.shutdown()
  }

  // MARK: helpers

  private func copy(_ s: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(s, forType: .string)
    guard let button = item?.button else { return }
    button.image = nil
    button.title = "Copied"
    DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
      MainActor.assumeIsolated { self.updateIcon() }
    }
  }
}

enum ConfigPath {
  static var file: URL {
    let base =
      ProcessInfo.processInfo.environment["XDG_CONFIG_HOME"].flatMap { $0.isEmpty ? nil : $0 }
      ?? ("~/.config" as NSString).expandingTildeInPath
    return URL(fileURLWithPath: base)
      .appendingPathComponent("tsmux")
      .appendingPathComponent("config.yaml")
  }
}
