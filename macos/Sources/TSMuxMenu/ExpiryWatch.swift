import Foundation

/// A node key cannot be renewed unattended — renewing it means signing in again
/// in a browser — so the most a tool can do is make sure the deadline is never
/// a surprise. This is the weekly check: a LaunchAgent running
/// `tsmux expiry --notify`, which posts a notification only when something is
/// inside the warning window.
///
/// Opt-in and reversible, the way `pac apply` / `pac restore` are: nothing is
/// written to ~/Library/LaunchAgents until the user turns it on, and turning it
/// off removes the file.
enum ExpiryWatch {
  /// Days of notice. Matches the CLI's own default, so the menu and the weekly
  /// notification agree about what "soon" means.
  static let warnDays = 21

  static let label = "dev.northisup.tsmux.expiry"

  static var plistURL: URL {
    FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent("Library/LaunchAgents/\(label).plist")
  }

  static var isInstalled: Bool {
    FileManager.default.fileExists(atPath: plistURL.path)
  }

  /// Sunday at 10am local. A weekday morning would land mid-meeting; a small
  /// fixed time also means every install agrees, which makes it debuggable.
  private static var plist: [String: Any] {
    [
      "Label": label,
      "ProgramArguments": [CLI.path ?? "tsmux", "expiry", "--notify"],
      "StartCalendarInterval": ["Weekday": 0, "Hour": 10, "Minute": 0],
      "RunAtLoad": false,
      "ProcessType": "Background",
    ]
  }

  static func install() throws {
    guard CLI.path != nil else {
      throw CLIError(message: "tsmux CLI not found")
    }
    let url = plistURL
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    let data = try PropertyListSerialization.data(
      fromPropertyList: plist, format: .xml, options: 0)
    try data.write(to: url, options: .atomic)
    // An install over a previous one has to unload first or launchctl keeps
    // running the old plist.
    launchctl("bootout")
    if let err = launchctl("bootstrap") {
      try? FileManager.default.removeItem(at: url)
      throw CLIError(message: err)
    }
  }

  static func remove() throws {
    launchctl("bootout")
    if FileManager.default.fileExists(atPath: plistURL.path) {
      try FileManager.default.removeItem(at: plistURL)
    }
  }

  /// Runs the check now, in the same process the LaunchAgent would use, so the
  /// notification a user sees from the menu is the one they get weekly.
  static func checkNow() {
    guard CLI.path != nil else { return }
    let p = Process()
    p.executableURL = URL(fileURLWithPath: CLI.path!)
    p.arguments = ["expiry", "--notify"]
    p.standardOutput = FileHandle.nullDevice
    p.standardError = FileHandle.nullDevice
    try? p.run()
  }

  @discardableResult
  private static func launchctl(_ verb: String) -> String? {
    let domain = "gui/\(getuid())"
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/bin/launchctl")
    p.arguments = verb == "bootout" ? [verb, "\(domain)/\(label)"] : [verb, domain, plistURL.path]
    let err = Pipe()
    p.standardError = err
    p.standardOutput = FileHandle.nullDevice
    do {
      try p.run()
    } catch {
      return (error as NSError).localizedDescription
    }
    let data = err.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    guard p.terminationStatus != 0 else { return nil }
    let msg = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    return msg.isEmpty ? "launchctl \(verb) failed (\(p.terminationStatus))" : msg
  }
}
