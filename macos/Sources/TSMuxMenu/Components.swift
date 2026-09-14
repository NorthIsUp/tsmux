import AppKit
import SwiftUI

// Shared bits of the Settings window. Kept dumb: no state beyond a copy flash.

struct CopyButton: View {
  let value: String
  @State private var copied = false

  var body: some View {
    Button {
      NSPasteboard.general.clearContents()
      NSPasteboard.general.setString(value, forType: .string)
      copied = true
      Task {
        try? await Task.sleep(for: .seconds(1))
        copied = false
      }
    } label: {
      Image(systemName: copied ? "checkmark" : "doc.on.doc")
    }
    .buttonStyle(.borderless)
    .help("Copy")
    .accessibilityLabel(copied ? "Copied" : "Copy \(value)")
    .disabled(value.isEmpty)
  }
}

/// Read-only value + copy button, the shape Tailscale uses for a search domain.
struct CopyableValue: View {
  let value: String
  var monospaced = false

  var body: some View {
    HStack(spacing: 6) {
      Text(value)
        .font(monospaced ? .system(.body, design: .monospaced) : .body)
        .textSelection(.enabled)
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .truncationMode(.middle)
      CopyButton(value: value)
    }
  }
}

struct StatusDot: View {
  let condition: ProfileStatus.Condition

  var body: some View {
    Circle()
      .fill(color)
      .frame(width: 9, height: 9)
      .accessibilityLabel(label)
  }

  private var color: Color {
    switch condition {
    case .running: return .green
    case .starting: return .blue
    case .needsLogin: return .yellow
    case .stopped: return .secondary
    case .failed: return .red
    }
  }

  private var label: String { condition.label }
}

extension ProfileStatus.Condition {
  var label: String {
    switch self {
    case .running: return "Connected"
    case .starting: return "Connecting…"
    case .needsLogin: return "Needs login"
    case .stopped: return "Stopped"
    case .failed: return "Error"
    }
  }
}

/// D9: initials in a tinted circle. No image fetch for decoration in a tool
/// whose whole point is scoped traffic.
struct InitialsAvatar: View {
  let name: String
  var size: CGFloat = 26

  var body: some View {
    ZStack {
      Circle().fill(Color.accentColor.opacity(0.18))
      Text(initials)
        .font(.system(size: size * 0.42, weight: .semibold))
        .foregroundStyle(Color.accentColor)
    }
    .frame(width: size, height: size)
    .accessibilityHidden(true)
  }

  private var initials: String {
    let words = name.split(separator: " ").prefix(2)
    let letters = words.compactMap { $0.first.map(String.init) }.joined()
    return letters.isEmpty ? "?" : letters.uppercased()
  }
}

/// The one treatment for every capability tsmux structurally cannot offer:
/// Tailscale's label at full contrast, an "Unavailable" capsule where the
/// control would be, and the reason spelled out under it.
struct UnavailableRow: View {
  let title: String
  let note: String
  var control: AnyView?

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      HStack {
        Text(title)
        Spacer()
        if let control {
          control.disabled(true)
        }
        Text("Unavailable")
          .font(.caption)
          .foregroundStyle(.secondary)
          .padding(.horizontal, 7)
          .padding(.vertical, 2)
          .background(Capsule().fill(Color.secondary.opacity(0.12)))
      }
      Text(note)
        .font(.footnote)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
    }
    .help(note)
    .accessibilityHint(note)
  }
}

enum Unavailable {
  static let runAsExitNode = """
    Unavailable. Serving as an exit node means capturing and forwarding other \
    devices' traffic, which needs a system VPN interface. tsmux runs each tailnet \
    in userspace with no VPN device — the same choice that lets it run all your \
    tailnets at the same time. Using an exit node still works, per tailnet, under \
    Accounts.
    """

  static let vpnOnDemand = """
    Unavailable. On Demand turns a system VPN profile on and off as you change \
    networks. tsmux installs no system VPN profile, so there is nothing to switch — \
    your tailnets are simply always connected, on every network.
    """

  static let tailnetLock = """
    Unavailable. The Tailscale library tsmux embeds (v1.102.4) exposes no \
    tailnet-lock API, so tsmux can't sign or list locked nodes. Manage lock from \
    the admin console, or from the official Tailscale client on another device.
    """
}

@MainActor
func openURLString(_ s: String) {
  guard let url = URL(string: s) else { return }
  NSWorkspace.shared.open(url)
}
