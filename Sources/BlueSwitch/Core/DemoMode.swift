import Combine
import Foundation

/// Provides privacy redaction, scenario presets, and hands-free auto-play for public demos and screen recordings.
final class DemoMode: ObservableObject {
  static let shared = DemoMode()

  /// Sample peripheral connection state when `demoSimulateSwitching` is active.
  @Published var demoPeripheralsConnectedHere: Bool = true
  @Published var activeDemoPeerID: String = "demo-macbook-pro"
  /// Whether hands-free Auto-Play Demo Loop is currently running.
  @Published private(set) var isAutoPlaying: Bool = false
  @Published private(set) var autoPlayCycleCount: Int = 0

  private var autoPlayTimer: Timer?

  private static let studioPeripherals: [BluetoothPeripheral] = [
    BluetoothPeripheral(
      id: "XX:XX:XX:XX:8A:1F", name: "Magic Keyboard with Touch ID", alias: "", isEnabled: true),
    BluetoothPeripheral(
      id: "XX:XX:XX:XX:4C:92", name: "Magic Trackpad", alias: "", isEnabled: true),
    BluetoothPeripheral(
      id: "XX:XX:XX:XX:2E:07", name: "Magic Mouse", alias: "", isEnabled: true),
  ]

  private static let multiMacPeripherals: [BluetoothPeripheral] = [
    BluetoothPeripheral(
      id: "XX:XX:XX:XX:8A:1F", name: "Magic Keyboard with Numeric Keypad", alias: "", isEnabled: true),
    BluetoothPeripheral(
      id: "XX:XX:XX:XX:4C:92", name: "Magic Trackpad (USB-C)", alias: "", isEnabled: true),
    BluetoothPeripheral(
      id: "XX:XX:XX:XX:2E:07", name: "Magic Mouse (USB-C)", alias: "", isEnabled: true),
    BluetoothPeripheral(
      id: "XX:XX:XX:XX:9B:44", name: "AirPods Max", alias: "", isEnabled: true),
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

  var samplePeripherals: [BluetoothPeripheral] {
    switch AppSettings.shared.demoScenario {
    case .twoMacStudio, .securityShowcase:
      return Self.studioPeripherals
    case .threeMacDesk:
      return Self.multiMacPeripherals
    }
  }

  var samplePeers: [PeerDevice] {
    let primaryName = effectiveDemoPeerAlias
    let base: [PeerDevice] = [
      PeerDevice(
        id: "demo-macbook-pro", name: primaryName, host: "10.0.1.24", port: 54820,
        isManual: false, appVersion: AppInfo.version, appBuild: AppInfo.build)
    ]
    switch AppSettings.shared.demoScenario {
    case .twoMacStudio:
      return base
    case .threeMacDesk:
      return base + [
        PeerDevice(
          id: "demo-mac-mini", name: "Studio Mac mini M4", host: "10.0.1.38", port: 54820,
          isManual: false, appVersion: AppInfo.version, appBuild: AppInfo.build),
        PeerDevice(
          id: "demo-macbook-air", name: "MacBook Air 15\"", host: "10.0.1.51", port: 54820,
          isManual: false, appVersion: AppInfo.version, appBuild: AppInfo.build),
      ]
    case .securityShowcase:
      return base + [
        PeerDevice(
          id: "demo-mac-mini", name: "Secure Lab Mac mini", host: "10.0.1.38", port: 54820,
          isManual: false, appVersion: AppInfo.version, appBuild: AppInfo.build)
      ]
    }
  }

  func toggle() {
    AppSettings.shared.demoModeEnabled.toggle()
    let state = AppSettings.shared.demoModeEnabled ? "ENABLED" : "DISABLED"
    Log.info("Demo / Screen Recording Mode \(state)", "Demo")
    if AppSettings.shared.demoModeEnabled {
      applyScenario(AppSettings.shared.demoScenario)
    } else {
      stopAutoPlay()
    }
  }

  func applyScenario(_ scenario: DemoScenario) {
    objectWillChange.send()
    guard isEnabled else { return }
    switch scenario {
    case .twoMacStudio, .threeMacDesk:
      activeDemoPeerID = "demo-macbook-pro"
    case .securityShowcase:
      activeDemoPeerID = "demo-macbook-pro"
      BluetoothDiagnosticsService.shared.runFullDiagnosticSuite()
      populateSampleLogs()
    }
  }

  // MARK: - Hands-Free Auto-Play Demo Loop

  func toggleAutoPlay() {
    if isAutoPlaying {
      stopAutoPlay()
    } else {
      startAutoPlay()
    }
  }

  func startAutoPlay() {
    if !AppSettings.shared.demoModeEnabled {
      AppSettings.shared.demoModeEnabled = true
    }
    if !AppSettings.shared.demoSimulateSwitching {
      AppSettings.shared.demoSimulateSwitching = true
    }
    isAutoPlaying = true
    autoPlayCycleCount = 0
    Log.info("Started hands-free Demo Auto-Play loop", "Demo")
    rescheduleAutoPlayIfNeeded()
    // Perform first simulated switch immediately so user gets instant visual feedback
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
      guard let self, self.isAutoPlaying else { return }
      self.performAutoPlayStep()
    }
  }

