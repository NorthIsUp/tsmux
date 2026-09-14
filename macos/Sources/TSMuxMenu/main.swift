import AppKit
import Foundation

// AppKit NSStatusItem + NSMenu, not SwiftUI MenuBarExtra: MenuBarExtra offers no
// menuWillOpen hook and no per-item tooltips, which this whole UI is built on.
//
// Everything it knows comes from `tsmux --json`, so the two stay in step
// without a second config parser.

// MARK: - CLI model

struct ProfileStatus: Decodable, Sendable {
  let profile: String
  let displayName: String
  let state: String
  let selfName: String?
  let ips: [String]?
  let peers: Int?
  let authURL: String?
  let suffixes: [String]?
  let httpProxy: String?
  let socks5Proxy: String?
  let error: String?

  enum CodingKeys: String, CodingKey {
    case profile
    case displayName = "display_name"
    case state
    case selfName = "self"
    case ips
    case peers
    case authURL = "auth_url"
    case suffixes
    case httpProxy = "http_proxy"
    case socks5Proxy = "socks5_proxy"
    case error
  }

  enum Health: Sendable {
    case running, starting, needsLogin, stopped, failed
  }

  var health: Health {
    if let e = error, !e.isEmpty { return .failed }
    switch state {
    case "Running": return .running
    case "Starting": return .starting
    case "NeedsLogin": return .needsLogin
    default: return .stopped
    }
  }

  var name: String { displayName.isEmpty ? profile : displayName }
}

enum StatusResult: Sendable {
  case ok([ProfileStatus])
  case daemonDown
  case failed(String)
}

enum CLI {
  /// Prefers the copy shipped inside the bundle so the app and the daemon are
  /// always the same build. No bare-name fallback: Finder's PATH lacks
  /// /opt/homebrew/bin, so it would only ever resolve to a confusing failure.
  static let path: String? = {
    if let bundled = Bundle.main.url(forResource: "tsmux", withExtension: nil)?.path,
      FileManager.default.isExecutableFile(atPath: bundled)
    {
      return bundled
    }
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    for candidate in ["/opt/homebrew/bin/tsmux", "/usr/local/bin/tsmux", "\(home)/go/bin/tsmux"]
    where FileManager.default.isExecutableFile(atPath: candidate) {
      return candidate
    }
    return nil
  }()

  @discardableResult
  /// `timeout: nil` for mutating subcommands (`pac apply`/`restore`): killing
  /// those mid-loop leaves the system proxy half-applied with no restore snapshot.
  static func run(_ args: [String], timeout: TimeInterval? = 4) -> (
    out: Data, err: String, status: Int32
  ) {
    guard let exe = path else { return (Data(), "tsmux CLI not found", -1) }
    let p = Process()
    p.executableURL = URL(fileURLWithPath: exe)
    p.arguments = args
    let outPipe = Pipe()
    let errPipe = Pipe()
    p.standardOutput = outPipe
    p.standardError = errPipe
    do {
      try p.run()
    } catch {
      return (Data(), (error as NSError).description, -1)
    }
    // A wedged daemon must never wedge the app.
    if let timeout {
      DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
        if p.isRunning { p.terminate() }
      }
    }

    let errQueue = DispatchQueue(label: "tsmux.stderr")
    var errData = Data()
    let done = DispatchSemaphore(value: 0)
    errQueue.async {
      errData = errPipe.fileHandleForReading.readDataToEndOfFile()
      done.signal()
    }
    let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
    done.wait()
    p.waitUntilExit()
    return (outData, String(data: errData, encoding: .utf8) ?? "", p.terminationStatus)
  }

  static func status() -> StatusResult {
    let (data, err, code) = run(["--json", "status"])
    if code == 0 {
      do {
        return .ok(try JSONDecoder().decode([ProfileStatus].self, from: data))
      } catch {
        return .failed(error.localizedDescription)
      }
    }
    if err.contains("daemon is not running") { return .daemonDown }
    let line = err.split(separator: "\n").first.map(String.init) ?? "tsmux exited with \(code)"
    return .failed(line)
  }
}

