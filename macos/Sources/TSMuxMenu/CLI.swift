import Foundation

// Everything the GUI knows comes from `tsmux --json`, so the two stay in step
// without a second config parser. Swift never speaks HTTP to the daemon.

// MARK: - Wire model

struct ExitNodeOption: Decodable, Sendable, Identifiable, Hashable {
  let id: String
  let name: String
  let hostname: String
  let online: Bool
  let current: Bool
}

/// One peer in a tailnet. `owner` is empty for tagged nodes — those group
/// under their tag instead, the way the admin console presents them.
struct Device: Decodable, Sendable, Identifiable, Hashable {
  let name: String
  let hostname: String
  let ips: [String]?
  let os: String?
  let owner: String?
  let tags: [String]?
  let online: Bool
  let exitNode: Bool?

  var id: String { name }

  enum CodingKeys: String, CodingKey {
    case name, hostname, ips, os, owner, tags, online
    case exitNode = "exit_node"
  }

  /// What a plain click copies: something you can paste into a browser.
  var url: String { "https://\(name)" }
  var primaryIP: String? { ips?.first }
  /// The short name, which is what you type at a shell.
  var shortName: String {
    hostname.isEmpty ? String(name.split(separator: ".").first ?? "") : hostname
  }

  /// Group heading this device belongs under.
  var group: String {
    if let t = tags?.first, !t.isEmpty { return t }
    if let o = owner, !o.isEmpty { return o }
    return "Other"
  }
}

struct ProfilePrefs: Decodable, Sendable, Hashable {
  /// This tailnet's own on/off state, independent of the others.
  let connected: Bool
  let acceptRoutes: Bool
  let acceptDNS: Bool
  let shieldsUp: Bool
  let exitNode: String
  let exitNodeAllowLAN: Bool

  enum CodingKeys: String, CodingKey {
    case connected
    case acceptRoutes = "accept_routes"
    case acceptDNS = "accept_dns"
    case shieldsUp = "shields_up"
    case exitNode = "exit_node"
    case exitNodeAllowLAN = "exit_node_allow_lan"
  }
}

struct UserProfile: Decodable, Sendable, Hashable {
  let loginName: String
  let displayName: String?
  let avatarURL: String?

  enum CodingKeys: String, CodingKey {
    case loginName = "login_name"
    case displayName = "display_name"
    case avatarURL = "avatar_url"
  }
}

struct ProfileStatus: Decodable, Sendable, Identifiable {
  let profile: String
  let displayName: String
  let state: String
  let selfName: String?
  let deviceName: String?
  let ips: [String]?
  let peers: Int?
  let authURL: String?
  let suffixes: [String]?
  let httpProxy: String?
  let socks5Proxy: String?
  let error: String?

  let tailnet: String?
  let magicDNSSuffix: String?
  let suffixConflict: String?
  let user: UserProfile?
  let keyExpiry: String?
  let connectedSince: String?
  let healthMessages: [String]?
  let adminURL: String?
  let prefs: ProfilePrefs?
  let exitNodeOptions: [ExitNodeOption]?
  let devices: [Device]?

  enum CodingKeys: String, CodingKey {
    case profile
    case displayName = "display_name"
    case state
    case selfName = "self"
    case deviceName = "device_name"
    case ips
    case peers
    case authURL = "auth_url"
    case suffixes
    case httpProxy = "http_proxy"
    case socks5Proxy = "socks5_proxy"
    case error
    case tailnet
    case magicDNSSuffix = "magic_dns_suffix"
    case suffixConflict = "suffix_conflict"
    case user
    case keyExpiry = "key_expiry"
    case connectedSince = "connected_since"
    case healthMessages = "health"
    case adminURL = "admin_url"
    case prefs
    case exitNodeOptions = "exit_node_options"
    case devices
  }

  var id: String { profile }

  enum Condition: Sendable {
    case running, starting, needsLogin, stopped, failed
  }

  var condition: Condition {
    if let e = error, !e.isEmpty { return .failed }
    switch state {
    case "Running": return .running
    case "Starting": return .starting
    case "NeedsLogin":
      // An already-authenticated node reports NeedsLogin on every daemon start
      // until its saved state loads, and a brand-new one sits here for ~25s
      // before the control server issues a link. Neither is the user's problem
      // to act on, so only an actual link means "needs login".
      return authURL?.isEmpty == false ? .needsLogin : .starting
    default: return .stopped
    }
  }

  var name: String { displayName.isEmpty ? profile : displayName }

  /// How long this tailnet has been connected, compactly. Nil when it isn't —
  /// a tailnet that is down has no uptime, and "0s" would imply otherwise.
  var uptime: String? {
    guard let raw = connectedSince, !raw.isEmpty else { return nil }
    let iso = ISO8601DateFormatter()
    iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    let since = iso.date(from: raw) ?? ISO8601DateFormatter().date(from: raw)
    guard let since else { return nil }
    let secs = max(0, Int(Date().timeIntervalSince(since)))
    switch secs {
    case ..<60: return "\(secs)s"
    case ..<3600: return "\(secs / 60)m"
    case ..<86400:
      let h = secs / 3600
      let m = (secs % 3600) / 60
      return m == 0 ? "\(h)h" : "\(h)h \(m)m"
    default:
      let d = secs / 86400
      let h = (secs % 86400) / 3600
      return h == 0 ? "\(d)d" : "\(d)d \(h)h"
    }
  }

