import Foundation
import SwiftUI

struct LogEntry: Identifiable {
  let id = UUID()
  let date: Date
  let level: LogLevel
  let category: String
  let message: String

  var line: String {
    let f = ISO8601DateFormatter()
    return "\(f.string(from: date)) [\(level.label.uppercased())] [\(category)] \(message)"
  }
}

/// In-app activity log shown in Settings → Activity Log.
final class Log: ObservableObject {
  static let shared = Log()
  @Published private(set) var entries: [LogEntry] = []

  private init() {}

  static func debug(_ m: String, _ c: String = "App") { shared.add(.debug, c, m) }
  static func info(_ m: String, _ c: String = "App") { shared.add(.info, c, m) }
  static func warn(_ m: String, _ c: String = "App") { shared.add(.warning, c, m) }
  static func error(_ m: String, _ c: String = "App") { shared.add(.error, c, m) }

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
    }
    if Thread.isMainThread { apply() } else { DispatchQueue.main.async(execute: apply) }
  }

  func clear() { entries.removeAll() }

  var exportText: String { entries.map(\.line).joined(separator: "\n") }
}