// MARK: - Controller

@MainActor
final class Controller: NSObject, NSMenuDelegate {
  private var item: NSStatusItem?
  private let menu = NSMenu()
  private var timer: Timer?

  private var status: StatusResult = .daemonDown
  private var daemon: Process?
  private var daemonErr: Pipe?
  private var daemonLog: [String] = []
  private var startDeadline: Date?
  private var crashLine: String?
  private var refreshing = false
  private var pacConfirmed = false
  private var expectingExit = false

  private static let pacKey = "pacApplied"
  private var pacApplied: Bool {
    get { UserDefaults.standard.bool(forKey: Self.pacKey) }
    set { UserDefaults.standard.set(newValue, forKey: Self.pacKey) }
  }

  private enum UIState {
    case cliMissing
    case down
    case starting
    case crashed(String)
    case failed(String)
    case ok([ProfileStatus])
  }

  private var ui: UIState {
    if CLI.path == nil { return .cliMissing }
    if startDeadline != nil { return .starting }
    switch status {
    case .ok(let ps): return .ok(ps)
    case .failed(let m): return .failed(m)
    case .daemonDown: return crashLine.map { .crashed($0) } ?? .down
    }
  }

  private var profiles: [ProfileStatus] {
    if case .ok(let ps) = ui { return ps }
    return []
  }

  private var weOwnDaemon: Bool { daemon?.isRunning == true }

  // MARK: launch

  func install() {
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
    updateIcon()
    refresh()
    scheduleTimer()
    if CLI.path == nil {
      alert("tsmux CLI not found", "TSMux could not find the tsmux executable to talk to.")
    }
  }

  // MARK: refresh

  private func scheduleTimer() {
    let interval: TimeInterval
    switch ui {
    case .starting: interval = 1
    case .ok(let ps): interval = ps.contains { $0.health == .needsLogin } ? 1 : 5
    default: interval = 15
    }
    if let t = timer, t.timeInterval == interval, t.isValid { return }
    timer?.invalidate()
    let t = Timer(timeInterval: interval, repeats: true) { _ in
      MainActor.assumeIsolated { self.refresh() }
    }
    t.tolerance = 1
    // .common so the badge keeps ticking while the menu is tracking.
    RunLoop.main.add(t, forMode: .common)
    timer = t
  }

  @objc private func refresh() {
    guard CLI.path != nil, !refreshing else { return }
    refreshing = true
    Task.detached(priority: .utility) {
      let next = CLI.status()
      await MainActor.run { self.apply(next) }
    }
  }

  private func apply(_ next: StatusResult) {
    refreshing = false
    status = next
    if case .ok = next {
      startDeadline = nil
      crashLine = nil
    } else if let deadline = startDeadline, Date() > deadline {
      startDeadline = nil
      if crashLine == nil {
        crashLine = daemonLog.last ?? "tsmux did not come up within 60 seconds"
      }
    }
    updateIcon()
    scheduleTimer()
  }

  // MARK: status item

