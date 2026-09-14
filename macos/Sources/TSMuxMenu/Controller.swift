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

    let symbol: String
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
      if ps.contains(where: { $0.condition == .needsLogin }) {
        symbol = "exclamationmark.triangle.fill"
        label = "tsmux, \(ps.filter { $0.condition == .needsLogin }.count) tailnets need login"
      } else if ps.contains(where: { $0.condition == .failed }) {
        symbol = "exclamationmark.triangle.fill"
        label = "tsmux, \(ps.filter { $0.condition == .failed }.count) tailnets have errors"
      } else {
        symbol = "grid"
        label = "tsmux, \(up) of \(total) tailnets connected"
      }
    case .starting:
      symbol = "grid"
      badge = "…"
      label = "tsmux, starting"
    case .down:
      symbol = "grid"
      dimmed = true
      label = "tsmux, not running"
    case .failed, .crashed, .cliMissing:
      symbol = "exclamationmark.triangle.fill"
      label = "tsmux, can't read status"
    }

    // "5/5" is noise — everything is fine and the grid already says so. The
    // count earns its space only when some tailnet is not up.
    if case .ok = model.ui, total > 0, up < total || model.alwaysShowCount {
      badge = "\(up)/\(total)"
    }

    // The grid carries the count itself; a warning symbol still wins when
    // something actually needs the user.
    let image =
      symbol == "exclamationmark.triangle.fill"
      ? Self.barImage(symbol)
      : Self.gridImage(connected: up, total: total)
    button.image = image
    button.appearsDisabled = dimmed
    button.toolTip = label
    button.setAccessibilityLabel(label)

    if let badge, image != nil {
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
    let size = NSSize(width: 17, height: 15)
    let image = NSImage(size: size, flipped: false) { _ in
      guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
      let dotR: CGFloat = 1.5
      let colX: [CGFloat] = [3, 13]
      let rowY: [CGFloat] = [3, 7.5, 12]
      // Fill order is bottom-up, left column first, so the first tailnet to
      // connect lights the dot nearest the arrow's base.
      var slots: [(CGFloat, CGFloat)] = []
      for y in rowY { for x in colX { slots.append((x, y)) } }
      let lit = max(0, min(connected, slots.count))
      // With nothing configured, show the full grid faintly rather than a
      // blank patch of menu bar.
      let dimAll = total == 0
      for (i, p) in slots.enumerated() {
        let on = !dimAll && i < lit
        ctx.setFillColor(NSColor.black.withAlphaComponent(on ? 1 : 0.3).cgColor)
        ctx.fillEllipse(in: CGRect(x: p.0 - dotR, y: p.1 - dotR, width: dotR * 2, height: dotR * 2))
      }
      ctx.setFillColor(NSColor.black.withAlphaComponent(dimAll ? 0.3 : 1).cgColor)
      let midX: CGFloat = 8.5
      let head: CGFloat = 3.1
      ctx.move(to: CGPoint(x: midX, y: 14))
      ctx.addLine(to: CGPoint(x: midX - head, y: 14 - head - 0.6))
      ctx.addLine(to: CGPoint(x: midX + head, y: 14 - head - 0.6))
      ctx.closePath()
      ctx.fillPath()
      ctx.setFillColor(NSColor.black.withAlphaComponent(dimAll ? 0.3 : 1).cgColor)
      ctx.fill(CGRect(x: midX - 0.9, y: 2, width: 1.8, height: 8.4))
      return true
    }
    image.isTemplate = true
    return image
  }

  // MARK: menu

  func menuWillOpen(_ menu: NSMenu) {
    rebuild()
    model.refresh()  // async; lands for the next open, never mutating a tracking menu
  }

  private func rebuild() {
    menu.removeAllItems()

    switch model.configState {
    case .firstRun:
      rebuildFirstRun()
      return
    case .broken(let msg):
      rebuildBroken(msg)
      return
    case .configured:
      break
    }

    // 1. status / profile block
    switch model.ui {
    case .cliMissing:
      menu.addItem(disabled("tsmux CLI not found"))
    case .down:
      menu.addItem(disabled("tsmux is not running"))
    case .starting:
      menu.addItem(disabled("Starting tsmux… (up to 30s)"))
    case .crashed(let line):
      let mi = disabled("tsmux stopped unexpectedly")
      mi.toolTip = line
      menu.addItem(mi)
    case .failed(let msg):
      let mi = disabled("Can't read tsmux status")
      mi.toolTip = msg
      menu.addItem(mi)
    case .ok(let ps):
      if ps.isEmpty {
        menu.addItem(action("Set up your first tailnet…", #selector(addTailnet)))
      } else {
        for p in ps { menu.addItem(profileItem(p)) }
      }
    }

    // 2. attention row
    // .needsLogin now implies a usable link — a node still acquiring one reads
    // as .starting, so there is no link-less case to render here.
    if let p = model.profiles.first(where: { $0.condition == .needsLogin }),
      let url = p.authURL, !url.isEmpty
    {
      let mi = action("Log in to \(p.name)…", #selector(openLogin(_:)))
      mi.representedObject = url
      menu.addItem(mi)
    }

    menu.addItem(.separator())

    // 3. start / stop
    if model.daemonRunning {
      let mi = action(
        model.weOwnDaemon ? "Stop tsmux" : "Stop tsmux (started elsewhere)", #selector(stop))
      mi.isEnabled = model.weOwnDaemon
      menu.addItem(mi)
    } else {
      let mi = action("Start tsmux", #selector(start))
      mi.isEnabled = CLI.path != nil
      menu.addItem(mi)
    }

    // 4. PAC toggle, 5. copy PAC
    let anyUp = model.profiles.contains { $0.condition == .running }
    let pac = action("Route System Traffic via tsmux", #selector(togglePAC))
    pac.state = model.pacApplied ? .on : .off
    pac.isEnabled = anyUp
    menu.addItem(pac)

    let copyPac = action("Copy PAC URL", #selector(copyPAC))
    copyPac.isEnabled = anyUp
    menu.addItem(copyPac)

    menu.addItem(.separator())

    // 6-9. fixed tail
    menu.addItem(action("Refresh", #selector(refresh), key: "r"))
    menu.addItem(action("Settings…", #selector(openSettings), key: ","))
    menu.addItem(advancedItem())
    menu.addItem(
      action(
        model.weOwnDaemon ? "Quit TSMux (stops tailnets)" : "Quit TSMux", #selector(quit),
        key: "q"))
  }

  private func rebuildFirstRun() {
    let setup = action("Set up your first tailnet…", #selector(addTailnet))
    setup.image = NSImage(systemSymbolName: "plus.circle.fill", accessibilityDescription: nil)?
      .withSymbolConfiguration(
        NSImage.SymbolConfiguration(paletteColors: [.controlAccentColor]))
    setup.image?.isTemplate = false
    menu.addItem(setup)
    menu.addItem(.separator())
    menu.addItem(advancedItem())
    menu.addItem(action("Quit TSMux", #selector(quit), key: "q"))
  }

  private func rebuildBroken(_ msg: String) {
    menu.addItem(disabled("⚠ Configuration error"))
    let line = disabled(msg.split(separator: "\n").first.map(String.init) ?? msg)
    line.toolTip = msg
    menu.addItem(line)
    menu.addItem(.separator())
    menu.addItem(action("Open Configuration…", #selector(openConfig)))
    menu.addItem(action("Run Diagnostics…", #selector(runDoctor)))
    menu.addItem(.separator())
    menu.addItem(action("Quit TSMux", #selector(quit), key: "q"))
  }

  private func advancedItem() -> NSMenuItem {
    let top = NSMenuItem(title: "Advanced", action: nil, keyEquivalent: "")
    let sub = NSMenu()
    sub.autoenablesItems = false
    sub.addItem(action("Edit config.yaml…", #selector(openConfig)))
    sub.addItem(action("Run Diagnostics…", #selector(runDoctor)))
    top.submenu = sub
    return top
  }

  /// Devices submenu. Each device is three stacked items sharing one slot:
  /// plain copies the URL, Option the IP, Shift-Option the short name. AppKit
  /// swaps them as the modifiers change, so the menu shows only one at a time.
  private func addDevices(_ p: ProfileStatus, to sub: NSMenu) {
    let devices = p.devices ?? []
    guard !devices.isEmpty else {
      sub.addItem(disabled("\(p.peers ?? 0) peers"))
      return
    }
    let root = NSMenuItem(title: "Devices (\(devices.count))", action: nil, keyEquivalent: "")
    let menu = NSMenu()
    menu.autoenablesItems = false

    // Tagged groups after people, each alphabetical; within a group the
    // reachable devices come first, since those are the ones you can act on.
    let groups = Dictionary(grouping: devices, by: \.group)
    let ordered = groups.keys.sorted { a, b in
      let at = a.hasPrefix("tag:")
      let bt = b.hasPrefix("tag:")
      return at == bt ? a.localizedStandardCompare(b) == .orderedAscending : !at
    }
    for (i, key) in ordered.enumerated() {
      if i > 0 { menu.addItem(.separator()) }
      menu.addItem(disabled(key))
      let sorted = (groups[key] ?? []).sorted {
        $0.online == $1.online
          ? $0.shortName.localizedStandardCompare($1.shortName) == .orderedAscending
          : $0.online
      }
      for d in sorted { addDeviceVariants(d, to: menu) }
    }
    root.submenu = menu
    sub.addItem(root)
  }

  private func addDeviceVariants(_ d: Device, to menu: NSMenu) {
    let dot = d.online ? "🟢" : "⚪️"
    let exit = d.exitNode == true ? "  ⇥" : ""
    let variants: [(String, String?)] = [
      ("\(dot)  \(d.shortName)\(exit)", d.url),
      ("\(dot)  \(d.shortName)\(exit)  — copy IP", d.primaryIP),
      ("\(dot)  \(d.shortName)\(exit)  — copy name", d.shortName),
    ]
    let masks: [NSEvent.ModifierFlags] = [[], [.option], [.option, .shift]]
    for (i, v) in variants.enumerated() {
      let mi = NSMenuItem(title: v.0, action: #selector(copyValue(_:)), keyEquivalent: "")
      mi.target = self
      mi.keyEquivalentModifierMask = masks[i]
      mi.isAlternate = i > 0
      mi.isEnabled = v.1 != nil
      mi.representedObject = v.1
      mi.toolTip = [d.name, d.primaryIP, d.os].compactMap { $0 }.joined(separator: " · ")
      mi.setAccessibilityLabel(
        "\(d.shortName), \(d.online ? "online" : "offline")")
      menu.addItem(mi)
    }
  }

  private func profileItem(_ p: ProfileStatus) -> NSMenuItem {
    let (symbol, color, label) = Self.appearance(p.condition, state: p.state)
    let top = NSMenuItem(title: "\(p.name) — \(label)", action: nil, keyEquivalent: "")
    top.target = self
    if p.condition == .needsLogin, let url = p.authURL, !url.isEmpty {
      top.action = #selector(openLogin(_:))
      top.representedObject = url
    } else if let proxy = p.httpProxy, !proxy.isEmpty {
      top.action = #selector(copyValue(_:))
      top.representedObject = proxy
    }
    top.image = Self.statusImage(symbol, color)
    top.setAccessibilityLabel("\(p.name), \(label)")
    top.toolTip = p.error.map { "\(p.state): \($0)" } ?? p.state

    let sub = NSMenu()
    sub.autoenablesItems = false
    if let e = p.error, !e.isEmpty {
      let mi = action(
        "⚠︎ \(e.count > 80 ? String(e.prefix(79)) + "…" : e)", #selector(copyValue(_:)))
      mi.representedObject = e
      mi.toolTip = e
      sub.addItem(mi)
    }
    if p.condition == .needsLogin, let url = p.authURL, !url.isEmpty {
      let mi = action("Log in to this tailnet…", #selector(openLogin(_:)))
      mi.representedObject = url
      sub.addItem(mi)
    }
    if sub.numberOfItems > 0 { sub.addItem(.separator()) }

    sub.addItem(disabled("profile: \(p.profile)"))
    if let n = p.machineName {
      let mi = action(n, #selector(copyValue(_:)))
      mi.representedObject = n
      sub.addItem(mi)
    }
    for ip in p.ips ?? [] {
      let mi = action(ip, #selector(copyValue(_:)))
      mi.representedObject = ip
      sub.addItem(mi)
    }
    addDevices(p, to: sub)
    sub.addItem(.separator())

    let http = p.httpProxy ?? ""
    let socks = p.socks5Proxy ?? ""
    if !http.isEmpty {
      let mi = action("Copy HTTP Proxy Address", #selector(copyValue(_:)))
      mi.representedObject = http
      sub.addItem(mi)
    }
    if !socks.isEmpty {
      let mi = action("Copy SOCKS5 Proxy Address", #selector(copyValue(_:)))
      mi.representedObject = socks
      sub.addItem(mi)
    }
    if !http.isEmpty || !socks.isEmpty {
      sub.addItem(disabled("HTTP \(http) · SOCKS5 \(socks)"))
    }
    if let sfx = p.suffixes, !sfx.isEmpty {
      sub.addItem(.separator())
      for s in sfx {
        let mi = action(s, #selector(copyValue(_:)))
        mi.representedObject = s
        sub.addItem(mi)
      }
    }
    sub.addItem(.separator())
    let settings = action("Tailnet Settings…", #selector(openProfileSettings(_:)))
    settings.representedObject = p.profile
    sub.addItem(settings)
    top.submenu = sub
    return top
  }

  static func appearance(_ c: ProfileStatus.Condition, state: String)
    -> (String, NSColor, String)
  {
    switch c {
    case .running: return ("checkmark.circle.fill", .systemGreen, "Connected")
    case .starting: return ("arrow.triangle.2.circlepath", .systemBlue, "Connecting…")
    case .needsLogin: return ("exclamationmark.triangle.fill", .systemYellow, "Needs login")
    case .stopped:
      return ("pause.circle", .tertiaryLabelColor, state == "NoState" ? "Not started" : "Stopped")
    case .failed: return ("xmark.octagon.fill", .systemRed, "Error")
    }
  }

  private static func statusImage(_ symbol: String, _ color: NSColor) -> NSImage? {
    let config = NSImage.SymbolConfiguration(pointSize: 12, weight: .semibold)
      .applying(NSImage.SymbolConfiguration(paletteColors: [color]))
    // Template images discard palette colours — all five states would flatten.
    let image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
      .withSymbolConfiguration(config)
    image?.isTemplate = false
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
