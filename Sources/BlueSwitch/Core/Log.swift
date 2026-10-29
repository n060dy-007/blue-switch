import Foundation
import SwiftUI

struct LogEntry: Identifiable {
  let id = UUID()
  let date: Date
  let level: LogLevel
  let category: String
  let message: String

  var displayMessage: String {
    DemoMode.shared.sanitizeLog(message)
  }

  var line: String {
    let f = ISO8601DateFormatter()
    return "\(f.string(from: date)) [\(level.label.uppercased())] [\(category)] \(message)"
  }

  var displayLine: String {
    let f = ISO8601DateFormatter()
    return "\(f.string(from: date)) [\(level.label.uppercased())] [\(category)] \(displayMessage)"
  }
}

/// In-app activity log shown in Settings → Activity Log.
/// When Demo Mode is active, `visibleEntries` returns an isolated `demoEntries` buffer so zero
/// historical personal/hardware/network log lines from real sessions are ever exposed on screen.
final class Log: ObservableObject {
  static let shared = Log()
  @Published private(set) var entries: [LogEntry] = []
  @Published private(set) var demoEntries: [LogEntry] = []

  private init() {}

  var visibleEntries: [LogEntry] {
    DemoMode.shared.isEnabled ? demoEntries : entries
  }

  static func debug(_ m: String, _ c: String = "App") { shared.add(.debug, c, m) }
  static func info(_ m: String, _ c: String = "App") { shared.add(.info, c, m) }
  static func warn(_ m: String, _ c: String = "App") { shared.add(.warning, c, m) }
  static func error(_ m: String, _ c: String = "App") { shared.add(.error, c, m) }

  static func demo(_ level: LogLevel = .info, _ c: String = "Demo", _ m: String) {
    shared.addDemo(level, c, m)
  }

  func add(_ level: LogLevel, _ category: String, _ message: String) {
    let entry = LogEntry(date: Date(), level: level, category: category, message: message)
    print(entry.line)
    let apply = { [weak self] in
      guard let self else { return }
      let settings = AppSettings.shared
      guard level >= settings.logLevel else { return }
      self.entries.append(entry)
      let maxEntries = max(50, settings.maxLogEntries)
      if self.entries.count > maxEntries {
        self.entries.removeFirst(self.entries.count - maxEntries)
      }
      // Only mirror explicitly safe Demo-originated events into demoEntries when Demo Mode is on
      if settings.demoModeEnabled && category == "Demo" {
        self.demoEntries.append(
          LogEntry(
            date: entry.date,
            level: level,
            category: category,
            message: DemoMode.shared.sanitizeLog(message)
          )
        )
      }
    }
    if Thread.isMainThread { apply() } else { DispatchQueue.main.async(execute: apply) }
  }

  func addDemo(_ level: LogLevel, _ category: String, _ message: String) {
    let apply = { [weak self] in
      guard let self else { return }
      let clean = DemoMode.shared.sanitizeLog(message)
      self.demoEntries.append(LogEntry(date: Date(), level: level, category: category, message: clean))
      if self.demoEntries.count > 200 {
        self.demoEntries.removeFirst(self.demoEntries.count - 200)
      }
    }
    if Thread.isMainThread { apply() } else { DispatchQueue.main.async(execute: apply) }
  }

  func seedDemoEntriesIfEmpty(localName: String, peerName: String) {
    let apply = { [weak self] in
      guard let self else { return }
      self.demoEntries = [
        LogEntry(
          date: Date().addingTimeInterval(-42), level: .info, category: "Network",
          message: "Bonjour service published as \"\(localName)\" (_blueswitch._tcp · port 54820)"),
        LogEntry(
          date: Date().addingTimeInterval(-35), level: .info, category: "Network",
          message: "Discovered peer \(peerName) at 10.0.1.24:54820 — AES-256-GCM authenticated"),
        LogEntry(
          date: Date().addingTimeInterval(-24), level: .info, category: "Bluetooth",
          message: "Verified 3/3 HID peripherals using Bonded AES/E0 Link Encryption (-52 dBm)"),
        LogEntry(
          date: Date().addingTimeInterval(-14), level: .info, category: "Security",
          message: "Keystroke & Mouse Guard active: 2 signed system taps inspected · 0 threats"),
        LogEntry(
          date: Date().addingTimeInterval(-4), level: .info, category: "Switch",
          message: "Ready to switch Magic Keyboard, Magic Trackpad & Magic Mouse between \(localName) and \(peerName)"),
      ]
    }
    if Thread.isMainThread { apply() } else { DispatchQueue.main.async(execute: apply) }
  }

  func clear() { entries.removeAll() }

  func clearVisible() {
    if DemoMode.shared.isEnabled {
      demoEntries.removeAll()
    } else {
      entries.removeAll()
    }
  }

  var exportText: String { visibleEntries.map(\.displayLine).joined(separator: "\n") }
}
