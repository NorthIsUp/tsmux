import AppKit
import SwiftUI

struct RemoveTailnetSheet: View {
  let model: AppModel
  let profile: ProfileStatus
  @Environment(\.dismiss) private var dismiss
  @State private var purge = false

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      Text("Remove \(profile.name)?").font(.headline)
      Text(
        "tsmux will stop running this tailnet and drop it from the configuration. "
          + "Other tailnets keep running."
      )
      .fixedSize(horizontal: false, vertical: true)
      Toggle("Also delete saved credentials", isOn: $purge)
      Text("Leave this off to keep the saved login so re-adding does not need a new sign-in.")
        .font(.footnote)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
      Spacer()
      HStack {
        Spacer()
        Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
        Button("Remove", role: .destructive) { remove() }
          .keyboardShortcut(.defaultAction)
      }
    }
    .padding(20)
    .frame(width: 440, height: 240)
  }

  private func remove() {
    var args = ["profile", "rm", profile.profile]
    if purge { args.append("--purge") }
    let outcome = model.mutateProfiles { CLI.json(RemovedProfile.self, args, timeout: 20) }
    if case .failure(let e) = outcome {
      Alert.show("Could not remove \(profile.name)", e.message)
      return
    }
    model.selectedProfile = nil
    dismiss()
  }
}

struct DNSSheet: View {
  let model: AppModel
  let profile: ProfileStatus
  @Environment(\.dismiss) private var dismiss
  @State private var inlineError: String?

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      Text("DNS — \(profile.name)").font(.headline)
      statusCard
      Form {
        Toggle("Use Tailscale DNS", isOn: acceptDNS)
          .disabled(profile.prefs == nil)
        LabeledContent("Search Domain") {
          if let s = profile.magicDNSSuffix, !s.isEmpty {
            CopyableValue(value: s, monospaced: true)
          } else {
            Text("not learned yet").foregroundStyle(.secondary)
          }
        }
        Section("Extra suffixes this tailnet claims") {
          if profile.extraSuffixes.isEmpty {
            Text("none").foregroundStyle(.secondary)
          } else {
            ForEach(profile.extraSuffixes, id: \.self) { s in
              Text(s).font(.system(.body, design: .monospaced))
            }
          }
          Text(
            "Routing sends these to this tailnet. Most setups need none, and the "
              + "search domain above is learned automatically. Edit them in "
              + "config.yaml under Advanced."
          )
          .font(.footnote)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
        }
      }
      .formStyle(.grouped)
      if let inlineError {
        Text(inlineError).font(.callout).foregroundStyle(.red)
      }
      HStack {
        Spacer()
        Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
      }
    }
    .padding(20)
    .frame(width: 480, height: 420)
  }

  @ViewBuilder private var statusCard: some View {
    if let s = profile.magicDNSSuffix, !s.isEmpty {
      Label {
        Text("MagicDNS is resolving names for **\(s)** inside this tailnet only.")
          .fixedSize(horizontal: false, vertical: true)
      } icon: {
        Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
      }
    } else {
      Label {
        Text("Not learned yet — log in and the search domain appears here automatically.")
          .fixedSize(horizontal: false, vertical: true)
      } icon: {
        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
      }
    }
  }

  private var acceptDNS: Binding<Bool> {
    Binding(
      get: { profile.prefs?.acceptDNS ?? false },
      set: { inlineError = model.setPrefs(profile.profile, ["--accept-dns=\($0)"]) })
  }
}

struct CLIIntegrationSheet: View {
  @Environment(\.dismiss) private var dismiss

  private static let command =
    "ln -s /Applications/TSMux.app/Contents/Resources/tsmux /usr/local/bin/tsmux"

  private var installed: String? {
    for p in ["/usr/local/bin/tsmux", "/opt/homebrew/bin/tsmux"]
    where FileManager.default.isExecutableFile(atPath: p) {
      return p
    }
    return nil
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      Text("Use tsmux from the command line").font(.headline)
      if let installed {
        Label("Already installed at \(installed)", systemImage: "checkmark.circle.fill")
          .foregroundStyle(.green)
      }
      Text("Run this in Terminal to link the copy bundled inside TSMux.app:")
      HStack(alignment: .top, spacing: 8) {
        Text(Self.command)
          .font(.system(.caption, design: .monospaced))
          .textSelection(.enabled)
          .fixedSize(horizontal: false, vertical: true)
        CopyButton(value: Self.command)
      }
      .padding(10)
      .background(RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(0.1)))
      Spacer()
      HStack {
        Spacer()
        Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
      }
    }
    .padding(20)
    .frame(width: 460, height: 260)
  }
}
