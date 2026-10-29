import Combine
import Foundation

/// Provides complete zero-leak privacy isolation, scenario presets, and hands-free auto-play
/// for public demos and screen recordings.
final class DemoMode: ObservableObject {
  static let shared = DemoMode()

  /// Sample peripheral connection state when `demoSimulateSwitching` is active.
  @Published var demoPeripheralsConnectedHere: Bool = true
  @Published var activeDemoPeerID: String = "demo-macbook-pro"
  /// Whether hands-free Auto-Play Demo Loop is currently running.
  @Published private(set) var isAutoPlaying: Bool = false
  @Published private(set) var autoPlayCycleCount: Int = 0

  private var autoPlayTimer: Timer?
  private var didSeedInitialDemoLogs = false

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

  /// Clean placeholder unpaired/available devices shown under "Paired With This Mac" in Demo Mode
  /// so real personal phones, watches, headsets, TVs, and speakers are NEVER shown.
  let sampleAvailablePeripherals: [BluetoothPeripheral] = [
    BluetoothPeripheral(
      id: "XX:XX:XX:XX:11:A4", name: "Magic Keyboard (Compact)", alias: "", isEnabled: true),
    BluetoothPeripheral(
      id: "XX:XX:XX:XX:22:C8", name: "Studio Wireless Headphones", alias: "", isEnabled: true),
  ]

  /// Clean placeholder Bonjour peer shown under "Discovered on This Network" in Demo Mode
  /// so real LAN Macs on the user's home/office network are NEVER shown.
  let sampleDiscoveredPeers: [PeerDevice] = [
    PeerDevice(
      id: "demo-discovered-imac", name: "Studio iMac 24\"", host: "10.0.1.62", port: 54820,
      isManual: false, appVersion: AppInfo.version, appBuild: AppInfo.build)
  ]

  private static let genericMacNames = [
    "MacBook Pro 16\"",
    "Mac Studio",
    "Mac mini M4",
    "iMac 24\"",
    "MacBook Air 15\"",
  ]

  private init() {
    if AppSettings.shared.demoModeEnabled {
      ensureDemoLogsSeeded()
    }
  }

  var isEnabled: Bool {
    let on = AppSettings.shared.demoModeEnabled
    if on && !didSeedInitialDemoLogs {
      ensureDemoLogsSeeded()
    }
    return on
  }

  var isSimulatingSwitch: Bool {
    AppSettings.shared.demoModeEnabled && AppSettings.shared.demoSimulateSwitching
  }

  private func ensureDemoLogsSeeded() {
    didSeedInitialDemoLogs = true
    Log.shared.seedDemoEntriesIfEmpty(
      localName: effectiveDemoLocalAlias,
      peerName: effectiveDemoPeerAlias
    )
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
    BluetoothDiagnosticsService.shared.clearDiagnosticResults()
    if AppSettings.shared.demoModeEnabled {
      ensureDemoLogsSeeded()
      applyScenario(AppSettings.shared.demoScenario)
      Log.demo(.info, "Demo", "Demo Mode ENABLED — all personal, hardware & network info hidden")
    } else {
      stopAutoPlay()
      Log.info("Demo / Screen Recording Mode \(state)", "App")
    }
  }

  func applyScenario(_ scenario: DemoScenario) {
    objectWillChange.send()
    guard AppSettings.shared.demoModeEnabled else { return }
    ensureDemoLogsSeeded()
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
    ensureDemoLogsSeeded()
    isAutoPlaying = true
    autoPlayCycleCount = 0
    Log.demo(.info, "Demo", "Started hands-free Demo Auto-Play loop")
    rescheduleAutoPlayIfNeeded()
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
      Log.demo(.info, "Demo", "Stopped Demo Auto-Play loop")
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
    Log.demo(.info, "Network", "Bonjour service published as \"\(local)\" (_blueswitch._tcp · port 54820)")
    Log.demo(.info, "Network", "Discovered peer \(peer) at 10.0.1.24:54820 — AES-256-GCM authenticated")
    Log.demo(.info, "Bluetooth", "Bluetooth Link Security verified: 3/3 HID peripherals using Bonded AES/E0 encryption")
    Log.demo(.info, "Security", "Input Guard scanned active WindowServer taps: 0 unauthorized keystroke/mouse monitors")
    Log.demo(.info, "Switch", "Switched Magic Keyboard with Touch ID, Magic Trackpad & Magic Mouse to \(peer) in 320 ms")
  }

