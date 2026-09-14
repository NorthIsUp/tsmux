import AppKit
import SwiftUI

/// Three panes in one frame. The whole point of the flow: the user types a
/// name and nothing else — the DNS suffix is a result at the end, never input.
struct AddTailnetSheet: View {
  let model: AppModel
  @Environment(\.dismiss) private var dismiss

  private enum Pane {
    case name, bringingUp, connected
  }

  @State private var pane: Pane = .name
  @State private var display = ""
  @State private var keyOverride: String?
  @State private var controlURL = ""
  @State private var showAdvanced = false

  @State private var elapsed = 0
  @State private var headline = "Starting a Tailscale node for this tailnet."
  @State private var openedAuthURL: String?
  @State private var currentAuthURL = ""
  @State private var openFailed = false
  @State private var fatal: String?
  @State private var result: ProfileStatus?
  @State private var poller: Task<Void, Never>?

  private var key: String { keyOverride ?? Slug.key(display) }

  private var collision: Bool {
    model.configProfiles.contains { $0.name == key }
  }

  private var canAdd: Bool { !key.isEmpty && !collision }

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      switch pane {
      case .name: namePane
      case .bringingUp: bringingUpPane
      case .connected: connectedPane
      }
    }
    .padding(20)
    .frame(width: 460, height: 300)
    .onDisappear { poller?.cancel() }
  }

  // MARK: pane 1

  private var namePane: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("Add a tailnet").font(.headline)
      VStack(alignment: .leading, spacing: 4) {
        TextField("Work", text: $display)
          .textFieldStyle(.roundedBorder)
          .onChange(of: display) { keyOverride = nil }
        if key.isEmpty {
          Text("Enter a name using letters or numbers.")
            .font(.caption)
            .foregroundStyle(.secondary)
        } else if collision {
          HStack(spacing: 6) {
            Text("You already have a tailnet named '\(display)'.")
              .font(.caption)
              .foregroundStyle(.red)
            Button("Use \(Slug.bump(key))") { keyOverride = Slug.bump(key) }
              .buttonStyle(.link)
              .font(.caption)
          }
        } else {
          Text("profile: \(key)").font(.caption).foregroundStyle(.secondary)
        }
      }
      DisclosureGroup("Use a self-hosted control server", isExpanded: $showAdvanced) {
        VStack(alignment: .leading, spacing: 4) {
          TextField("https://headscale.example.com", text: $controlURL)
            .textFieldStyle(.roundedBorder)
            .accessibilityLabel("Control server URL")
          Text("For Headscale or another coordination server. Leave blank to use Tailscale.")
            .font(.caption).foregroundStyle(.secondary)
        }
        .padding(.top, 4)
      }
      Spacer()
      HStack {
        Spacer()
        Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
        Button("Add") { add() }
          .keyboardShortcut(.defaultAction)
          .disabled(!canAdd)
      }
    }
  }

  // MARK: pane 2

  private var bringingUpPane: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("Setting up \(display)").font(.headline)
      if let fatal {
        VStack(alignment: .leading, spacing: 10) {
          Label("tsmux couldn't start.", systemImage: "exclamationmark.triangle.fill")
            .foregroundStyle(.red)
          Text(fatal).font(.callout).foregroundStyle(.secondary)
          Spacer()
          HStack {
            Button("Run Diagnostics…") { runDoctor() }
            Spacer()
            Button("Remove Tailnet") { cancelSetup(force: true) }
          }
        }
      } else {
        HStack(spacing: 10) {
          ProgressView().controlSize(.small)
          Text(headline)
          Spacer()
          Text(timeString).font(.system(.caption, design: .monospaced))
            .foregroundStyle(.secondary)
            .monospacedDigit()
        }
        Text(
          "This takes about 30 seconds before the sign-in page can open.\n\n"
            + "You can leave this window open — we'll take you to your browser "
            + "when it's ready."
        )
        .font(.footnote)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
        if openFailed, !currentAuthURL.isEmpty {
          Text(currentAuthURL).font(.caption).textSelection(.enabled).lineLimit(2)
        }
        Spacer()
        HStack {
          Button("Open Sign-in Page Again") { openURLString(currentAuthURL) }
            .disabled(currentAuthURL.isEmpty)
          Button(openFailed ? "Copy Sign-in Link" : "Copy Link") { copy(currentAuthURL) }
            .disabled(currentAuthURL.isEmpty)
          Spacer()
          Button("Cancel") { cancelSetup(force: false) }
        }
      }
    }
  }

  private var timeString: String {
    String(format: "%d:%02d", elapsed / 60, elapsed % 60)
  }

  // MARK: pane 3

  private var connectedPane: some View {
    let suffix = result?.magicDNSSuffix ?? ""
    let proxy = result?.httpProxy ?? ""
    return VStack(alignment: .leading, spacing: 12) {
      Label("\(display) is connected", systemImage: "checkmark.circle.fill")
        .foregroundStyle(.green)
        .font(.headline)
      if suffix.isEmpty {
        Text(
          "We couldn't detect this tailnet's DNS suffix automatically, so hostnames "
            + "won't route yet. You can add one in Settings, or use this tailnet's "
            + "proxy directly at \(proxy)."
        )
        .fixedSize(horizontal: false, vertical: true)
      } else {
        Text("Anything ending in ")
          + Text(".\(suffix)").font(.system(.body, design: .monospaced))
          + Text(" now goes to this tailnet.")
      }
      Spacer()
      HStack {
        if suffix.isEmpty {
          Button("Copy Proxy Address") { copy(proxy) }
        } else {
          if !model.pacApplied {
            Button("Route System Traffic") { model.togglePAC() }
          }
          Button("Copy PAC URL") { copy(CLI.pacURL() ?? "") }
        }
        Spacer()
        Button("Done") { dismiss() }
          .keyboardShortcut(.defaultAction)
          .buttonStyle(.borderedProminent)
      }
    }
  }

  // MARK: actions

  private func add() {
    var args = ["profile", "add", key, "--display-name", display]
    if !controlURL.trimmingCharacters(in: .whitespaces).isEmpty {
      args += ["--control-url", controlURL.trimmingCharacters(in: .whitespaces)]
    }
    // D13: bare hostnames go to the only tailnet there is, and no further.
    if model.configProfiles.isEmpty { args.append("--match-root") }

    pane = .bringingUp
    let outcome = model.mutateProfiles { CLI.json(Profile.self, args, timeout: 20) }
    if case .failure(let e) = outcome {
      fatal = e.message
      return
    }
    poll()
  }

  private func poll() {
    poller?.cancel()
    poller = Task { @MainActor in
      while !Task.isCancelled {
        try? await Task.sleep(for: .seconds(1))
        if Task.isCancelled { return }
        elapsed += 1
        model.refresh()
        guard let p = model.profiles.first(where: { $0.profile == key }) else {
          // Copy staged from real signals only; a missing profile is just
          // "the daemon has not published it yet".
          if elapsed >= 45 { headline = Self.slowCopy }
          continue
        }
        advance(p)
        if p.condition == .running {
          result = p
          pane = .connected
          return
        }
      }
    }
  }

  private static let slowCopy =
    "This is taking longer than usual. Check that you're online — tsmux needs "
    + "to reach the coordination server."

  private func advance(_ p: ProfileStatus) {
    let auth = p.authURL ?? ""
    if !auth.isEmpty {
      headline = "Opening your browser to sign in."
      currentAuthURL = auth
      // Latch on the URL: the same link must not open a second tab, but a
      // different one is a genuine re-registration.
      if openedAuthURL != auth {
        openedAuthURL = auth
        openFailed = !(URL(string: auth).map { NSWorkspace.shared.open($0) } ?? false)
      }
      return
    }
    switch p.condition {
    case .needsLogin: headline = "Almost there — waiting for a sign-in link."
    default: headline = "Connecting to the coordination server."
    }
    if elapsed >= 45 { headline = Self.slowCopy }
  }

  private func cancelSetup(force: Bool) {
    poller?.cancel()
    if openedAuthURL != nil && !force {
      let a = NSAlert()
      a.messageText = "Stop setting up \(display)?"
      a.informativeText =
        "If you already signed in, this tailnet will be removed and you'll need "
        + "to sign in again next time."
      a.addButton(withTitle: "Keep Setting Up")
      a.addButton(withTitle: "Remove")
      guard a.runModal() == .alertSecondButtonReturn else {
        poll()
        return
      }
    }
    model.mutateProfiles { CLI.run(["--json", "profile", "rm", key, "--purge"], timeout: 20) }
    dismiss()
  }

  private func runDoctor() {
    let (data, err, code) = CLI.run(["--json", "doctor"], timeout: 30)
    if let report = try? JSONDecoder().decode(DoctorReport.self, from: data) {
      let problems = report.problems ?? []
      Alert.show(
        problems.isEmpty ? "No problems found" : "\(problems.count) problem(s) found",
        ([report.config] + problems).joined(separator: "\n\n"))
      return
    }
    Alert.show("Diagnostics failed", code == 0 ? "tsmux produced no report." : CLI.message(err))
  }

  private func copy(_ s: String) {
    guard !s.isEmpty else { return }
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(s, forType: .string)
  }
}
