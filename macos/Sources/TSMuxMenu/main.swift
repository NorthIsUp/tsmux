import AppKit
import Foundation

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
  let controller = Controller()

  // Documented ordering: the status item is created after launch finishes.
  func applicationDidFinishLaunching(_ notification: Notification) {
    controller.install()
    maybeShowFirstRun(notification)
  }

  /// An app that throws a window in your face at every login is malware
  /// behaviour; a silent menu-bar icon after a double-click tells the user
  /// nothing. Show it once, and only when the user launched us themselves.
  private func maybeShowFirstRun(_ notification: Notification) {
    guard controller.model.configState == .firstRun else { return }
    let userLaunched =
      notification.userInfo?["NSApplicationLaunchIsDefaultLaunchKey"] as? Bool ?? true
    guard userLaunched,
      !UserDefaults.standard.bool(forKey: AppModel.didShowFirstRunKey)
    else { return }
    UserDefaults.standard.set(true, forKey: AppModel.didShowFirstRunKey)
    SettingsWindow.shared.show(controller.model)
  }

  func applicationWillTerminate(_ notification: Notification) {
    controller.shutdown()
  }
}

assert(Slug.selfCheck(), "profile-key derivation is wrong")

let app = NSApplication.shared
// Covers running the binary outside the .app bundle, where LSUIElement is absent.
app.setActivationPolicy(.accessory)
// NSApp holds its delegate weakly, so this global is what keeps it (and the
// status item it owns) alive for the process lifetime.
let delegate = MainActor.assumeIsolated { AppDelegate() }
app.delegate = delegate
app.run()