  func resetDemoState() {
    stopAutoPlay()
    demoPeripheralsConnectedHere = true
    activeDemoPeerID = "demo-macbook-pro"
    SecurityMonitor.shared.clearSimulatedIncidents()
    Log.shared.seedDemoEntriesIfEmpty(
      localName: effectiveDemoLocalAlias,
      peerName: effectiveDemoPeerAlias
    )
    Log.demo(.info, "Demo", "Reset Demo Mode showcase state (peripherals connected to \(localMacDisplayName))")
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
    if sampleDiscoveredPeers.contains(where: { $0.id == peer.id }) { return peer.name }
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
    if samplePeers.contains(where: { $0.id == peer.id })
      || sampleDiscoveredPeers.contains(where: { $0.id == peer.id })
    {
      return "\(peer.host):\(peer.port) · AES-256-GCM"
    }
    let lastOctet = (abs(peer.id.hashValue) % 80) + 20
    return "10.0.1.\(lastOctet):54820 · AES-256-GCM"
  }

  /// Never outputs any substring of a real peripheral's name or alias when Demo Mode is active.
  func peripheralDisplayName(_ p: BluetoothPeripheral) -> String {
    guard isEnabled else { return p.displayName }
    if samplePeripherals.contains(where: { $0.id == p.id })
      || sampleAvailablePeripherals.contains(where: { $0.id == p.id })
    {
      return p.name
    }
    return Self.genericHardwareLabel(for: p.name)
  }

  func peripheralSubtitle(_ p: BluetoothPeripheral) -> String {
    guard isEnabled else {
      return p.alias.isEmpty ? p.id : "\(p.name) · \(p.id)"
    }
    return Self.maskMAC(p.id)
  }

  /// Always returns generic studio audio device names in Demo Mode so real AirPods/iPhone/USB interface names never show.
  func audioDeviceDisplayName(_ raw: String, isInput: Bool) -> String {
    guard isEnabled else { return raw }
    return isInput ? "Studio Microphone" : "Studio Speakers"
  }

  func sanitizePath(_ path: String) -> String {
    guard isEnabled else { return path }
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    var out = path.replacingOccurrences(of: home, with: "~")
    for token in Self.personalWordTokens() {
      out = out.replacingOccurrences(of: token, with: "demo", options: .caseInsensitive)
    }
    return out
  }

