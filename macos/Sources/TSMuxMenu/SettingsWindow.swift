import AppKit
import Combine
import SwiftUI

/// One lazily-created, retained window. A menu-bar app that leaks a window per
/// invocation is the classic bug here, so `isReleasedWhenClosed` is off and the
/// close button only orders out.
@MainActor
final class SettingsWindow: NSObject, NSWindowDelegate {
  static let shared = SettingsWindow()

  private var window: NSWindow?
  private var model: AppModel?

  func show(_ model: AppModel, addTailnet: Bool = false) {
    self.model = model
    if window == nil { build(model) }
    guard let window else { return }
    if addTailnet { model.selectedTab = .accounts }
    window.subtitle = model.selectedTab.title

    // An .accessory app has no app menu, so ⌘W/⌘C and Edit-menu text editing
    // are dead inside a form. Hiding the Dock icon is the user asking for that.
    if !model.hideDockIcon {
      NSApp.setActivationPolicy(.regular)
      NSApp.activate()
    } else {
      NSApp.activate(ignoringOtherApps: true)
    }
    window.makeKeyAndOrderFront(nil)
    if addTailnet { NotificationCenter.default.post(name: .tsmuxAddTailnet, object: nil) }
  }

  private func build(_ model: AppModel) {
    let root = SettingsRootView(model: model) { [weak self] title in
      self?.window?.subtitle = title
    }
    let w = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 760, height: 560),
      styleMask: [.titled, .closable, .miniaturizable, .resizable],
      backing: .buffered, defer: false)
    w.title = "TSMux"
    w.contentMinSize = NSSize(width: 680, height: 480)
    w.contentViewController = NSHostingController(rootView: root)
    w.isReleasedWhenClosed = false
    w.delegate = self
    w.center()
    w.setFrameAutosaveName("TSMuxSettings")
    window = w
  }

  func windowWillClose(_ notification: Notification) {
    NSApp.setActivationPolicy(.accessory)
  }
}

extension Notification.Name {
  static let tsmuxAddTailnet = Notification.Name("tsmux.addTailnet")
}

struct SettingsRootView: View {
  let model: AppModel
  let onTabChange: (String) -> Void

  @State private var showAdd = false

  var body: some View {
    TabView(selection: tabBinding) {
      AccountsTab(model: model, showAdd: $showAdd)
        .tabItem { Label("Accounts", systemImage: "person.2") }
        .tag(SettingsTab.accounts)
      GlobalSettingsTab(model: model)
        .tabItem { Label("Settings", systemImage: "gearshape") }
        .tag(SettingsTab.settings)
      AboutTab()
        .tabItem { Label("About", systemImage: "info.circle") }
        .tag(SettingsTab.about)
    }
    .frame(minWidth: 680, minHeight: 480)
    .onReceive(NotificationCenter.default.publisher(for: .tsmuxAddTailnet)) { _ in
      showAdd = true
    }
  }

  private var tabBinding: Binding<SettingsTab> {
    Binding(
      get: { model.selectedTab },
      set: {
        model.selectedTab = $0
        onTabChange($0.title)
      })
  }
}