  /// A configured-but-not-yet-reported tailnet. The config is the truth about
  /// which tailnets exist; the daemon is only the truth about how they are
  /// doing. Without this the UI claims you have none while it is starting.
  static func placeholder(_ p: Profile) -> ProfileStatus {
    ProfileStatus(
      profile: p.name, displayName: p.displayName, state: "Stopped",
      selfName: nil, deviceName: p.hostname, ips: nil, peers: 0, authURL: nil,
      suffixes: p.suffixes, httpProxy: "127.0.0.1:\(p.httpProxyPort)",
      socks5Proxy: "127.0.0.1:\(p.socks5ProxyPort)", error: nil,
      tailnet: nil, magicDNSSuffix: nil, suffixConflict: nil, user: nil,
      keyExpiry: nil, connectedSince: nil, healthMessages: nil, adminURL: nil, prefs: nil,
      exitNodeOptions: nil, devices: nil)
  }

  /// `self` keeps the wire's trailing dot; nothing user-facing wants it.
  var machineName: String? {
    guard let n = selfName, !n.isEmpty else { return nil }
    return n.hasSuffix(".") ? String(n.dropLast()) : n
  }

  var expiryDate: Date? {
    guard let s = keyExpiry, !s.isEmpty else { return nil }
    return ISO8601DateFormatter().date(from: s)
  }

  /// Suffixes beyond the one learned from the tailnet itself.
  var extraSuffixes: [String] {
    let learned = magicDNSSuffix.map { "." + $0.lowercased() } ?? ""
    return (suffixes ?? []).filter { $0.lowercased() != learned }
  }
}

struct Profile: Decodable, Sendable, Identifiable {
  let name: String
  let displayName: String
  let hostname: String
  let controlURL: String
  let acceptRoutes: Bool
  let suffixes: [String]?
  let matchRoot: Bool
  let ipRoutes: [String]?
  let httpProxyPort: Int
  let socks5ProxyPort: Int

  enum CodingKeys: String, CodingKey {
    case name
    case displayName = "display_name"
    case hostname
    case controlURL = "control_url"
    case acceptRoutes = "accept_routes"
    case suffixes
    case matchRoot = "match_root"
    case ipRoutes = "ip_routes"
    case httpProxyPort = "http_proxy_port"
    case socks5ProxyPort = "socks5_proxy_port"
  }

  var id: String { name }
}

struct RemovedProfile: Decodable, Sendable {
  let removed: String
  let purged: Bool
}

struct DoctorReport: Decodable, Sendable {
  let config: String
  let problems: [String]?
}

struct VersionInfo: Decodable, Sendable {
  let version: String?
}

/// The contract's whole error surface: stderr's last line, `tsmux: ` stripped.
struct CLIError: Error, Sendable {
  let message: String
}

enum StatusResult: Sendable {
  case ok([ProfileStatus])
  case daemonDown
  case failed(String)
}

// MARK: - Runner

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

  /// Contract: on failure stderr's last non-empty line is the message, prefixed `tsmux: `.
  static func message(_ err: String) -> String {
    let line =
      err.split(separator: "\n")
      .map { $0.trimmingCharacters(in: .whitespaces) }
      .last(where: { !$0.isEmpty }) ?? ""
    if line.isEmpty { return "tsmux reported no details." }
    return line.hasPrefix("tsmux: ") ? String(line.dropFirst("tsmux: ".count)) : line
  }

  static func json<T: Decodable>(
    _ type: T.Type, _ args: [String], timeout: TimeInterval? = 4
  ) -> Result<T, CLIError> {
    let (data, err, code) = run(["--json"] + args, timeout: timeout)
    guard code == 0 else { return .failure(CLIError(message: message(err))) }
    do {
      return .success(try JSONDecoder().decode(T.self, from: data))
    } catch {
      return .failure(
        CLIError(message: "unreadable output from tsmux: \(error.localizedDescription)"))
    }
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
    return .failed(message(err))
  }

  /// The launch probe: no tsnet, no ports, ~15ms. `[]` means first run.
  static func profileList() -> Result<[Profile], CLIError> {
    json([Profile].self, ["profile", "list"])
  }

  static func pacURL() -> String? {
    let (data, _, code) = run(["pac", "url"])
    guard code == 0 else { return nil }
    let s = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
    return (s?.isEmpty == false) ? s : nil
  }
}

// MARK: - Profile key derivation

enum Slug {
  /// The config key derived from a display name. `nameRE` on the Go side needs
  /// at least two characters, hence the `-1` tail on a single-character result.
  static func key(_ display: String) -> String {
    let folded = display.folding(
      options: [.diacriticInsensitive, .widthInsensitive, .caseInsensitive], locale: .current)
    var out = ""
    for scalar in folded.unicodeScalars {
      let ch = Character(scalar)
      if scalar.isASCII, ch.isLetter || ch.isNumber {
        out.append(ch)
      } else if !out.isEmpty, !out.hasSuffix("-") {
        out.append("-")
      }
    }
    while out.hasSuffix("-") { out.removeLast() }
    if out.count > 32 {
      out = String(out.prefix(32))
      while out.hasSuffix("-") { out.removeLast() }
    }
    if out.count == 1 { out += "-1" }
    return out
  }

  /// `work` → `work-2` → `work-3`; only the key moves, never the display name.
  static func bump(_ key: String) -> String {
    guard let dash = key.lastIndex(of: "-"), let n = Int(key[key.index(after: dash)...]) else {
      return key + "-2"
    }
    return key[..<dash] + "-\(n + 1)"
  }

  static func selfCheck() -> Bool {
    key("Work") == "work" && key("My Tailnet!") == "my-tailnet" && key("Café") == "cafe"
      && key("🎉") == "" && key("X") == "x-1" && bump("work") == "work-2"
      && bump("work-2") == "work-3"
  }
}
