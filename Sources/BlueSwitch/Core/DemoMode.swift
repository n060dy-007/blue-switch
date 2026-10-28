import Combine
import Foundation

/// Provides privacy redaction and interactive showcase state for public screen recordings and demos.
final class DemoMode: ObservableObject {
  static let shared = DemoMode()

  /// Sample peripherals shown in Demo Mode when `demoSimulateSwitching` is active (or when no real peripherals are registered).
  @Published var demoPeripheralsConnectedHere: Bool = true
  @Published var activeDemoPeerID: String = "demo-macbook-pro"

  let samplePeripherals: [BluetoothPeripheral] = [
    BluetoothPeripheral(
      id: "XX:XX:XX:XX:8A:1F", name: "Magic Keyboard with Touch ID", alias: "", isEnabled: true),
    BluetoothPeripheral(
      id: "XX:XX:XX:XX:4C:92", name: "Magic Trackpad", alias: "", isEnabled: true),
    BluetoothPeripheral(
      id: "XX:XX:XX:XX:2E:07", name: "Magic Mouse", alias: "", isEnabled: true),
  ]

  let samplePeers: [PeerDevice] = [
    PeerDevice(
      id: "demo-macbook-pro", name: "MacBook Pro 16\"", host: "10.0.1.24", port: 54820,
      isManual: false, appVersion: AppInfo.version, appBuild: AppInfo.build),
    PeerDevice(
      id: "demo-mac-mini", name: "Studio Mac mini", host: "10.0.1.38", port: 54820,
      isManual: false, appVersion: AppInfo.version, appBuild: AppInfo.build),
  ]

  private static let genericMacNames = [
    "MacBook Pro 16\"",
    "Mac Studio",
    "Mac mini M4",
    "iMac 24\"",
    "MacBook Air 15\"",
  ]

  private init() {}

  var isEnabled: Bool { AppSettings.shared.demoModeEnabled }
  var isSimulatingSwitch: Bool {
    AppSettings.shared.demoModeEnabled && AppSettings.shared.demoSimulateSwitching
  }

  func toggle() {
    AppSettings.shared.demoModeEnabled.toggle()
    let state = AppSettings.shared.demoModeEnabled ? "ENABLED" : "DISABLED"
    Log.info("Demo / Screen Recording Mode \(state)", "Demo")
  }

  // MARK: - Display Redaction Helpers

  var localMacDisplayName: String {
    guard isEnabled else { return AppSettings.shared.effectiveDeviceName }
    return "Mac Studio"
  }

  var publishedServiceDisplayName: String {
    guard isEnabled else { return NetworkService.shared.publishedName ?? "—" }
    return "Mac Studio (_blueswitch._tcp)"
  }

  var listeningPortDisplay: String {
    guard isEnabled else {
      return NetworkService.shared.listeningPort.map { " · port \($0)" } ?? ""
    }
    return " · port 54820 (AES-256-GCM)"
  }

  var releaseFeedDisplay: String {
    guard isEnabled else { return AppSettings.shared.updateRepository }
    return "demo-org/blue-switch"
  }

  func peerDisplayName(_ peer: PeerDevice) -> String {
    guard isEnabled else { return peer.name }
    if samplePeers.contains(where: { $0.id == peer.id }) { return peer.name }
    let idx = abs(peer.id.hashValue) % Self.genericMacNames.count
    return Self.genericMacNames[idx]
  }

  func peerAddressDisplay(_ peer: PeerDevice) -> String {
    guard isEnabled else {
      return peer.host.isEmpty ? "Address not resolved yet" : "\(peer.host):\(peer.port)"
    }
    if samplePeers.contains(where: { $0.id == peer.id }) {
      return "\(peer.host):\(peer.port) · AES-256-GCM"
    }
    let lastOctet = (abs(peer.id.hashValue) % 80) + 20
    return "10.0.1.\(lastOctet):54820 · AES-256-GCM"
  }

  func peripheralDisplayName(_ p: BluetoothPeripheral) -> String {
    guard isEnabled else { return p.displayName }
    return Self.stripPersonalOwnerPrefix(from: p.displayName)
  }

  func peripheralSubtitle(_ p: BluetoothPeripheral) -> String {
    guard isEnabled else {
      return p.alias.isEmpty ? p.id : "\(p.name) · \(p.id)"
    }
    let masked = Self.maskMAC(p.id)
    let cleanName = Self.stripPersonalOwnerPrefix(from: p.name)
    return p.alias.isEmpty ? masked : "\(cleanName) · \(masked)"
  }

  func audioDeviceDisplayName(_ raw: String, isInput: Bool) -> String {
    guard isEnabled else { return raw }
    let cleaned = Self.stripPersonalOwnerPrefix(from: raw)
    if cleaned.lowercased().contains("iphone") || cleaned.lowercased().contains("ipad") {
      return isInput ? "Studio Microphone" : "Studio Speakers"
    }
    return cleaned
  }

  func sanitizePath(_ path: String) -> String {
    guard isEnabled else { return path }
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    var out = path.replacingOccurrences(of: home, with: "~")
    let user = NSUserName()
    if !user.isEmpty {
      out = out.replacingOccurrences(of: user, with: "demo", options: .caseInsensitive)
    }
    return out
  }

