import Foundation

/// A Bluetooth peripheral (Magic Keyboard, Trackpad, Mouse…) managed by BlueSwitch.
struct BluetoothPeripheral: Identifiable, Codable, Hashable {
  /// MAC address of the device (stable identifier shared across Macs).
  let id: String
  /// Name reported by the device.
  var name: String
  /// Optional user-provided display name.
  var alias: String = ""
  /// Whether this peripheral participates in switching.
  var isEnabled: Bool = true

  var displayName: String { alias.isEmpty ? name : alias }

  /// Canonical uppercase colon-separated MAC (`XX:XX:XX:XX:XX:XX`).
  var canonicalID: String { Self.canonicalMAC(id) }

  /// Normalizes any MAC separator/case (`04-41-a5-9a-f1-4f` -> `04:41:A5:9A:F1:4F`).
  static func canonicalMAC(_ raw: String) -> String {
    raw
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .replacingOccurrences(of: "-", with: ":")
      .uppercased()
  }

  /// Normalizes device names across curly/straight apostrophes and case (`Home’s` == `Home's`).
  static func canonicalName(_ raw: String) -> String {
    raw
      .replacingOccurrences(of: "\u{2019}", with: "'")
      .replacingOccurrences(of: "\u{2018}", with: "'")
      .replacingOccurrences(of: "\u{02BC}", with: "'")
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .lowercased()
  }

  init(id: String, name: String, alias: String = "", isEnabled: Bool = true) {
    self.id = id
    self.name = name
    self.alias = alias
    self.isEnabled = isEnabled
  }

  // Tolerant decoding so older saved data (id + name only) still loads.
  init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    id = try c.decode(String.self, forKey: .id)
    name = try c.decode(String.self, forKey: .name)
    alias = try c.decodeIfPresent(String.self, forKey: .alias) ?? ""
    isEnabled = try c.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true
  }

  /// Guess an SF Symbol from the device name.
  var symbolName: String {
    let n = name.lowercased()
    if n.contains("trackpad") { return "rectangle.and.hand.point.up.left.fill" }
    if n.contains("mouse") { return "computermouse.fill" }
    if n.contains("keyboard") { return "keyboard" }
    if n.contains("airpods") || n.contains("headphone") || n.contains("beats") {
      return "headphones"
    }
    return "dot.radiowaves.left.and.right"
  }
}

/// Another Mac running BlueSwitch.
struct PeerDevice: Identifiable, Codable, Hashable {
  /// Bonjour service name (or user-supplied name for manual peers).
  let id: String
  var name: String
  var host: String
  var port: Int
  var isManual: Bool = false
  var lastSeen: Date? = nil
  var appVersion: String? = nil
  var appBuild: String? = nil

  init(
    id: String, name: String, host: String, port: Int, isManual: Bool = false,
    appVersion: String? = nil, appBuild: String? = nil
  ) {
    self.id = id
    self.name = name
    self.host = host
    self.port = port
    self.isManual = isManual
    self.appVersion = appVersion
    self.appBuild = appBuild
  }

  init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    id = try c.decode(String.self, forKey: .id)
    name = try c.decode(String.self, forKey: .name)
    host = try c.decodeIfPresent(String.self, forKey: .host) ?? ""
    port = try c.decodeIfPresent(Int.self, forKey: .port) ?? 0
    isManual = try c.decodeIfPresent(Bool.self, forKey: .isManual) ?? false
    lastSeen = try c.decodeIfPresent(Date.self, forKey: .lastSeen)
    appVersion = try c.decodeIfPresent(String.self, forKey: .appVersion)
    appBuild = try c.decodeIfPresent(String.self, forKey: .appBuild)
  }
}

/// Aggregate connection state of the enabled peripherals on this Mac.
enum PeripheralConnectionState {
  case none, allConnected, allDisconnected, partial

  var label: String {
    switch self {
    case .none: return "No peripherals"
    case .allConnected: return "Connected here"
    case .allDisconnected: return "Not on this Mac"
    case .partial: return "Partially connected"
    }
  }
}

enum PeerReachability: Equatable {
  case unknown, checking, online, offline
}

/// Live connection and battery telemetry reported by a peer Mac for its peripherals.
struct PeerPeripheralStatus: Codable, Hashable, Equatable {
  var id: String
  var name: String
  var isConnected: Bool
  var batteryPercent: Int?
  var isCharging: Bool
  var transport: String?

  var canonicalID: String { BluetoothPeripheral.canonicalMAC(id) }
  var canonicalName: String { BluetoothPeripheral.canonicalName(name) }
}