  func stopAutoPlay() {
    autoPlayTimer?.invalidate()
    autoPlayTimer = nil
    if isAutoPlaying {
      isAutoPlaying = false
      Log.info("Stopped Demo Auto-Play loop", "Demo")
    }
  }

  func rescheduleAutoPlayIfNeeded() {
    guard isAutoPlaying else { return }
    autoPlayTimer?.invalidate()
    let interval = max(3.0, AppSettings.shared.demoAutoPlayInterval)
    autoPlayTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) {
      [weak self] _ in
      self?.performAutoPlayStep()
    }
  }

  private func performAutoPlayStep() {
    guard isEnabled, isAutoPlaying else {
      stopAutoPlay()
      return
    }
    guard !SwitchCoordinator.shared.phase.isWorking else { return }
    autoPlayCycleCount += 1

    // In 3-Mac scenario, rotate target peer when bringing back to local Mac
    if demoPeripheralsConnectedHere == false {
      let peers = samplePeers
      if peers.count > 1, let idx = peers.firstIndex(where: { $0.id == activeDemoPeerID }) {
        activeDemoPeerID = peers[(idx + 1) % peers.count].id
      }
    }
    SwitchCoordinator.shared.switchDevices()
  }

  // MARK: - Showcase Helpers

  func populateSampleLogs() {
    let local = localMacDisplayName
    let peer = effectiveDemoPeerAlias
    Log.info("Bonjour service published as \(local) (_blueswitch._tcp · port 54820)", "Network")
    Log.info("Discovered peer \(peer) at 10.0.1.24:54820 — AES-256-GCM authenticated", "Network")
    Log.info("Bluetooth Link Security verified: 3/3 HID peripherals using Bonded AES/E0 encryption", "Bluetooth")
    Log.info("Input Guard scanned active WindowServer taps: 0 unauthorized keystroke/mouse monitors", "Security")
    Log.info("Switched Magic Keyboard with Touch ID, Magic Trackpad & Magic Mouse to \(peer) in 340 ms", "Switch")
  }

  func resetDemoState() {
    stopAutoPlay()
    demoPeripheralsConnectedHere = true
    activeDemoPeerID = "demo-macbook-pro"
    SecurityMonitor.shared.clearIncidents()
    Log.info("Reset Demo Mode showcase state (peripherals connected to \(localMacDisplayName))", "Demo")
  }

  // MARK: - Display Redaction Helpers

  private var effectiveDemoLocalAlias: String {
    let trimmed = AppSettings.shared.demoLocalMacName.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? "Mac Studio" : trimmed
  }

  private var effectiveDemoPeerAlias: String {
    let trimmed = AppSettings.shared.demoPeerMacName.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? "MacBook Pro 16\"" : trimmed
  }

  var localMacDisplayName: String {
    guard isEnabled else { return AppSettings.shared.effectiveDeviceName }
    return effectiveDemoLocalAlias
  }

  var publishedServiceDisplayName: String {
    guard isEnabled else { return NetworkService.shared.publishedName ?? "—" }
    return "\(effectiveDemoLocalAlias) (_blueswitch._tcp)"
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
    if NetworkService.shared.activePeer?.id == peer.id {
      return effectiveDemoPeerAlias
    }
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
    let localAlias = effectiveDemoLocalAlias

    // Scrub full name & username
    for token in [NSFullUserName(), NSUserName(), Host.current().localizedName ?? ""]
    where !token.isEmpty {
      out = out.replacingOccurrences(of: token, with: localAlias, options: .caseInsensitive)
    }
    let customDev = AppSettings.shared.deviceName.trimmingCharacters(in: .whitespacesAndNewlines)
    if !customDev.isEmpty {
      out = out.replacingOccurrences(of: customDev, with: localAlias, options: .caseInsensitive)
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