  private func updateIcon() {
    guard let button = item?.button else { return }
    let ps = profiles
    let up = ps.filter { $0.health == .running }.count
    let total = ps.count

    let symbol: String
    let label: String
    var badge: String?
    var dimmed = false

    switch ui {
    case .ok:
      if ps.contains(where: { $0.health == .needsLogin }) {
        symbol = "exclamationmark.triangle.fill"
        badge = "\(up)/\(total)"
        label = "tsmux, \(ps.filter { $0.health == .needsLogin }.count) tailnets need login"
      } else if ps.contains(where: { $0.health == .failed }) {
        symbol = "exclamationmark.triangle.fill"
        badge = "\(up)/\(total)"
        label = "tsmux, \(ps.filter { $0.health == .failed }.count) tailnets have errors"
      } else {
        symbol = "point.3.filled.connected.trianglepath.dotted"
        if total > 1 { badge = "\(up)/\(total)" }
        label = "tsmux, \(up) of \(total) tailnets connected"
      }
    case .starting:
      symbol = "point.3.connected.trianglepath.dotted"
      badge = "…"
      label = "tsmux, starting"
    case .down:
      symbol = "point.3.connected.trianglepath.dotted"
      dimmed = true
      label = "tsmux, not running"
    case .failed, .crashed, .cliMissing:
      symbol = "exclamationmark.triangle.fill"
      label = "tsmux, can't read status"
    }

    let image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
      .withSymbolConfiguration(
        NSImage.SymbolConfiguration(pointSize: 15, weight: .medium, scale: .medium))
    image?.isTemplate = true
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

  // MARK: menu

  func menuWillOpen(_ menu: NSMenu) {
    rebuild()
    refresh()  // async; the result lands for the next open, never mutating a tracking menu
  }

  private func rebuild() {
    menu.removeAllItems()

    // 1. status / profile block
    switch ui {
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
        menu.addItem(action("No tailnets configured", #selector(openConfig)))
      } else {
        for p in ps { menu.addItem(profileItem(p)) }
      }
    }

    // 2. attention row
    if let p = profiles.first(where: { $0.health == .needsLogin }) {
      if let url = p.authURL, !url.isEmpty {
        let mi = action("Log in to \(p.name)…", #selector(openLogin(_:)))
        mi.representedObject = url
        menu.addItem(mi)
      } else {
        menu.addItem(disabled("Waiting for login link…"))
      }
    }

    menu.addItem(.separator())

    // 3. start / stop
    let running: Bool
    if case .ok = ui {
      running = true
    } else if case .starting = ui {
      running = true
    } else {
      running = false
    }
    if running {
      let mi = action(
        weOwnDaemon ? "Stop tsmux" : "Stop tsmux (started elsewhere)", #selector(stop))
      mi.isEnabled = weOwnDaemon
      menu.addItem(mi)
    } else {
      let mi = action("Start tsmux", #selector(start))
      mi.isEnabled = CLI.path != nil
      menu.addItem(mi)
    }

    // 4. PAC toggle, 5. copy PAC
    let anyUp = profiles.contains { $0.health == .running }
    let pac = action("Route System Traffic via tsmux", #selector(togglePAC))
    pac.state = pacApplied ? .on : .off
    pac.isEnabled = anyUp
    menu.addItem(pac)

    let copyPac = action("Copy PAC URL", #selector(copyPAC))
    copyPac.isEnabled = anyUp
    menu.addItem(copyPac)

    menu.addItem(.separator())

    // 6-8. fixed tail
    menu.addItem(action("Refresh", #selector(refresh), key: "r"))
    menu.addItem(action("Open Configuration…", #selector(openConfig), key: ","))
    menu.addItem(
      action(
        weOwnDaemon ? "Quit TSMux (stops tailnets)" : "Quit TSMux", #selector(quit), key: "q"))
  }

  private func profileItem(_ p: ProfileStatus) -> NSMenuItem {
    let (symbol, color, suffix) = Self.appearance(p.health, state: p.state)
    let top = NSMenuItem(title: "\(p.name) — \(suffix)", action: nil, keyEquivalent: "")
    top.target = self
    if p.health == .needsLogin, let url = p.authURL, !url.isEmpty {
      top.action = #selector(openLogin(_:))
      top.representedObject = url
    } else if let proxy = p.httpProxy, !proxy.isEmpty {
      top.action = #selector(copyValue(_:))
      top.representedObject = proxy
    }
    top.image = Self.statusImage(symbol, color)
    top.setAccessibilityLabel("\(p.name), \(suffix)")
    top.toolTip = p.error.map { "\(p.state): \($0)" } ?? p.state

    let sub = NSMenu()
    if let e = p.error, !e.isEmpty {
      let mi = action(
        "⚠︎ \(e.count > 80 ? String(e.prefix(79)) + "…" : e)", #selector(copyValue(_:)))
      mi.representedObject = e
      mi.toolTip = e
      sub.addItem(mi)
    }
    if p.health == .needsLogin, let url = p.authURL, !url.isEmpty {
      let mi = action("Log in to this tailnet…", #selector(openLogin(_:)))
      mi.representedObject = url
      sub.addItem(mi)
    }
    if sub.numberOfItems > 0 { sub.addItem(.separator()) }

    sub.addItem(disabled("profile: \(p.profile)"))
    if let n = p.selfName, !n.isEmpty {
      let mi = action(n.hasSuffix(".") ? String(n.dropLast()) : n, #selector(copyValue(_:)))
      mi.representedObject = mi.title
      sub.addItem(mi)
    }
    for ip in p.ips ?? [] {
      let mi = action(ip, #selector(copyValue(_:)))
      mi.representedObject = ip
      sub.addItem(mi)
    }
    sub.addItem(disabled("\(p.peers ?? 0) peers"))
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
    top.submenu = sub
    return top
  }

  private static func appearance(_ h: ProfileStatus.Health, state: String)
    -> (String, NSColor, String)
  {
    switch h {
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

  @objc private func start() {
    guard let exe = CLI.path else { return }
    if daemon?.isRunning == true { return }
    let p = Process()
    p.executableURL = URL(fileURLWithPath: exe)
    p.arguments = ["up"]
    p.standardOutput = FileHandle.nullDevice
    let errPipe = Pipe()
    p.standardError = errPipe
    errPipe.fileHandleForReading.readabilityHandler = { handle in
      let chunk = handle.availableData
      // EOF: the source otherwise fires forever on empty data and pegs a core.
      guard !chunk.isEmpty else {
        handle.readabilityHandler = nil
        return
      }
      guard let text = String(data: chunk, encoding: .utf8) else { return }
      Task { @MainActor in self.appendLog(text) }
    }
    p.terminationHandler = { proc in
      Task { @MainActor in self.daemonExited(status: proc.terminationStatus) }
    }
    do {
      try p.run()
    } catch {
      daemon = nil
      alert("Could not start tsmux", (error as NSError).localizedDescription)
      return
    }
    daemon = p
    daemonErr = errPipe
    daemonLog.removeAll()
    crashLine = nil
    startDeadline = Date().addingTimeInterval(60)
    updateIcon()
    scheduleTimer()
  }

  private func appendLog(_ text: String) {
    for line in text.split(separator: "\n") where !line.isEmpty {
      daemonLog.append(String(line))
    }
    if daemonLog.count > 200 { daemonLog.removeFirst(daemonLog.count - 200) }
  }

  private func daemonExited(status code: Int32) {
    daemon = nil
    startDeadline = nil
    daemonErr?.fileHandleForReading.readabilityHandler = nil
    daemonErr = nil
    if code != 0 && !expectingExit {
      crashLine = daemonLog.last ?? "tsmux exited with status \(code)"
    }
    expectingExit = false
    refresh()
  }

  @objc private func stop() {
    guard let d = daemon, d.isRunning else { return }
    if pacApplied { restorePAC(silent: false) }
    expectingExit = true
    d.terminate()
    daemon = nil
    startDeadline = nil
    DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
      MainActor.assumeIsolated { self.refresh() }
    }
  }

  @objc private func togglePAC() {
    if pacApplied {
      restorePAC(silent: false)
      return
    }
    if !pacConfirmed {
      let a = NSAlert()
      a.messageText = "Route system traffic through tsmux?"
      a.informativeText = "All system network traffic will be routed through tsmux."
      a.addButton(withTitle: "Route System Traffic")
      a.addButton(withTitle: "Cancel")
      NSApp.activate(ignoringOtherApps: true)
      guard a.runModal() == .alertFirstButtonReturn else { return }
      pacConfirmed = true
    }
    let (_, err, code) = CLI.run(["pac", "apply"], timeout: nil)
    if code == 0 {
      pacApplied = true
    } else {
      alert("Could not route system traffic", firstLine(err))
    }
  }

  private func restorePAC(silent: Bool) {
    let (_, err, code) = CLI.run(["pac", "restore"], timeout: nil)
    if code == 0 {
      pacApplied = false
    } else if !silent {
      alert("Could not restore the system proxy", firstLine(err))
    }
  }

  @objc private func copyPAC() {
    let (data, err, code) = CLI.run(["pac", "url"])
    guard code == 0,
      let url = String(data: data, encoding: .utf8)?
        .trimmingCharacters(in: .whitespacesAndNewlines), !url.isEmpty
    else {
      alert("Could not get the PAC URL", firstLine(err))
      return
    }
    copy(url)
  }

  @objc private func openLogin(_ sender: NSMenuItem) {
    guard let s = sender.representedObject as? String, let url = URL(string: s) else { return }
    if !NSWorkspace.shared.open(url) { alert("Could not open the login page", s) }
  }

  @objc private func copyValue(_ sender: NSMenuItem) {
    guard let s = sender.representedObject as? String else { return }
    copy(s)
  }

  @objc private func openConfig() {
    let base =
      ProcessInfo.processInfo.environment["XDG_CONFIG_HOME"].flatMap { $0.isEmpty ? nil : $0 }
      ?? ("~/.config" as NSString).expandingTildeInPath
    let dir = URL(fileURLWithPath: base).appendingPathComponent("tsmux")
    let file = dir.appendingPathComponent("config.yaml")
    if !FileManager.default.fileExists(atPath: file.path) {
      do {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Self.configTemplate.write(to: file, atomically: true, encoding: .utf8)
      } catch {
        alert(
          "Could not create the configuration file", "\(file.path)\n\n\(error.localizedDescription)"
        )
        return
      }
    }
    if !NSWorkspace.shared.open(file) {
      alert("Could not open the configuration file", file.path)
    }
  }

  private static let configTemplate = """
    # tsmux configuration
    #
    # Each profile is one tailnet. Ports must be unique across profiles.
    #
    # profiles:
    #   - name: work
    #     display_name: Work
    #     auth_key: tskey-auth-...
    #     http_port: 1080
    #     socks_port: 1081
    #     suffixes:
    #       - example.ts.net

    profiles: []
    """

  @objc private func quit() { NSApp.terminate(nil) }

  func shutdown() {
    timer?.invalidate()
    if pacApplied { restorePAC(silent: true) }
    guard let d = daemon, d.isRunning else { return }
    expectingExit = true
    d.terminate()
    let deadline = Date().addingTimeInterval(3)
    while d.isRunning && Date() < deadline { usleep(50_000) }
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

  private func firstLine(_ err: String) -> String {
    let line = err.split(separator: "\n").first.map(String.init) ?? ""
    return line.isEmpty ? "tsmux reported no details." : line
  }

  private func alert(_ title: String, _ info: String) {
    let a = NSAlert()
    a.messageText = title
    a.informativeText = info
    NSApp.activate(ignoringOtherApps: true)
    a.runModal()
  }
}

// MARK: - App

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
  let controller = Controller()

  // Documented ordering: the status item is created after launch finishes.
  func applicationDidFinishLaunching(_ notification: Notification) {
    controller.install()
  }

  func applicationWillTerminate(_ notification: Notification) {
    controller.shutdown()
  }
}

let app = NSApplication.shared
// Covers running the binary outside the .app bundle, where LSUIElement is absent.
app.setActivationPolicy(.accessory)
// NSApp holds its delegate weakly, so this global is what keeps it (and the
// status item it owns) alive for the process lifetime.
let delegate = MainActor.assumeIsolated { AppDelegate() }
app.delegate = delegate
app.run()
