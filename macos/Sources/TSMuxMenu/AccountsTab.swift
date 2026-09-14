import AppKit
import SwiftUI

struct AccountsTab: View {
  let model: AppModel
  @Binding var showAdd: Bool

  @State private var showRemove = false
  @State private var showDNS = false

  var body: some View {
    Group {
      if model.profiles.isEmpty {
        emptyState
      } else {
        split
      }
    }
    .sheet(isPresented: $showAdd) { AddTailnetSheet(model: model) }
    .sheet(isPresented: $showRemove) {
      if let p = model.selection { RemoveTailnetSheet(model: model, profile: p) }
    }
    .sheet(isPresented: $showDNS) {
      if let p = model.selection { DNSSheet(model: model, profile: p) }
    }
  }

  private var emptyState: some View {
    VStack(spacing: 14) {
      Image(systemName: "point.3.connected.trianglepath.dotted")
        .font(.system(size: 44))
        .foregroundStyle(.secondary)
      Text("No tailnets yet").font(.title2).bold()
      Text(
        "tsmux runs every tailnet at once. Add your first one — you only need a name."
      )
      .foregroundStyle(.secondary)
      .multilineTextAlignment(.center)
      .frame(maxWidth: 360)
      Button("Set up your first tailnet…") { showAdd = true }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }

  private var split: some View {
    NavigationSplitView {
      sidebar
        .navigationSplitViewColumnWidth(min: 200, ideal: 230, max: 260)
    } detail: {
      if let p = model.selection {
        AccountDetail(
          model: model, profile: p, showRemove: $showRemove, showDNS: $showDNS)
      } else {
        Text("Select a tailnet").foregroundStyle(.secondary)
      }
    }
  }

  private var sidebar: some View {
    VStack(spacing: 0) {
      List(selection: selectionBinding) {
        Section {
          ForEach(model.profiles) { p in
            row(p).tag(p.profile)
          }
        } header: {
          VStack(alignment: .leading, spacing: 1) {
            Text("Tailnets")
            // The whole adaptation from Tailscale in one line: selection here
            // inspects, it does not switch.
            Text(connectedSummary).font(.caption).foregroundStyle(.secondary)
          }
        }
      }
      Divider()
      HStack(spacing: 2) {
        Button {
          showAdd = true
        } label: {
          Image(systemName: "plus")
        }
        .help("Add a tailnet")
        .accessibilityLabel("Add a tailnet")
        Button {
          showRemove = true
        } label: {
          Image(systemName: "minus")
        }
        .help("Remove the selected tailnet")
        .accessibilityLabel("Remove the selected tailnet")
        .disabled(model.selection == nil)
        Spacer()
      }
      .buttonStyle(.borderless)
      .padding(.horizontal, 8)
      .padding(.vertical, 5)
    }
  }

  private var connectedSummary: String {
    let up = model.profiles.filter { $0.condition == .running }.count
    if up == 0 { return "none connected yet" }
    return up == model.profiles.count && up > 1
      ? "\(up) connected, all at once" : "\(up) of \(model.profiles.count) connected"
  }

  private var selectionBinding: Binding<String?> {
    Binding(
      get: { model.selection?.profile },
      set: { model.selectedProfile = $0 })
  }

  private func row(_ p: ProfileStatus) -> some View {
    HStack(spacing: 8) {
      InitialsAvatar(name: p.name)
      VStack(alignment: .leading, spacing: 1) {
        Text(p.name).lineLimit(1)
        Text(p.user?.loginName ?? "not signed in")
          .font(.caption)
          .foregroundStyle(.secondary)
          .lineLimit(1)
        if model.profiles.count > 1, let proxy = p.httpProxy,
          let port = proxy.split(separator: ":")
            .last
        {
          Text("proxy :\(port)").font(.caption2).foregroundStyle(.tertiary)
        }
      }
      Spacer(minLength: 4)
      StatusDot(condition: p.condition)
    }
    .padding(.vertical, 2)
  }
}

struct AccountDetail: View {
  let model: AppModel
  let profile: ProfileStatus
  @Binding var showRemove: Bool
  @Binding var showDNS: Bool

