import AppKit
import ServiceManagement
import SwiftUI

/// Per-profile rows appear here as read-only fleet summaries with a jump
/// button, never as editable aggregates: one place to edit, plus the
/// cross-tailnet view Tailscale cannot have.
struct GlobalSettingsTab: View {
  let model: AppModel

  @State private var showCLI = false
  @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
  @State private var pacURL: String = ""

  var body: some View {
    Form {
      general
      networkRouting
      window
      Section("VPN On Demand") {
        UnavailableRow(
          title: "On Demand", note: Unavailable.vpnOnDemand,
          control: AnyView(Button("Manage…") {}))
      }
      exitNodes
      Section("Tailnet Lock") {
        UnavailableRow(
          title: "Tailnet Lock", note: Unavailable.tailnetLock,
          control: AnyView(Button("Manage…") {}))
      }
      Section("CLI integration") {
        LabeledContent("Command line") {
          Button("Show me how") { showCLI = true }
        }
      }
    }
    .formStyle(.grouped)
    .sheet(isPresented: $showCLI) { CLIIntegrationSheet() }
    .task { pacURL = CLI.pacURL() ?? "" }
  }

  // MARK: general

  @ViewBuilder private var general: some View {
    Section("General") {
      fleetRow("Allow incoming connections") { !($0.prefs?.shieldsUp ?? true) }
      fleetRow("Use Tailscale DNS") { $0.prefs?.acceptDNS ?? false }
      fleetRow("Use Tailscale subnets") { $0.prefs?.acceptRoutes ?? false }
      Toggle("Launch TSMux at login", isOn: launchBinding)
      Toggle("Connect tailnets at launch", isOn: connectBinding)
    }
  }

  private var launchBinding: Binding<Bool> {
    Binding(
      get: { launchAtLogin },
      set: { on in
        do {
          if on {
            try SMAppService.mainApp.register()
          } else {
            try SMAppService.mainApp.unregister()
          }
          launchAtLogin = SMAppService.mainApp.status == .enabled
        } catch {
          Alert.show("Could not change the login item", error.localizedDescription)
          launchAtLogin = SMAppService.mainApp.status == .enabled
        }
      })
  }

  private var connectBinding: Binding<Bool> {
    Binding(get: { model.connectAtLaunch }, set: { model.connectAtLaunch = $0 })
  }

  // MARK: network routing

  @ViewBuilder private var networkRouting: some View {
    Section("Network routing") {
      Toggle("Route system traffic via tsmux", isOn: pacBinding)
        .disabled(!model.profiles.contains { $0.condition == .running })
      LabeledContent("PAC URL") {
        CopyableValue(value: pacURL.isEmpty ? "unavailable while tsmux is stopped" : pacURL)
      }
    }
  }

  private var pacBinding: Binding<Bool> {
    Binding(
      get: { model.pacApplied },
      set: { _ in
        model.togglePAC()
        pacURL = CLI.pacURL() ?? ""
      })
  }

  // MARK: window

  @ViewBuilder private var window: some View {
    Section("Window") {
      VStack(alignment: .leading, spacing: 3) {
        Toggle(
          "Hide Dock Icon",
          isOn: Binding(get: { model.hideDockIcon }, set: { model.hideDockIcon = $0 }))
        Text("TSMux stays in the menu bar only. Settings opens without a Dock icon.")
          .font(.footnote)
          .foregroundStyle(.secondary)
      }
    }
  }

  // MARK: exit nodes

  @ViewBuilder private var exitNodes: some View {
    Section("Exit Nodes") {
      LabeledContent("Use an exit node") {
        HStack(spacing: 8) {
          Text(exitNodeSummary).foregroundStyle(.secondary).lineLimit(1)
          jumpButton(to: model.profiles.first { !($0.prefs?.exitNode.isEmpty ?? true) })
        }
      }
      fleetRow("Allow local network access") { $0.prefs?.exitNodeAllowLAN ?? false }
      // One honest row, not N identical disabled ones.
      UnavailableRow(
        title: "Run as exit node", note: Unavailable.runAsExitNode,
        control: AnyView(Toggle("", isOn: .constant(false)).labelsHidden()))
    }
  }

  private var exitNodeSummary: String {
    let using = model.profiles.filter { !($0.prefs?.exitNode.isEmpty ?? true) }
    guard !using.isEmpty else { return "No tailnet is using one" }
    return
      using
      .map { p in
        let id = p.prefs?.exitNode ?? ""
        let name = p.exitNodeOptions?.first { $0.id == id }?.hostname ?? id
        return "\(p.name) → \(name)"
      }
      .joined(separator: " · ")
  }

  // MARK: fleet rows

  private func fleetRow(_ title: String, _ on: @escaping (ProfileStatus) -> Bool) -> some View {
    let total = model.profiles.count
    let matching = model.profiles.filter(on)
    let count = matching.count
    let summary = total == 0 ? "no tailnets yet" : "\(count) of \(total) tailnets"
    // The odd one out only exists when exactly one profile disagrees.
    let odd: ProfileStatus? =
      count == total - 1
      ? model.profiles.first { !on($0) } : (count == 1 && total > 2 ? matching.first : nil)
    return LabeledContent(title) {
      HStack(spacing: 8) {
        Text(summary).foregroundStyle(.secondary)
        jumpButton(to: odd)
      }
    }
  }

  private func jumpButton(to profile: ProfileStatus?) -> some View {
    Button("Manage in Accounts") {
      if let profile { model.selectedProfile = profile.profile }
      model.selectedTab = .accounts
    }
    .disabled(model.profiles.isEmpty)
  }
}

struct AboutTab: View {
  @State private var version = "…"

  var body: some View {
    VStack(spacing: 12) {
      Image(systemName: "point.3.filled.connected.trianglepath.dotted")
        .font(.system(size: 48))
        .foregroundStyle(Color.accentColor)
      Text("TSMux").font(.title).bold()
      Text("Version \(version)").foregroundStyle(.secondary)
      Text("Runs every one of your Tailscale tailnets at the same time, in userspace.")
        .multilineTextAlignment(.center)
        .frame(maxWidth: 380)
      Button("github.com/NorthIsUp/tsmux") {
        openURLString("https://github.com/NorthIsUp/tsmux")
      }
      .buttonStyle(.link)
      Text("MIT licensed.").font(.footnote).foregroundStyle(.secondary)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .task {
      if case .success(let v) = CLI.json(VersionInfo.self, ["version"]) {
        version = v.version ?? "unknown"
      } else {
        version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown"
      }
    }
  }
}