  func sanitizeLog(_ text: String) -> String {
    guard isEnabled else { return text }
    var out = sanitizePath(text)

    // Scrub full name & username
    for token in [NSFullUserName(), NSUserName(), Host.current().localizedName ?? ""]
    where !token.isEmpty {
      out = out.replacingOccurrences(of: token, with: "Mac Studio", options: .caseInsensitive)
    }
    let customDev = AppSettings.shared.deviceName.trimmingCharacters(in: .whitespacesAndNewlines)
    if !customDev.isEmpty {
      out = out.replacingOccurrences(of: customDev, with: "Mac Studio", options: .caseInsensitive)
    }

    // Scrub registered & discovered peer names and hosts
    for peer in NetworkService.shared.peers + NetworkService.shared.discovered {
      if !peer.name.isEmpty {
        out = out.replacingOccurrences(
          of: peer.name, with: peerDisplayName(peer), options: .caseInsensitive)
      }
      if !peer.host.isEmpty {
        out = out.replacingOccurrences(
          of: peer.host, with: "10.0.1.24", options: .caseInsensitive)
      }
    }

    // Scrub Bluetooth peripheral personal names
    for p in BluetoothService.shared.peripherals + BluetoothService.shared.availablePeripherals {
      if !p.name.isEmpty {
        out = out.replacingOccurrences(
          of: p.name, with: Self.stripPersonalOwnerPrefix(from: p.name), options: .caseInsensitive)
      }
    }

    // Mask Bluetooth MAC addresses (AA:BB:CC:DD:EE:FF or AA-BB-CC-DD-EE-FF)
    if let macRegex = try? NSRegularExpression(
      pattern: "\\b([0-9A-Fa-f]{2}[:-]){4}([0-9A-Fa-f]{2}[:-][0-9A-Fa-f]{2})\\b")
    {
      let range = NSRange(out.startIndex..<out.endIndex, in: out)
      out = macRegex.stringByReplacingMatches(
        in: out, range: range, withTemplate: "XX:XX:XX:XX:$2")
    }

    // Mask IPv4 addresses
    if let ipRegex = try? NSRegularExpression(
      pattern: "\\b(?:\\d{1,3}\\.){3}(\\d{1,3})\\b")
    {
      let range = NSRange(out.startIndex..<out.endIndex, in: out)
      out = ipRegex.stringByReplacingMatches(
        in: out, range: range, withTemplate: "10.0.1.$1")
    }

    return out
  }

  // MARK: - Effective Demo Collections for UI

  var effectivePeripherals: [BluetoothPeripheral] {
    if isSimulatingSwitch || (isEnabled && BluetoothService.shared.peripherals.isEmpty) {
      return samplePeripherals
    }
    return BluetoothService.shared.peripherals
  }

  var effectivePeers: [PeerDevice] {
    if isSimulatingSwitch || (isEnabled && NetworkService.shared.peers.isEmpty) {
      return samplePeers
    }
    return NetworkService.shared.peers
  }

  var effectiveActivePeer: PeerDevice? {
    if isSimulatingSwitch || (isEnabled && NetworkService.shared.peers.isEmpty) {
      return samplePeers.first { $0.id == activeDemoPeerID } ?? samplePeers.first
    }
    return NetworkService.shared.activePeer
  }

  func isPeripheralConnected(_ p: BluetoothPeripheral) -> Bool {
    if isSimulatingSwitch || (isEnabled && BluetoothService.shared.peripherals.isEmpty) {
      return demoPeripheralsConnectedHere
    }
    return BluetoothService.shared.isConnected(p)
  }

  var effectiveConnectionState: PeripheralConnectionState {
    if isSimulatingSwitch || (isEnabled && BluetoothService.shared.peripherals.isEmpty) {
      return demoPeripheralsConnectedHere ? .allConnected : .allDisconnected
    }
    return BluetoothService.shared.connectionState
  }

  func reachability(for peer: PeerDevice) -> PeerReachability {
    if isSimulatingSwitch || samplePeers.contains(where: { $0.id == peer.id }) {
      return .online
    }
    return NetworkService.shared.reachability[peer.id] ?? .unknown
  }

  // MARK: - String Helpers

  static func maskMAC(_ id: String) -> String {
    if id.hasPrefix("XX:") { return id }
    let suffix = id.suffix(5)
    return "XX:XX:XX:XX:\(suffix)"
  }

  /// Strips possessive prefixes like `"Gregory's Magic Keyboard"` -> `"Magic Keyboard"`.
  static func stripPersonalOwnerPrefix(from name: String) -> String {
    for sep in ["’s ", "'s "] {
      if let range = name.range(of: sep) {
        let remainder = String(name[range.upperBound...]).trimmingCharacters(in: .whitespaces)
        if !remainder.isEmpty { return remainder }
      }
    }
    let user = NSUserName()
    if !user.isEmpty && name.localizedCaseInsensitiveContains(user) {
      return name.replacingOccurrences(of: user, with: "Studio", options: .caseInsensitive)
    }
    return name
  }
}
