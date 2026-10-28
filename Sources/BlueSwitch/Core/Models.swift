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