  func sanitizeLog(_ text: String) -> String {
    guard isEnabled else { return text }
    var out = sanitizePath(text)
    let localAlias = effectiveDemoLocalAlias

    // Scrub GitHub repository and owner slug (e.g. n060dy-007/blue-switch and n060dy-007)
    let repo = AppSettings.shared.updateRepository.trimmingCharacters(in: .whitespacesAndNewlines)
    if !repo.isEmpty {
      out = out.replacingOccurrences(
        of: repo, with: "demo-org/blue-switch", options: .caseInsensitive)
      if let owner = repo.split(separator: "/").first, owner.count >= 3 {
        out = out.replacingOccurrences(
          of: String(owner), with: "demo-org", options: .caseInsensitive)
      }
    }

    // Scrub full name, username, computer name, and individual name tokens
    for token in [NSFullUserName(), NSUserName(), Host.current().localizedName ?? ""]
    where !token.isEmpty {
      out = out.replacingOccurrences(of: token, with: localAlias, options: .caseInsensitive)
    }
    for word in Self.personalWordTokens() {
      out = out.replacingOccurrences(of: word, with: "Studio", options: .caseInsensitive)
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
          of: p.name, with: Self.genericHardwareLabel(for: p.name), options: .caseInsensitive)
      }
      if !p.alias.isEmpty {
        out = out.replacingOccurrences(
          of: p.alias, with: Self.genericHardwareLabel(for: p.name), options: .caseInsensitive)
      }
    }

    // Scrub email addresses
    if let emailRegex = try? NSRegularExpression(
      pattern: "[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\\.[A-Za-z]{2,}")
    {
      let range = NSRange(out.startIndex..<out.endIndex, in: out)
      out = emailRegex.stringByReplacingMatches(
        in: out, range: range, withTemplate: "demo@example.com")
    }

    // Scrub .local Bonjour hostnames
    if let localRegex = try? NSRegularExpression(
      pattern: "\\b[A-Za-z0-9-]+\\.local\\.?\\b")
    {
      let range = NSRange(out.startIndex..<out.endIndex, in: out)
      out = localRegex.stringByReplacingMatches(
        in: out, range: range, withTemplate: "mac-studio.local")
    }

    // Mask Bluetooth MAC addresses completely (zero real octets preserved)
    if let macRegex = try? NSRegularExpression(
      pattern: "\\b(?:[0-9A-Fa-f]{2}[:-]){5}[0-9A-Fa-f]{2}\\b")
    {
      let range = NSRange(out.startIndex..<out.endIndex, in: out)
      out = macRegex.stringByReplacingMatches(
        in: out, range: range, withTemplate: "XX:XX:XX:XX:8A:1F")
    }

    // Mask IPv4 addresses completely
    if let ipRegex = try? NSRegularExpression(
      pattern: "\\b(?:\\d{1,3}\\.){3}\\d{1,3}\\b")
    {
      let range = NSRange(out.startIndex..<out.endIndex, in: out)
      out = ipRegex.stringByReplacingMatches(
        in: out, range: range, withTemplate: "10.0.1.24")
    }

    return out
  }

  // MARK: - Effective Isolated Collections for UI

  var effectivePeripherals: [BluetoothPeripheral] {
    if isSimulatingSwitch || (isEnabled && BluetoothService.shared.peripherals.isEmpty) {
      return samplePeripherals
    }
    return BluetoothService.shared.peripherals
  }

  /// Paired-but-unmanaged devices shown in `PeripheralsPane`: completely isolated from real OS paired devices in Demo Mode.
  var effectiveAvailablePeripherals: [BluetoothPeripheral] {
    if isEnabled {
      return sampleAvailablePeripherals
    }
    return BluetoothService.shared.availablePeripherals
  }

  var effectivePeers: [PeerDevice] {
    if isSimulatingSwitch || (isEnabled && NetworkService.shared.peers.isEmpty) {
      return samplePeers
    }
    return NetworkService.shared.peers
  }

  /// Discovered Bonjour Macs shown in `DevicesPane`: completely isolated from real LAN Macs in Demo Mode.
  var effectiveDiscoveredPeers: [PeerDevice] {
    if isEnabled {
      return sampleDiscoveredPeers
    }
    return NetworkService.shared.discovered
  }

  /// Security incidents shown on `DashboardView` & `NetworkPane`: hides all real local process event-tap alerts in Demo Mode.
  var effectiveSecurityIncidents: [SecurityIncident] {
    if isEnabled {
      return SecurityMonitor.shared.incidents.filter { $0.pid == -999 }
    }
    return SecurityMonitor.shared.incidents
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
    if isEnabled {
      return .online
    }
    return NetworkService.shared.reachability[peer.id] ?? .unknown
  }

  // MARK: - Deterministic Zero-Leak Helpers

  /// Replaces any real Bluetooth MAC with a deterministic synthetic `XX:XX:XX:XX:HH:HH` string (0 real bytes preserved).
  static func maskMAC(_ id: String) -> String {
    if id.hasPrefix("XX:") { return id }
    var hash: UInt64 = 1_469_598_103_934_665_603
    for b in id.uppercased().utf8 {
      hash ^= UInt64(b)
      hash &*= 1_099_511_628_211
    }
    let b1 = UInt8((hash >> 8) & 0xFF)
    let b2 = UInt8(hash & 0xFF)
    return String(format: "XX:XX:XX:XX:%02X:%02X", b1, b2)
  }

  /// Maps any hardware name to a 100% generic product type without echoing any user-defined substring.
  static func genericHardwareLabel(for rawName: String) -> String {
    let lower = rawName.lowercased()
    if lower.contains("keyboard") { return "Magic Keyboard" }
    if lower.contains("trackpad") { return "Magic Trackpad" }
    if lower.contains("mouse") { return "Magic Mouse" }
    if lower.contains("airpods") || lower.contains("headphone") || lower.contains("beats")
      || lower.contains("buds")
    {
      return "Studio Wireless Headphones"
    }
    return "Bluetooth Peripheral"
  }

  static func stripPersonalOwnerPrefix(from name: String) -> String {
    genericHardwareLabel(for: name)
  }

  private static func personalWordTokens() -> [String] {
    let genericMacWords: Set<String> = [
      "mac", "macbook", "pro", "air", "mini", "studio", "imac", "local", "apple", "computer", "the",
    ]
    var tokens: Set<String> = []
    let sources =
      [NSFullUserName(), NSUserName(), Host.current().localizedName ?? ""] + Host.current().names
    for src in sources where !src.isEmpty {
      tokens.insert(src)
      let parts = src.components(separatedBy: CharacterSet.alphanumerics.inverted)
      for part in parts where part.count >= 3 && !genericMacWords.contains(part.lowercased()) {
        tokens.insert(part)
      }
    }
    return tokens.sorted { $0.count > $1.count }
  }
}
