import AppKit
import Foundation
import Observation

// ponytail: one shared AppModel, no view-model-per-tab.

enum UIState: Sendable {
  case cliMissing
  case down
  case starting
  case crashed(String)
  case failed(String)
  case ok([ProfileStatus])
}

enum ConfigState: Sendable, Equatable {
  case firstRun
  case configured
  case broken(String)
}

enum SettingsTab: String, Sendable, CaseIterable {
  case accounts, settings, about

  var title: String {
    switch self {
    case .accounts: return "Accounts"
    case .settings: return "Settings"
    case .about: return "About"
    }
  }
}

@MainActor @Observable
final class AppModel {
  var status: StatusResult = .daemonDown
  /// `profile list` — the YAML view. Needed for fields `/status` does not
  /// carry (match_root), and as the launch probe.
  var configProfiles: [Profile] = []

  /// What the UI lists. Falls back to the configured tailnets whenever the
  /// daemon has not reported yet, so "no tailnets" means the config is empty
  /// and never "the daemon is still starting".
  var displayProfiles: [ProfileStatus] {
    profiles.isEmpty ? configProfiles.map(ProfileStatus.placeholder) : profiles
  }
  var configState: ConfigState = .configured
  var startDeadline: Date?
  var crashLine: String?

  var selectedTab: SettingsTab = .accounts
  var selectedProfile: String?
  /// Bumped after any mutation so open sheets can re-read `profile list`.
  var profilesRevision = 0

  private var daemon: Process?
  private var daemonErr: Pipe?
  private var daemonLog: [String] = []
  private var refreshing = false
  private var expectingExit = false
  private var pacConfirmed = false
  /// Session-scoped by design: a fresh launch is a fresh statement of intent.
  private var stopLatch = false

  @ObservationIgnored var onChange: (() -> Void)?

  // MARK: defaults

  static let pacKey = "pacApplied"
  static let pacAutoKey = "pacAuto"
  static let hideDockKey = "hideDockIcon"
  static let connectAtLaunchKey = "connectAtLaunch"
  static let didShowFirstRunKey = "didShowFirstRun"

  var pacApplied: Bool {
    get { UserDefaults.standard.bool(forKey: Self.pacKey) }
    set {
      UserDefaults.standard.set(newValue, forKey: Self.pacKey)
      notify()
    }
  }

  var hideDockIcon: Bool {
    get { UserDefaults.standard.bool(forKey: Self.hideDockKey) }
    set {
      UserDefaults.standard.set(newValue, forKey: Self.hideDockKey)
      notify()
    }
  }

  var connectAtLaunch: Bool {
    get { UserDefaults.standard.object(forKey: Self.connectAtLaunchKey) as? Bool ?? true }
    set {
      UserDefaults.standard.set(newValue, forKey: Self.connectAtLaunchKey)
      notify()
    }
  }

  // MARK: derived

  var ui: UIState {
    if CLI.path == nil { return .cliMissing }
    if startDeadline != nil { return .starting }
    switch status {
    case .ok(let ps): return .ok(ps)
    case .failed(let m): return .failed(m)
    case .daemonDown: return crashLine.map { .crashed($0) } ?? .down
    }
  }

  var profiles: [ProfileStatus] {
    if case .ok(let ps) = ui { return ps }
    return []
  }

  var weOwnDaemon: Bool { daemon?.isRunning == true }

  var daemonRunning: Bool {
    switch ui {
    case .ok, .starting: return true
    default: return false
    }
  }

  var selection: ProfileStatus? {
    let list = displayProfiles
    return list.first { $0.profile == selectedProfile } ?? list.first
  }

  // MARK: launch

  /// Synchronous and cheap — `profile list` never starts tsnet or binds a port.
  func launchProbe() {
    reloadConfigProfiles()
    guard configState == .configured else { return }
    // A daemon already up (a terminal, or a second copy of the app) is adopted.
    if case .ok = CLI.status() {
      refresh()
      return
    }
    if connectAtLaunch { autoStart() }
  }

  func reloadConfigProfiles() {
    switch CLI.profileList() {
    case .success(let list):
      configProfiles = list
      configState = list.isEmpty ? .firstRun : .configured
    case .failure(let e):
      configState = .broken(e.message)
    }
    notify()
  }

  private func autoStart() {
    guard !stopLatch else { return }
    start()
  }

  // MARK: refresh

  func refresh() {
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
    if case .ok(let ps) = next {
      startDeadline = nil
      crashLine = nil
      // The product promise is that a tailnet name just resolves. Requiring a
      // menu click for that is the whole problem, so route by default once a
      // tailnet is actually up — and stop if the user ever turns it off.
      if pacAuto, !pacApplied, ps.contains(where: { $0.condition == .running }) {
        applyPAC(auto: true)
      }
    } else if let deadline = startDeadline, Date() > deadline {
      startDeadline = nil
      if crashLine == nil {
        crashLine = daemonLog.last ?? "tsmux did not come up within 60 seconds"
      }
    }
    notify()
  }

  private func notify() { onChange?() }

  // MARK: daemon lifecycle

  func start() {
    stopLatch = false
    startDaemon()
  }

