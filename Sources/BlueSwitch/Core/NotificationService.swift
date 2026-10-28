import Foundation
import UserNotifications

/// Wraps UNUserNotificationCenter and applies the Notifications settings.
enum NotificationService {
  enum Kind { case switchResult, error, peerFound, remoteRequest, message, general }

  /// UNUserNotificationCenter crashes when there is no bundle (e.g. `swift run`).
  private static var available: Bool { Bundle.main.bundleIdentifier != nil }

  static func requestAuthorization() {
    guard available else { return }
    UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) {
      granted, error in
      if let error { Log.warn("Notification authorization error: \(error)", "Notify") }
      Log.debug("Notification authorization \(granted ? "granted" : "denied")", "Notify")
    }
  }

  static func authorizationStatus(_ completion: @escaping (String) -> Void) {
    guard available else {
      completion("Unavailable (run the .app bundle)")
      return
    }
    UNUserNotificationCenter.current().getNotificationSettings { s in
      let text: String
      switch s.authorizationStatus {
      case .authorized: text = "Allowed"
      case .denied: text = "Denied in System Settings"
      case .notDetermined: text = "Not requested yet"
      case .provisional: text = "Provisional"
      case .ephemeral: text = "Ephemeral"
      @unknown default: text = "Unknown"
      }
      DispatchQueue.main.async { completion(text) }
    }
  }

  static func post(title: String, body: String, kind: Kind = .general) {
    let s = AppSettings.shared
    guard s.notificationsEnabled else { return }
    switch kind {
    case .switchResult where !s.notifyOnSwitch: return
    case .error where !s.notifyOnError: return
    case .peerFound where !s.notifyOnPeerFound: return
    case .remoteRequest where !s.notifyOnRemoteRequest: return
    default: break
    }
    guard available else {
      Log.info("[notification] \(title): \(body)", "Notify")
      return
    }
    let content = UNMutableNotificationContent()
    content.title = title
    content.body = body
    if s.notificationSound { content.sound = .default }
    let req = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
    UNUserNotificationCenter.current().add(req) { error in
      if let error { Log.warn("Failed to show notification: \(error)", "Notify") }
    }
  }
}
