import Foundation
import ServiceManagement

/// Launch-at-login via SMAppService (macOS 13+). Implements upstream's "Auto Launch at Startup".
enum LoginItem {
  static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }

  static var statusText: String {
    switch SMAppService.mainApp.status {
    case .enabled: return "Enabled"
    case .notRegistered: return "Not registered"
    case .requiresApproval: return "Needs approval in System Settings → Login Items"
    case .notFound: return "Unavailable (move BlueSwitch.app to /Applications)"
    @unknown default: return "Unknown"
    }
  }

  @discardableResult
  static func set(_ enabled: Bool) -> Bool {
    do {
      if enabled {
        if SMAppService.mainApp.status != .enabled { try SMAppService.mainApp.register() }
      } else {
        if SMAppService.mainApp.status == .enabled { try SMAppService.mainApp.unregister() }
      }
      Log.info("Launch at login \(enabled ? "enabled" : "disabled")", "System")
      return true
    } catch {
      Log.error("Launch at login change failed: \(error.localizedDescription)", "System")
      return false
    }
  }

  static func openSystemSettings() { SMAppService.openSystemSettingsLoginItems() }
}