  @State private var inlineError: String?

  var body: some View {
    Form {
      if let conflict = profile.suffixConflict, !conflict.isEmpty {
        Section { conflictBanner(conflict) }
      }
      if let msg = inlineError {
        Section {
          Label(msg, systemImage: "exclamationmark.triangle.fill")
            .foregroundStyle(.red)
            .font(.callout)
        }
      }
      if profile.condition == .needsLogin {
        Section {
          VStack(alignment: .leading, spacing: 8) {
            Text("This tailnet needs you to sign in.")
            Button("Log In…") { openURLString(profile.authURL ?? "") }
              .buttonStyle(.borderedProminent)
              .disabled((profile.authURL ?? "").isEmpty)
            if (profile.authURL ?? "").isEmpty {
              Text("Waiting for a sign-in link…").font(.footnote).foregroundStyle(.secondary)
            }
          }
        }
      } else {
        identity
      }
      routing
      connection
      account
    }
    .formStyle(.grouped)
  }

  // MARK: identity

  @ViewBuilder private var identity: some View {
    Section("Identity") {
      LabeledContent("Tailnet") {
        VStack(alignment: .trailing, spacing: 1) {
          Text(profile.tailnet ?? "—")
          if let s = profile.magicDNSSuffix, !s.isEmpty {
            Text(s).font(.caption).foregroundStyle(.secondary)
          }
        }
      }
      LabeledContent("Email", value: profile.user?.loginName ?? "—")
      LabeledContent("Status") {
        VStack(alignment: .trailing, spacing: 2) {
          HStack(spacing: 6) {
            StatusDot(condition: profile.condition)
            Text(profile.condition.label)
          }
          ForEach(profile.healthMessages ?? [], id: \.self) { h in
            Text(h).font(.caption).foregroundStyle(.red)
          }
          if let e = profile.error, !e.isEmpty {
            Text(e).font(.caption).foregroundStyle(.red)
          }
        }
      }
      if let machine = profile.machineName {
        LabeledContent("Machine") { CopyableValue(value: machine) }
      }
      if let ips = profile.ips, !ips.isEmpty {
        LabeledContent("Addresses") {
          VStack(alignment: .trailing, spacing: 2) {
            ForEach(ips, id: \.self) { CopyableValue(value: $0, monospaced: true) }
          }
        }
      }
      if let expiry = profile.expiryDate {
        LabeledContent("Expiry") {
          HStack(spacing: 8) {
            Text(Self.expiryText(expiry))
            if let admin = profile.adminURL, !admin.isEmpty {
              Button("Renew…") { openURLString(admin) }
            }
          }
        }
      }
    }
  }

  static func expiryText(_ date: Date) -> String {
    let f = RelativeDateTimeFormatter()
    f.unitsStyle = .full
    return date < Date()
      ? "Expired \(f.localizedString(for: date, relativeTo: Date()))"
      : "Expires \(f.localizedString(for: date, relativeTo: Date()))"
  }

  // MARK: routing

  @ViewBuilder private var routing: some View {
    Section("Routing (tsmux)") {
      LabeledContent("Search domain") {
        if let s = profile.magicDNSSuffix, !s.isEmpty {
          CopyableValue(value: s, monospaced: true)
        } else {
          Text("learned automatically after sign-in").foregroundStyle(.secondary)
        }
      }
      LabeledContent("Extra suffixes") {
        HStack(spacing: 8) {
          Text(
            profile.extraSuffixes.isEmpty
              ? "none" : profile.extraSuffixes.joined(separator: " ")
          )
          .foregroundStyle(.secondary)
          .lineLimit(1)
          .truncationMode(.middle)
          Button("Manage…") { showDNS = true }
        }
      }
      LabeledContent("HTTP proxy") { CopyableValue(value: profile.httpProxy ?? "—") }
      LabeledContent("SOCKS5 proxy") { CopyableValue(value: profile.socks5Proxy ?? "—") }
      // Read-only: the contract has no `profile set --match-root`, and Swift
      // never writes config.yaml behind the daemon's back.
      VStack(alignment: .leading, spacing: 3) {
        Toggle("Claim bare hostnames", isOn: .constant(claimsRoot))
          .disabled(true)
        Text(
          otherRootClaimer.map { "Bare names already go to \($0)." }
            ?? "Sends single-word names like `db` to this tailnet. "
            + "Set when the tailnet is added."
        )
        .font(.footnote)
        .foregroundStyle(.secondary)
      }
    }
  }