  private func startDaemon() {
    guard let exe = CLI.path, daemon?.isRunning != true else { return }
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
      Alert.show("Could not start tsmux", (error as NSError).localizedDescription)
      return
    }
    daemon = p
    daemonErr = errPipe
    daemonLog.removeAll()
    crashLine = nil
    startDeadline = Date().addingTimeInterval(60)
    notify()
  }

  private func appendLog(_ text: String) {
    for line in text.split(separator: "\n") where !line.isEmpty {
      daemonLog.append(String(line))
    }
    if daemonLog.count > 200 { daemonLog.removeFirst(daemonLog.count - 200) }
  }

  var lastDaemonLine: String? { daemonLog.last }

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

  func stop() {
    stopLatch = true
    stopDaemon()
  }

  /// Stops whatever daemon is up, not just one we spawned: a daemon started
  /// from a terminal still holds the profiles, and refusing to act on it turns
  /// an ordinary "remove this tailnet" into an error the user cannot clear.
  private func stopDaemon() {
    if pacApplied { restorePAC(silent: false) }
    if let d = daemon, d.isRunning {
      expectingExit = true
      d.terminate()
      let deadline = Date().addingTimeInterval(5)
      while d.isRunning && Date() < deadline { usleep(50_000) }
    } else {
      _ = CLI.run(["down"], timeout: 10)
    }
    daemon = nil
    startDeadline = nil
    // The process being gone is not the same as the port being free; the CLI
    // refuses to mutate while /status still answers.
    let deadline = Date().addingTimeInterval(8)
    while Date() < deadline {
      if case .daemonDown = CLI.status() { break }
      usleep(100_000)
    }
    status = .daemonDown
    notify()
  }

  /// `profile add`/`rm` cannot run against a live daemon (D5), so bracket them.
  @discardableResult
  func mutateProfiles<T>(_ body: () -> T) -> T {
    // Any live daemon blocks the mutation, whether or not we started it.
    let wasRunning = daemonRunning
    let countBefore = configProfiles.count
    if wasRunning { stopDaemon() }
    let result = body()
    profilesRevision += 1
    reloadConfigProfiles()
    // Adding a tailnet is a fresh statement of intent; emptying the config is
    // the opposite — and `tsmux up` with zero profiles exits 1, which would
    // latch crashLine and report a crash the user caused by backing out.
    if configProfiles.count > countBefore {
      stopLatch = false
    } else if configProfiles.isEmpty {
      stopLatch = true
    }
    if configState == .configured, wasRunning || !stopLatch { startDaemon() }
    refresh()
    return result
  }

  // MARK: PAC

  /// Off by hand means off: an automatic re-apply on the next poll would be
  /// the app arguing with the user.
  var pacAuto: Bool {
    get { (UserDefaults.standard.object(forKey: Self.pacAutoKey) as? Bool) ?? true }
    set { UserDefaults.standard.set(newValue, forKey: Self.pacAutoKey) }
  }

  func togglePAC() {
    if pacApplied {
      pacAuto = false
      restorePAC(silent: false)
      return
    }
    pacAuto = true
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
    applyPAC(auto: false)
  }

  private func applyPAC(auto: Bool) {
    let (_, err, code) = CLI.run(["pac", "apply"], timeout: nil)
    if code == 0 {
      pacApplied = true
      notify()
    } else if !auto {
      Alert.show("Could not route system traffic", CLI.message(err))
    }
  }

  func restorePAC(silent: Bool) {
    let (_, err, code) = CLI.run(["pac", "restore"], timeout: nil)
    if code == 0 {
      pacApplied = false
    } else if !silent {
      Alert.show("Could not restore the system proxy", CLI.message(err))
    }
  }

  // MARK: per-profile prefs

  /// Optimistic-then-authoritative: the caller flips locally, we re-render from
  /// the Status the CLI hands back.
  @discardableResult
  func setPrefs(_ profile: String, _ flags: [String]) -> String? {
    switch CLI.json(ProfileStatus.self, ["profile", "set", profile] + flags, timeout: 15) {
    case .success(let fresh):
      replace(fresh)
      return nil
    case .failure(let e):
      refresh()
      return e.message
    }
  }

  @discardableResult
  func logout(_ profile: String) -> String? {
    switch CLI.json(ProfileStatus.self, ["profile", "logout", profile], timeout: 20) {
    case .success(let fresh):
      replace(fresh)
      return nil
    case .failure(let e):
      refresh()
      return e.message
    }
  }

  private func replace(_ fresh: ProfileStatus) {
    guard case .ok(var ps) = status else { return }
    if let i = ps.firstIndex(where: { $0.profile == fresh.profile }) {
      ps[i] = fresh
      status = .ok(ps)
      notify()
    }
  }

  // MARK: shutdown

  func shutdown() {
    if pacApplied { restorePAC(silent: true) }
    guard let d = daemon, d.isRunning else { return }
    expectingExit = true
    d.terminate()
    let deadline = Date().addingTimeInterval(3)
    while d.isRunning && Date() < deadline { usleep(50_000) }
  }
}

enum Alert {
  @MainActor
  static func show(_ title: String, _ info: String) {
    let a = NSAlert()
    a.messageText = title
    a.informativeText = info
    NSApp.activate(ignoringOtherApps: true)
    a.runModal()
  }
}