  private var configEntry: Profile? {
    model.configProfiles.first { $0.name == profile.profile }
  }

  private var claimsRoot: Bool { configEntry?.matchRoot ?? false }

  private var otherRootClaimer: String? {
    guard !claimsRoot else { return nil }
    return model.configProfiles.first { $0.name != profile.profile && $0.matchRoot }?.displayName
  }

  private func conflictBanner(_ other: String) -> some View {
    let suffix = profile.magicDNSSuffix ?? "this tailnet"
    let port = (profile.httpProxy ?? "").split(separator: ":").last.map(String.init) ?? "its port"
    return Label {
      Text(
        "This tailnet's names (\(suffix)) are already routed to **\(other)**. "
          + "Traffic for those hosts uses that profile; this one is still reachable "
          + "on its own proxy port \(port)."
      )
      .fixedSize(horizontal: false, vertical: true)
    } icon: {
      Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
    }
    .font(.callout)
  }

  // MARK: connection

  @ViewBuilder private var connection: some View {
    Section("Connection") {
      Toggle(
        "Allow incoming connections", isOn: pref(\.shieldsUp, invert: true, flag: "shields-up"))
      Toggle("Use Tailscale DNS", isOn: pref(\.acceptDNS, flag: "accept-dns"))
      Toggle("Use Tailscale subnets", isOn: pref(\.acceptRoutes, flag: "accept-routes"))
      Picker("Exit node", selection: exitNodeBinding) {
        Text("None").tag("")
        ForEach(profile.exitNodeOptions ?? []) { opt in
          Text(opt.online ? opt.hostname : "\(opt.hostname) (offline)").tag(opt.id)
        }
      }
      .pickerStyle(.menu)
      Toggle("Allow local network access", isOn: pref(\.exitNodeAllowLAN, flag: "exit-node-lan"))
        .disabled(profile.prefs?.exitNode.isEmpty ?? true)
    }
    .disabled(profile.prefs == nil)
  }

  /// Optimistic-then-authoritative: SwiftUI redraws from the returned Status,
  /// so a rejected write simply snaps back with the reason inline.
  private func pref(
    _ key: KeyPath<ProfilePrefs, Bool>, invert: Bool = false, flag: String
  ) -> Binding<Bool> {
    Binding(
      get: {
        guard let p = profile.prefs else { return false }
        return invert ? !p[keyPath: key] : p[keyPath: key]
      },
      set: { on in
        let wire = invert ? !on : on
        inlineError = model.setPrefs(profile.profile, ["--\(flag)=\(wire)"])
      })
  }

  private var exitNodeBinding: Binding<String> {
    Binding(
      get: { profile.prefs?.exitNode ?? "" },
      set: { inlineError = model.setPrefs(profile.profile, ["--exit-node", $0]) })
  }

  // MARK: account

  @ViewBuilder private var account: some View {
    Section("Account") {
      HStack {
        Button("Log Out", role: .destructive) {
          inlineError = model.logout(profile.profile)
        }
        if let admin = profile.adminURL, !admin.isEmpty {
          Button("Admin Console…") { openURLString(admin) }
        }
        Spacer()
        Button("Remove Tailnet…") { showRemove = true }
      }
    }
  }
}
