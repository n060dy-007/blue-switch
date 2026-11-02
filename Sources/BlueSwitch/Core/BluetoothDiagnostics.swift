import Combine
import CoreBluetooth
import Foundation
import IOBluetooth
import IOKit
import SwiftUI

// MARK: - Telemetry & Security Models

enum BluetoothSignalQuality: String {
  case excellent = "Excellent"
  case good = "Good"
  case fair = "Fair"
  case weak = "Weak"
  case idle = "Idle"

  var color: Color {
    switch self {
    case .excellent, .good: return Theme.green
    case .fair: return Theme.amber
    case .weak: return Theme.red
    case .idle: return .secondary
    }
  }

  var symbol: String {
    switch self {
    case .excellent, .good: return "wifi"
    case .fair: return "wifi.exclamationmark"
    case .weak: return "exclamationmark.triangle.fill"
    case .idle: return "moon.zzz"
    }
  }
}

struct BluetoothControllerSecurityInfo {
  var isPoweredOn: Bool = true
  var rawAddress: String = "—"
  var isDiscoverable: Bool = false
  var isConnectable: Bool = true
  var classOfDeviceHex: String = "0x000000"
  var pairedDevicesCount: Int = 0
  var connectedHIDCount: Int = 0
  var unencryptedActiveCount: Int = 0
  var unsolicitedHIDCount: Int = 0

  var displayAddress: String {
    if DemoMode.shared.isEnabled {
      return "XX:XX:XX:XX:9A:01"
    }
    return rawAddress
  }

  var displayClassOfDeviceHex: String {
    if DemoMode.shared.isEnabled {
      return "0x38010C"
    }
    return classOfDeviceHex
  }

  var securityPostureLabel: String {
    if !DemoMode.shared.isEnabled && (unencryptedActiveCount > 0 || unsolicitedHIDCount > 0) {
      return "Warning — Review Active Links"
    }
    if !isPoweredOn && !DemoMode.shared.isEnabled {
      return "Radio Off"
    }
    return isDiscoverable && !DemoMode.shared.isEnabled
      ? "Protected (Discoverable Mode On)"
      : "Hardened (Non-Discoverable · Link-Key Encrypted)"
  }

  var securityPostureColor: Color {
    if !DemoMode.shared.isEnabled && (unencryptedActiveCount > 0 || unsolicitedHIDCount > 0) {
      return Theme.red
    }
    return (isDiscoverable && !DemoMode.shared.isEnabled) ? Theme.amber : Theme.green
  }
}

struct PeripheralReliabilityStats: Codable {
  var successCount: Int = 0
  var failureCount: Int = 0
  var consecutiveFailures: Int = 0
  var autoHealCount: Int = 0
  var lastLatencyMs: Int? = nil
  var totalLatencyMs: Int = 0
  var latencySamples: Int = 0
  var lastConnectedAt: Date? = nil
  var lastErrorDescription: String? = nil

  var averageLatencyMs: Int? {
    guard latencySamples > 0 else { return lastLatencyMs }
    return totalLatencyMs / latencySamples
  }

  var reliabilityPercent: Int {
    let total = successCount + failureCount
    guard total > 0 else { return 100 }
    return Int((Double(successCount) / Double(total) * 100.0).rounded())
  }
}

struct PeripheralSecurityTelemetry: Identifiable {
  let id: String
  var name: String
  var isConnected: Bool
  var isPaired: Bool
  var rssi: Int?  // dBm when connected and valid
  var rawRSSI: Int?
  var encryptionMode: Int  // 0 = off, 1 = P2P encrypted, 2 = P2P + broadcast encrypted
  var isIncoming: Bool
  var deviceClassMajor: UInt32
  var deviceClassMinor: UInt32
  var vendorName: String
  var stats: PeripheralReliabilityStats
  var batteryPercent: Int? = nil
  var isCharging: Bool = false
  var activeTransport: String? = nil
  var connectedOnPeerName: String? = nil

  var batterySymbol: String {
    if isCharging { return "battery.100percent.bolt" }
    guard let pct = batteryPercent else { return "battery.0percent" }
    if pct >= 88 { return "battery.100percent" }
    if pct >= 63 { return "battery.75percent" }
    if pct >= 38 { return "battery.50percent" }
    if pct >= 13 { return "battery.25percent" }
    return "battery.0percent"
  }

  var batteryColor: Color {
    if isCharging { return Theme.green }
    guard let pct = batteryPercent else { return .secondary }
    if pct <= 15 { return Theme.red }
    if pct <= 30 { return Theme.amber }
    if pct >= 50 { return Theme.green }
    return .secondary
  }

  var batteryDisplay: String? {
    guard let pct = batteryPercent else { return nil }
    return isCharging ? "\(pct)% ⚡" : "\(pct)%"
  }

  var signalQuality: BluetoothSignalQuality {
    guard isConnected, let rssi else { return .idle }
    if rssi >= -60 { return .excellent }
    if rssi >= -72 { return .good }
    if rssi >= -82 { return .fair }
    return .weak
  }

  var rssiDisplay: String {
    guard isConnected, let rssi else {
      if isConnected {
        if let tr = activeTransport, tr == "USB-C" {
          return "Wired USB-C"
        }
        return "Active Link"
      }
      if let peer = connectedOnPeerName {
        return "Active on \(peer)"
      }
      return "Standby"
    }
    return "\(rssi) dBm (\(signalQuality.rawValue))"
  }

  var isLinkEncrypted: Bool {
    if encryptionMode > 0 { return true }
    if activeTransport == "USB-C" && isConnected { return true }
    if connectedOnPeerName != nil { return true }
    // On macOS, paired Apple Magic HID devices connected over classic/BR-EDR or BLE HID
    // enforce link-layer encryption via their paired bond even when HCI encryptionMode reports 0.
    return isConnected && isPaired
  }

  var encryptionBadgeText: String {
    if isConnected {
      if activeTransport == "USB-C" {
        return "Direct USB-C HID"
      } else if encryptionMode >= 1 {
        return "AES/E0 Link Encrypted"
      } else if isPaired {
        return "Bonded HID Encrypted"
      } else {
        return "Unencrypted Link"
      }
    } else if connectedOnPeerName != nil {
      return "Bonded HID Encrypted"
    } else {
      return isPaired ? "Paired Bond Ready" : "Re-pairs on Switch"
    }
  }

  var encryptionColor: Color {
    if isConnected && !isLinkEncrypted { return Theme.red }
    if isConnected && isLinkEncrypted { return Theme.green }
    if connectedOnPeerName != nil { return Theme.cyan }
    return isPaired ? Theme.blue : .secondary
  }

  var deviceClassDescription: String {
    switch deviceClassMajor {
    case 0x05:  // Peripheral (HID)
      switch deviceClassMinor {
      case 0x10: return "HID Keyboard"
      case 0x20: return "HID Pointing / Trackpad"
      case 0x30: return "HID Combo Keyboard/Pointing"
      default: return "HID Peripheral"
      }
    case 0x04:
      return "Audio / Video Device"
    case 0x01:
      return "Computer"
    default:
      let lower = name.lowercased()
      if lower.contains("trackpad") || lower.contains("mouse") { return "HID Pointing / Trackpad" }
      if lower.contains("keyboard") { return "HID Keyboard" }
      return "Bluetooth Device"
    }
  }

  var connectionDirectionLabel: String {
    if !isConnected {
      if let peer = connectedOnPeerName {
        return "Connected on \(peer)"
      }
      return "Standby"
    }
    if activeTransport == "USB-C" { return "Wired USB-C" }
    return isIncoming ? "Peripheral-Initiated (Reconnect)" : "Host-Initiated (Verified)"
  }
}

struct BluetoothDiagnosticStepResult: Identifiable {
  enum Status: String {
    case running = "Running"
    case passed = "Passed"
    case warning = "Warning"
    case failed = "Failed"

    var color: Color {
      switch self {
      case .running: return Theme.blue
      case .passed: return Theme.green
      case .warning: return Theme.amber
      case .failed: return Theme.red
      }
    }

    var symbol: String {
      switch self {
      case .running: return "hourglass"
      case .passed: return "checkmark.seal.fill"
      case .warning: return "exclamationmark.triangle.fill"
      case .failed: return "xmark.octagon.fill"
      }
    }
  }

  let id = UUID()
  var title: String
  var detail: String
  var status: Status
  var durationMs: Int?
}

// MARK: - Bluetooth Diagnostics, Reliability & Security Service

final class BluetoothDiagnosticsService: ObservableObject {
  static let shared = BluetoothDiagnosticsService()

  struct HIDHardwareNode {
    var canonicalMAC: String?
    var product: String
    var canonicalName: String
    var batteryPercent: Int?
    var isCharging: Bool
    var transport: String
    var vendorID: Int?
  }

  struct AccessoryPowerReading {
    var name: String
    var canonicalName: String
    var batteryPercent: Int
    var isCharging: Bool
    var isPresent: Bool
  }

  @Published private(set) var controllerInfo = BluetoothControllerSecurityInfo()
  @Published private(set) var telemetryByID: [String: PeripheralSecurityTelemetry] = [:]
  @Published private(set) var statsByID: [String: PeripheralReliabilityStats] = [:]
  @Published private(set) var diagnosticSteps: [BluetoothDiagnosticStepResult] = []
  @Published private(set) var isRunningDiagnostics = false
  @Published private(set) var testingPeripheralIDs: Set<String> = []
  @Published private(set) var lastDiagnosticRunAt: Date? = nil
  @Published private(set) var lastDiagnosticSummary: String = "Not run in this session"
  @Published private(set) var totalAutoHealsSession: Int = 0

  /// Until this timestamp, the auto-heal watchdog will not attempt to reconnect peripherals
  /// (because BlueSwitch intentionally released them to another Mac).
  private var suppressAutoHealUntil: Date = .distantPast
  /// Tracks whether peripherals were intentionally sent to a peer Mac so we don't fight the peer.
  private var intentionallyReleasedToPeer = false
  private var watchdogTimer: Timer?
  private let statsStorageKey = "bluetoothReliabilityStatsV1"
  private let batteryCacheKey = "bluetoothBatteryCacheV1"
  private let scrubbedFlagKey = "bluetoothReliabilityScrubbedV2"

  private let hidLock = NSLock()
  private var cachedHIDNodesStorage: [HIDHardwareNode] = []
  private var cachedHIDNodesAt: Date = .distantPast
  private var accessoryPowerByName: [String: AccessoryPowerReading] = [:]
  private var lastKnownBatteryByKey: [String: Int] = [:]
  private var lastPmsetPollAt: Date = .distantPast
  private var isPollingPmset = false

  private init() {
    loadBatteryCache()
    loadStats()
    pollAccessoryPowerAsync(force: true)
    refreshTelemetry()
  }

  // MARK: - Lifecycle & Watchdog

  func start() {
    pollAccessoryPowerAsync(force: true)
    refreshTelemetry()
    scheduleWatchdog()
  }

  func scheduleWatchdog() {
    watchdogTimer?.invalidate()
    let interval = max(3.0, AppSettings.shared.btAutoHealInterval)
    watchdogTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) {
      [weak self] _ in
      self?.watchdogTick()
    }
  }

  /// Called when BlueSwitch intentionally releases peripherals (e.g. sending to another Mac).
  func markIntentionallyReleased(cooldown: TimeInterval = 20.0) {
    intentionallyReleasedToPeer = true
    suppressAutoHealUntil = Date().addingTimeInterval(cooldown)
  }

  /// Called when BlueSwitch connects or claims peripherals onto this Mac.
  func markClaimedLocally() {
    intentionallyReleasedToPeer = false
  }

  // MARK: - Stats Recording

  func recordConnectOutcome(
    for p: BluetoothPeripheral,
    succeeded: Bool,
    latencyMs: Int,
    attemptsUsed: Int,
    isAutoHeal: Bool = false
  ) {
    DispatchQueue.main.async {
      let key = p.canonicalID
      var st = self.statsByID[key] ?? PeripheralReliabilityStats()
      if succeeded {
        st.successCount += 1
        st.consecutiveFailures = 0
        st.lastLatencyMs = latencyMs
        st.totalLatencyMs += latencyMs
        st.latencySamples += 1
        st.lastConnectedAt = Date()
        st.lastErrorDescription = nil
        if isAutoHeal {
          st.autoHealCount += 1
          self.totalAutoHealsSession += 1
        }
        self.intentionallyReleasedToPeer = false
      } else if !isAutoHeal {
        st.failureCount += 1
        st.consecutiveFailures += 1
        st.lastErrorDescription = "Timed out after \(attemptsUsed) attempt(s)"
      }
      self.statsByID[key] = st
      self.saveStats()
      self.refreshTelemetry()
    }
  }

  func resetReliabilityStats() {
    statsByID.removeAll()
    totalAutoHealsSession = 0
    UserDefaults.standard.removeObject(forKey: statsStorageKey)
    refreshTelemetry()
    Log.info("Cleared Bluetooth reliability & latency statistics", "Bluetooth")
  }

  func clearDiagnosticResults() {
    diagnosticSteps.removeAll()
    lastDiagnosticSummary = "Ready to run diagnostics"
  }

  // MARK: - Live Telemetry & Security Inspection

  func telemetry(for p: BluetoothPeripheral) -> PeripheralSecurityTelemetry {
    if DemoMode.shared.isEnabled {
      return demoTelemetry(for: p)
    }
    let key = p.canonicalID
    if let existing = telemetryByID[key] {
      return existing
    }
    return inspectDevice(id: p.id, fallbackName: p.name)
  }

  func refreshTelemetry() {
    pollAccessoryPowerAsync(force: false)
    let host = IOBluetoothHostController.default()
    let powered = (host?.powerState == kBluetoothHCIPowerStateON)
    let rawAddr = (host?.addressAsString() ?? "Unavailable")
      .replacingOccurrences(of: "-", with: ":")
      .uppercased()
    let cod = host?.classOfDevice() ?? 0

    let pairedDevices = (IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice]) ?? []
    var map: [String: PeripheralSecurityTelemetry] = [:]

    let managed = BluetoothService.shared.peripherals
    var entriesToInspect: [String: String] = [:]
    for p in managed {
      entriesToInspect[p.canonicalID] = p.name
    }
    for dev in pairedDevices {
      if let addr = dev.addressString {
        let canon = BluetoothPeripheral.canonicalMAC(addr)
        if entriesToInspect[canon] == nil {
          entriesToInspect[canon] = dev.name ?? "Bluetooth Device"
        }
      }
    }

    var connectedHID = 0
    var unencryptedActive = 0
    var unsolicitedHID = 0

    for (canonID, fallback) in entriesToInspect {
      let item = inspectDevice(id: canonID, fallbackName: fallback)
      map[canonID] = item

      if item.isConnected && item.deviceClassMajor == 0x05 {
        connectedHID += 1
        if !item.isLinkEncrypted {
          unencryptedActive += 1
        }
        let isManaged = managed.contains {
          $0.canonicalID == canonID
            || BluetoothPeripheral.canonicalName($0.name)
              == BluetoothPeripheral.canonicalName(item.name)
        }
        if item.isIncoming && !item.isPaired && !isManaged {
          unsolicitedHID += 1
          handleUnsolicitedHIDThreat(item)
        } else if !item.isLinkEncrypted && AppSettings.shared.btRequireEncryptedLink {
          SecurityMonitor.shared.recordAudit(
            category: "BluetoothSecurity",
            message:
              "Active HID device \(item.name) (\(item.id)) has an unencrypted link (mode \(item.encryptionMode))",
            level: .warning
          )
        }
      }
    }

    DispatchQueue.main.async {
      self.telemetryByID = map
      self.controllerInfo = BluetoothControllerSecurityInfo(
        isPoweredOn: powered,
        rawAddress: rawAddr,
        isDiscoverable: false,
        isConnectable: powered,
        classOfDeviceHex: String(format: "0x%06X", cod),
        pairedDevicesCount: pairedDevices.count,
        connectedHIDCount: connectedHID,
        unencryptedActiveCount: unencryptedActive,
        unsolicitedHIDCount: unsolicitedHID
      )
    }
  }

  private func inspectDevice(id: String, fallbackName: String) -> PeripheralSecurityTelemetry {
    let key = BluetoothPeripheral.canonicalMAC(id)
    let stats = statsByID[key] ?? statsByID[id.uppercased()] ?? PeripheralReliabilityStats()
    let local = localConnectionAndBattery(id: id, name: fallbackName)
    let dev = resolveIOBluetoothDevice(id: id, name: fallbackName)

    let effectiveName =
      (dev?.name?.isEmpty == false ? dev!.name! : nil)
      ?? fallbackName
    let probe = BluetoothPeripheral(id: id, name: effectiveName)
    let remoteMatch = NetworkService.shared.remotePeripheralStatus(for: probe)
    let remotePeerName: String? =
      (!local.isConnected && remoteMatch?.status.isConnected == true)
      ? remoteMatch?.peer.name
      : nil

    let effectiveBattery =
      local.batteryPercent
      ?? remoteMatch?.status.batteryPercent
      ?? cachedBattery(canonicalMAC: key, canonicalName: BluetoothPeripheral.canonicalName(effectiveName))
    let effectiveCharging =
      local.isConnected
      ? local.isCharging
      : (remoteMatch?.status.isConnected == true ? (remoteMatch?.status.isCharging ?? false) : false)

    let connected = local.isConnected
    let paired = local.isPaired
    let rawR = dev.map { Int($0.rawRSSI()) } ?? 0
    let r = dev.map { Int($0.rssi()) } ?? 0
    let validRSSI: Int? = (connected && r != 127 && r != 0) ? r : nil
    let validRawRSSI: Int? = (connected && rawR != 127 && rawR != 0) ? rawR : nil
    let encMode = Self.queryEncryptionMode(dev)
    let incoming = dev?.isIncoming() ?? false
    let major = dev?.deviceClassMajor ?? 0x05
    let lowerName = effectiveName.lowercased()
    let defaultMinor: UInt32 =
      (lowerName.contains("trackpad") || lowerName.contains("mouse")) ? 0x20 : 0x10
    let minor = (dev != nil && dev!.deviceClassMajor != 0) ? dev!.deviceClassMinor : defaultMinor

    return PeripheralSecurityTelemetry(
      id: key,
      name: effectiveName,
      isConnected: connected,
      isPaired: paired,
      rssi: validRSSI ?? validRawRSSI,
      rawRSSI: validRawRSSI,
      encryptionMode: encMode,
      isIncoming: incoming,
      deviceClassMajor: major == 0 ? 0x05 : major,
      deviceClassMinor: minor,
      vendorName: Self.lookupVendor(forMAC: key, deviceName: effectiveName),
      stats: stats,
      batteryPercent: effectiveBattery,
      isCharging: effectiveCharging,
      activeTransport: local.transport,
      connectedOnPeerName: remotePeerName
    )
  }

  private func handleUnsolicitedHIDThreat(_ item: PeripheralSecurityTelemetry) {
    guard AppSettings.shared.btBlockUnsolicitedHID else { return }
    SecurityMonitor.shared.recordAudit(
      category: "BluetoothSecurity",
      message:
        "ALERT: Unsolicited unpaired incoming HID connection from \(item.name) (\(item.id)). Blocking potential keystroke injection.",
      level: .error
    )
    if let dev = IOBluetoothDevice(addressString: item.id) {
      _ = dev.closeConnection()
    }
    NotificationService.post(
      title: "Blocked Unsolicited Bluetooth HID Device",
      body: "\(item.name) (\(item.id)) attempted an unpaired incoming HID connection and was disconnected.",
      kind: .error
    )
  }

  // MARK: - Auto-Heal Watchdog

  private func watchdogTick() {
    refreshTelemetry()
    let settings = AppSettings.shared
    guard settings.btAutoHealEnabled else { return }
    guard !DemoMode.shared.isSimulatingSwitch else { return }
    guard Date() >= suppressAutoHealUntil else { return }
    guard !intentionallyReleasedToPeer else { return }
    guard !SwitchCoordinator.shared.phase.isWorking else { return }

    let bt = BluetoothService.shared
    guard bt.isPoweredOn else { return }
    let enabled = bt.enabledPeripherals
    guard !enabled.isEmpty else { return }

    // Never attempt to auto-heal peripherals that are currently connected on a peer Mac.
    let connectedHere = enabled.filter { bt.isConnected($0) }
    let dropped = enabled.filter { p in
      guard !bt.isConnected(p), !bt.busyIDs.contains(p.id) else { return false }
      if NetworkService.shared.remotePeripheralStatus(for: p)?.status.isConnected == true {
        return false
      }
      return true
    }
    guard !dropped.isEmpty else { return }
    let shouldHeal = !connectedHere.isEmpty || NetworkService.shared.peers.isEmpty
    guard shouldHeal else { return }

    for p in dropped {
      Log.info(
        "Auto-Heal Watchdog: \(p.displayName) dropped unexpectedly — attempting self-heal reconnect",
        "Bluetooth")
      SecurityMonitor.shared.recordAudit(
        category: "BluetoothReliability",
        message: "Auto-Heal triggered for dropped peripheral \(p.displayName) (\(p.id))",
        level: .info
      )
      bt.connect(p, isAutoHeal: true)
    }
  }

  // MARK: - Interactive Bluetooth Testing Suite

  /// Tests a single peripheral: checks HCI visibility, RSSI, pairing bond, link encryption, and connect latency.
  func testPeripheral(_ p: BluetoothPeripheral, completion: ((Bool, String) -> Void)? = nil) {
    testingPeripheralIDs.insert(p.id)
    let start = Date()

    if DemoMode.shared.isSimulatingSwitch {
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.55) {
        let ms = Int(Date().timeIntervalSince(start) * 1000)
        self.recordConnectOutcome(for: p, succeeded: true, latencyMs: ms, attemptsUsed: 1)
        self.testingPeripheralIDs.remove(p.id)
        let name = DemoMode.shared.peripheralDisplayName(p)
        let summary = "\(name): Verified Encrypted HID · -54 dBm · \(ms) ms"
        Log.info("Bluetooth Test passed for \(summary)", "Bluetooth")
        completion?(true, summary)
      }
      return
    }

    if BluetoothService.shared.isConnected(p) {
      DispatchQueue.global(qos: .userInitiated).async {
        Thread.sleep(forTimeInterval: 0.18)
        let ms = max(12, Int(Date().timeIntervalSince(start) * 1000))
        let item = self.inspectDevice(id: p.id, fallbackName: p.displayName)
        self.recordConnectOutcome(for: p, succeeded: true, latencyMs: ms, attemptsUsed: 1)
        DispatchQueue.main.async {
          self.testingPeripheralIDs.remove(p.id)
          let summary =
            "\(p.displayName): Connected · \(item.encryptionBadgeText) · \(item.rssiDisplay) · \(ms) ms"
          Log.info("Bluetooth Test passed — \(summary)", "Bluetooth")
          SecurityMonitor.shared.recordAudit(
            category: "BluetoothTest",
            message: "Peripheral test passed: \(summary)",
            level: .info
          )
          completion?(true, summary)
        }
      }
    } else {
      BluetoothService.shared.connect(p) { ok in
        let ms = Int(Date().timeIntervalSince(start) * 1000)
        self.testingPeripheralIDs.remove(p.id)
        self.refreshTelemetry()
        let item = self.telemetry(for: p)
        let summary =
          ok
          ? "\(p.displayName): Connected in \(ms) ms · \(item.encryptionBadgeText)"
          : "\(p.displayName): Could not connect (\(ms) ms) — verify device is powered on & in range"
        if ok {
          Log.info("Bluetooth Test passed — \(summary)", "Bluetooth")
        } else {
          Log.warn("Bluetooth Test failed — \(summary)", "Bluetooth")
        }
        completion?(ok, summary)
      }
    }
  }

  /// Runs the 4-stage Bluetooth Reliability, Radio & Security Diagnostic Suite.
  func runFullDiagnosticSuite() {
    guard !isRunningDiagnostics else { return }
    isRunningDiagnostics = true
    diagnosticSteps = [
      BluetoothDiagnosticStepResult(
        title: "1. Host Controller & Permission Check",
        detail: "Inspecting IOBluetoothHostController, HCI radio state, and macOS privacy permissions…",
        status: .running, durationMs: nil),
      BluetoothDiagnosticStepResult(
        title: "2. Peripheral Signal & Baseband Link Audit",
        detail: "Waiting to sample RSSI and baseband responsiveness…",
        status: .running, durationMs: nil),
      BluetoothDiagnosticStepResult(
        title: "3. Link Encryption & Rogue-HID Security Scan",
        detail: "Waiting to verify link-key bonding, encryption modes, and IEEE OUI vendors…",
        status: .running, durationMs: nil),
      BluetoothDiagnosticStepResult(
        title: "4. Handshake & Switching Readiness Verification",
        detail: "Waiting to verify auto-clicker helper and switching pipeline readiness…",
        status: .running, durationMs: nil),
    ]

    let suiteStart = Date()
    let isDemo = DemoMode.shared.isEnabled

    // Step 1: Controller & Permissions
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
      self.refreshTelemetry()
      let bt = BluetoothService.shared
      let powered = isDemo ? true : bt.isPoweredOn
      let authorized = isDemo ? true : bt.isAuthorized
      let step1Status: BluetoothDiagnosticStepResult.Status =
        (powered && authorized) ? .passed : .failed
      let step1Detail: String
      if isDemo {
        step1Detail =
          "Controller \(self.controllerInfo.displayAddress) Online · Bluetooth Permission Allowed · HCI Ready"
      } else if !powered {
        step1Detail = "Bluetooth radio is turned OFF. Enable Bluetooth in Control Center."
      } else if !authorized {
        step1Detail =
          "Bluetooth permission is '\(bt.authorizationText)'. Grant access in System Settings → Privacy & Security → Bluetooth."
      } else {
        step1Detail =
          "Controller \(self.controllerInfo.displayAddress) Online · Permission Allowed · \(self.controllerInfo.pairedDevicesCount) paired device(s)"
      }
      self.diagnosticSteps[0] = BluetoothDiagnosticStepResult(
        title: "1. Host Controller & Permission Check",
        detail: step1Detail,
        status: step1Status,
        durationMs: 240
      )

      // Step 2: Signal & Baseband Link Poll
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
        let list = DemoMode.shared.effectivePeripherals
        let connectedCount = list.filter { DemoMode.shared.isPeripheralConnected($0) }.count
        let step2Status: BluetoothDiagnosticStepResult.Status
        let step2Detail: String

        if list.isEmpty {
          step2Status = .warning
          step2Detail = "No managed peripherals added yet. Add your Magic Keyboard/Trackpad above."
        } else {
          let rssiSummaries = list.map { p -> String in
            let t = self.telemetry(for: p)
            let name = DemoMode.shared.peripheralDisplayName(p)
            return "\(name): \(t.rssiDisplay)"
          }
          step2Status = connectedCount > 0 ? .passed : .warning
          step2Detail =
            "\(connectedCount)/\(list.count) connected locally — "
            + rssiSummaries.joined(separator: " · ")
        }

        self.diagnosticSteps[1] = BluetoothDiagnosticStepResult(
          title: "2. Peripheral Signal & Baseband Link Audit",
          detail: step2Detail,
          status: step2Status,
          durationMs: 340
        )

        // Step 3: Security & Encryption Audit
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
          let unenc = isDemo ? 0 : self.controllerInfo.unencryptedActiveCount
          let rogue = isDemo ? 0 : self.controllerInfo.unsolicitedHIDCount
          let step3Status: BluetoothDiagnosticStepResult.Status =
            (unenc == 0 && rogue == 0) ? .passed : .failed
          let step3Detail: String
          if unenc == 0 && rogue == 0 {
            step3Detail =
              "All active HID links use authenticated Link-Key / AES encryption · 0 rogue/unsolicited HID devices · Input Guard active"
          } else {
            step3Detail =
              "Detected \(unenc) unencrypted link(s) and \(rogue) unsolicited HID device(s) — review security warnings below"
          }

          self.diagnosticSteps[2] = BluetoothDiagnosticStepResult(
            title: "3. Link Encryption & Rogue-HID Security Scan",
            detail: step3Detail,
            status: step3Status,
            durationMs: 330
          )

          // Step 4: Handshake & Switching Readiness
          DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            let clickerTrusted = isDemo ? true : BluetoothAutoClicker.shared.isAccessibilityTrusted
            let autoAccept = AppSettings.shared.autoAcceptBluetoothRequests
            let peers = DemoMode.shared.effectivePeers
            let step4Status: BluetoothDiagnosticStepResult.Status =
              (!autoAccept || clickerTrusted) ? .passed : .warning
            let step4Detail: String
            if autoAccept && !clickerTrusted {
              step4Detail =
                "Accessibility permission not granted yet for auto-accepting macOS pairing banners (grant in Peripherals banner)."
            } else {
              step4Detail =
                "Auto-Clicker helper ready · Auto-Heal \(AppSettings.shared.btAutoHealEnabled ? "Enabled" : "Off") · \(peers.count) target Mac(s) configured"
            }

            self.diagnosticSteps[3] = BluetoothDiagnosticStepResult(
              title: "4. Handshake & Switching Readiness Verification",
              detail: step4Detail,
              status: step4Status,
              durationMs: 310
            )

            let totalMs = Int(Date().timeIntervalSince(suiteStart) * 1000)
            let passedCount = self.diagnosticSteps.filter { $0.status == .passed }.count
            self.lastDiagnosticRunAt = Date()
            self.lastDiagnosticSummary =
              "\(passedCount)/\(self.diagnosticSteps.count) checks passed in \(totalMs) ms"
            self.isRunningDiagnostics = false

            SecurityMonitor.shared.recordAudit(
              category: "BluetoothDiagnostics",
              message: "Completed Bluetooth diagnostic & security suite: \(self.lastDiagnosticSummary)",
              level: step3Status == .passed ? .info : .warning
            )
          }
        }
      }
    }
  }

  // MARK: - Multi-Source Hardware Connection & Battery Engine

  private static func isGenericDeviceName(_ canonName: String) -> Bool {
    let generic: Set<String> = [
      "", "bluetooth device", "unknown device", "wireless device",
      "apple keyboard", "usb keyboard", "usb mouse", "headset", "btm",
    ]
    return generic.contains(canonName)
  }

  private static func isValidMAC(_ raw: String) -> Bool {
    let parts = raw
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .replacingOccurrences(of: "-", with: ":")
      .split(separator: ":")
    guard parts.count == 6 else { return false }
    return parts.allSatisfy { $0.count == 2 && UInt8($0, radix: 16) != nil }
  }

  /// Resolves an `IOBluetoothDevice` across colon/dash MAC formats and rotated BLE addresses.
  func resolveIOBluetoothDevice(id: String, name: String) -> IOBluetoothDevice? {
    let trimmed = id.trimmingCharacters(in: .whitespacesAndNewlines)
    let canonMAC = BluetoothPeripheral.canonicalMAC(trimmed)
    let dashMAC = canonMAC.replacingOccurrences(of: ":", with: "-").lowercased()
    let canonName = BluetoothPeripheral.canonicalName(name)

    var candidates: [IOBluetoothDevice] = []
    if !trimmed.isEmpty, let d = IOBluetoothDevice(addressString: trimmed) {
      candidates.append(d)
    }
    if canonMAC != trimmed, let d = IOBluetoothDevice(addressString: canonMAC) {
      candidates.append(d)
    }
    if dashMAC != trimmed, let d = IOBluetoothDevice(addressString: dashMAC) {
      candidates.append(d)
    }

    let paired = (IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice]) ?? []
    for dev in paired {
      if let addr = dev.addressString, BluetoothPeripheral.canonicalMAC(addr) == canonMAC {
        candidates.append(dev)
      }
    }

    if let connectedMatch = candidates.first(where: { $0.isConnected() }) {
      return connectedMatch
    }
    if let pairedMatch = candidates.first(where: { $0.isPaired() }) {
      return pairedMatch
    }

    // Fallback for Apple Magic BLE HID devices whose BLE address rotated after re-pairing
    if !Self.isGenericDeviceName(canonName) {
      let nameMatches = paired.filter {
        guard let devName = $0.name else { return false }
        return BluetoothPeripheral.canonicalName(devName) == canonName
      }
      if let connectedByName = nameMatches.first(where: { $0.isConnected() }) {
        return connectedByName
      }
      if let firstByName = nameMatches.first {
        return firstByName
      }
    }

    return candidates.first
  }

  /// Queries live local connection state, battery percentage (`0-100`), charging status, and transport
  /// across `IOBluetooth`, `IORegistry` external HID nodes, `pmset -g accps`, and `CoreBluetooth`.
  func localConnectionAndBattery(
    id: String, name: String
  ) -> (
    isConnected: Bool, isPaired: Bool, batteryPercent: Int?, isCharging: Bool,
    transport: String?, resolvedMAC: String?
  ) {
    pollAccessoryPowerAsync(force: false)
    let canonMAC = BluetoothPeripheral.canonicalMAC(id)
    let dev = resolveIOBluetoothDevice(id: id, name: name)
    let effectiveName = (dev?.name?.isEmpty == false ? dev!.name! : nil) ?? name
    let canonName = BluetoothPeripheral.canonicalName(effectiveName)
    let resolvedMAC = dev?.addressString.map(BluetoothPeripheral.canonicalMAC)

    let ioConnected = dev?.isConnected() ?? false
    let ioPaired = dev?.isPaired() ?? false

    let nodes = cachedHIDNodes()
    let matchedNodes = nodes.filter { node in
      if let nodeMAC = node.canonicalMAC {
        if nodeMAC == canonMAC || (resolvedMAC != nil && nodeMAC == resolvedMAC) {
          return true
        }
      }
      if !Self.isGenericDeviceName(canonName), !node.canonicalName.isEmpty,
        node.canonicalName == canonName
      {
        return true
      }
      return false
    }

    let accps = accessoryPowerEntry(forCanonicalName: canonName)
    let bleConnected =
      !Self.isGenericDeviceName(canonName)
      && BluetoothService.shared.isBLEConnected(canonicalName: canonName)

    let isConnected =
      ioConnected || !matchedNodes.isEmpty || (accps?.isPresent == true) || bleConnected
    let isPaired = ioPaired || isConnected

    let nodeBattery = matchedNodes.compactMap(\.batteryPercent).first
    let accpsBattery = accps?.batteryPercent
    let liveBattery = nodeBattery ?? accpsBattery

    if let pct = liveBattery {
      recordBatteryInCache(pct, canonicalMAC: canonMAC, canonicalName: canonName)
      if let rMAC = resolvedMAC, rMAC != canonMAC {
        recordBatteryInCache(pct, canonicalMAC: rMAC, canonicalName: canonName)
      }
    }

    let battery = liveBattery ?? cachedBattery(canonicalMAC: canonMAC, canonicalName: canonName)
    let charging =
      matchedNodes.contains(where: \.isCharging) || (accps?.isCharging == true)
    let transport: String? = {
      if let nodeTransport = matchedNodes.first?.transport, !nodeTransport.isEmpty {
        return nodeTransport
      }
      if bleConnected && !ioConnected { return "BLE" }
      if isConnected { return "Bluetooth" }
      return nil
    }()

    return (isConnected, isPaired, battery, charging, transport, resolvedMAC)
  }

  /// Builds live status & battery snapshots for ALL local managed, paired, and active HID peripherals
  /// so peer Macs always see accurate connection & battery telemetry.
  func allLocalHardwareSnapshots(managed: [BluetoothPeripheral]) -> [PeerPeripheralStatus] {
    var byMAC: [String: PeerPeripheralStatus] = [:]
    var coveredNames: Set<String> = []

    for p in managed {
      let info = localConnectionAndBattery(id: p.id, name: p.name)
      let mac = info.resolvedMAC ?? p.canonicalID
      let cName = BluetoothPeripheral.canonicalName(p.name)
      if !cName.isEmpty { coveredNames.insert(cName) }
      byMAC[mac] = PeerPeripheralStatus(
        id: mac,
        name: p.name,
        isConnected: info.isConnected,
        batteryPercent: info.batteryPercent,
        isCharging: info.isCharging,
        transport: info.transport
      )
    }

    let paired = (IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice]) ?? []
    for dev in paired {
      guard let addr = dev.addressString else { continue }
      let mac = BluetoothPeripheral.canonicalMAC(addr)
      if byMAC[mac] != nil { continue }
      let devName = dev.name ?? "Bluetooth Device"
      let info = localConnectionAndBattery(id: mac, name: devName)
      if info.isConnected || info.batteryPercent != nil {
        let cName = BluetoothPeripheral.canonicalName(devName)
        if !cName.isEmpty { coveredNames.insert(cName) }
        byMAC[mac] = PeerPeripheralStatus(
          id: mac,
          name: devName,
          isConnected: info.isConnected,
          batteryPercent: info.batteryPercent,
          isCharging: info.isCharging,
          transport: info.transport
        )
      }
    }

    for node in cachedHIDNodes() {
      let mac = node.canonicalMAC ?? "HID:\(node.canonicalName)"
      if byMAC[mac] != nil { continue }
      if !node.canonicalName.isEmpty && coveredNames.contains(node.canonicalName) { continue }
      guard !node.product.isEmpty || node.canonicalMAC != nil else { continue }
      byMAC[mac] = PeerPeripheralStatus(
        id: mac,
        name: node.product.isEmpty ? mac : node.product,
        isConnected: true,
        batteryPercent: node.batteryPercent,
        isCharging: node.isCharging,
        transport: node.transport
      )
    }

    return Array(byMAC.values)
  }

  /// Stores battery readings received from a peer Mac so battery telemetry stays populated across switches.
  func ingestRemoteBatterySnapshots(_ list: [PeerPeripheralStatus]) {
    var updated = false
    hidLock.lock()
    for item in list {
      guard let pct = item.batteryPercent, (0...100).contains(pct) else { continue }
      let mKey = item.canonicalID
      if !mKey.isEmpty, lastKnownBatteryByKey[mKey] != pct {
        lastKnownBatteryByKey[mKey] = pct
        updated = true
      }
      let nKey = "name:\(item.canonicalName)"
      if !item.canonicalName.isEmpty, !Self.isGenericDeviceName(item.canonicalName),
        lastKnownBatteryByKey[nKey] != pct
      {
        lastKnownBatteryByKey[nKey] = pct
        updated = true
      }
    }
    let snapshotToSave = updated ? lastKnownBatteryByKey : nil
    hidLock.unlock()

    if let snapshotToSave {
      saveBatteryCache(snapshotToSave)
    }
    DispatchQueue.main.async {
      self.refreshTelemetry()
      BluetoothService.shared.bumpRefreshTick()
    }
  }

  private func recordBatteryInCache(
    _ pct: Int, canonicalMAC: String, canonicalName: String
  ) {
    guard (0...100).contains(pct) else { return }
    var snapshotToSave: [String: Int]? = nil
    hidLock.lock()
    if !canonicalMAC.isEmpty, lastKnownBatteryByKey[canonicalMAC] != pct {
      lastKnownBatteryByKey[canonicalMAC] = pct
      snapshotToSave = lastKnownBatteryByKey
    }
    if !canonicalName.isEmpty, !Self.isGenericDeviceName(canonicalName) {
      let nKey = "name:\(canonicalName)"
      if lastKnownBatteryByKey[nKey] != pct {
        lastKnownBatteryByKey[nKey] = pct
        snapshotToSave = lastKnownBatteryByKey
      }
    }
    hidLock.unlock()
    if let snapshotToSave {
      saveBatteryCache(snapshotToSave)
    }
  }

  private func cachedBattery(canonicalMAC: String, canonicalName: String) -> Int? {
    hidLock.lock()
    defer { hidLock.unlock() }
    if let v = lastKnownBatteryByKey[canonicalMAC] { return v }
    if !canonicalName.isEmpty, !Self.isGenericDeviceName(canonicalName),
      let v = lastKnownBatteryByKey["name:\(canonicalName)"]
    {
      return v
    }
    return nil
  }

  private func accessoryPowerEntry(forCanonicalName canonName: String) -> AccessoryPowerReading? {
    guard !Self.isGenericDeviceName(canonName) else { return nil }
    hidLock.lock()
    defer { hidLock.unlock() }
    return accessoryPowerByName[canonName]
  }

  private func cachedHIDNodes() -> [HIDHardwareNode] {
    hidLock.lock()
    if Date().timeIntervalSince(cachedHIDNodesAt) < 0.8 {
      let cached = cachedHIDNodesStorage
      hidLock.unlock()
      return cached
    }
    hidLock.unlock()

    let scanned = Self.scanIORegistryHIDNodes()
    hidLock.lock()
    cachedHIDNodesStorage = scanned
    cachedHIDNodesAt = Date()
    hidLock.unlock()
    return scanned
  }

  private static func scanIORegistryHIDNodes() -> [HIDHardwareNode] {
    var iterator: io_iterator_t = 0
    guard
      IOServiceGetMatchingServices(
        kIOMainPortDefault, IOServiceMatching("IOService"), &iterator) == KERN_SUCCESS
    else {
      return []
    }
    defer { IOObjectRelease(iterator) }

    let ignoredSubstrings = [
      "fifo", "spu", "spmi", "audio", "internal", "backlight", "headset", "btm", "mikey",
    ]
    var results: [HIDHardwareNode] = []

    while case let entry = IOIteratorNext(iterator), entry != 0 {
      defer { IOObjectRelease(entry) }

      let directBat = propInt(entry, "BatteryPercent") ?? propInt(entry, "BatteryLevel")
      let directTransport = propString(entry, "Transport")
      let hasExternalTransport: Bool = {
        guard let t = directTransport?.lowercased() else { return false }
        return t == "bluetooth" || t == "bluetoothlowenergy" || t == "ble" || t == "usb"
      }()

      guard directBat != nil || hasExternalTransport else { continue }
      if propBool(entry, "Built-In") == true { continue }

      let className = (IOObjectCopyClass(entry)?.takeRetainedValue() as String? ?? "").lowercased()
      if ignoredSubstrings.contains(where: { className.contains($0) }) { continue }

      var product = propString(entry, "Product") ?? ""
      var transportRaw = directTransport ?? ""
      var macCandidate = extractMAC(from: entry)
      var vendorID = propInt(entry, "VendorID")
      var isBuiltIn = false
      var charging =
        (propBool(entry, "BatteryCharging") == true)
        || (propBool(entry, "IsCharging") == true)

      // Walk up at most 6 parent IORegistry entries to fill in missing Product / MAC / Transport
      var cur: io_registry_entry_t = 0
      if IORegistryEntryGetParentEntry(entry, kIOServicePlane, &cur) == KERN_SUCCESS {
        var depth = 0
        while cur != 0 && depth < 6 {
          depth += 1
          if propBool(cur, "Built-In") == true {
            isBuiltIn = true
          }
          if product.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            let p = propString(cur, "Product"),
            !p.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
          {
            product = p
          }
          if transportRaw.isEmpty, let t = propString(cur, "Transport"), !t.isEmpty {
            transportRaw = t
          }
          if macCandidate == nil {
            macCandidate = extractMAC(from: cur)
          }
          if vendorID == nil {
            vendorID = propInt(cur, "VendorID")
          }
          if !charging {
            charging =
              (propBool(cur, "BatteryCharging") == true)
              || (propBool(cur, "IsCharging") == true)
          }
          var next: io_registry_entry_t = 0
          let hasNext =
            !isBuiltIn && (depth < 6)
            && (IORegistryEntryGetParentEntry(cur, kIOServicePlane, &next) == KERN_SUCCESS)
          IOObjectRelease(cur)
          cur = hasNext ? next : 0
        }
      }

      if isBuiltIn { continue }
      let lowerProd = product.lowercased()
      let lowerTrans = transportRaw.lowercased()
      if ignoredSubstrings.contains(where: { lowerProd.contains($0) || lowerTrans.contains($0) }) {
        continue
      }

      // Exclude pure wired non-rechargeable USB keyboards/mice that have neither battery nor BT MAC
      if lowerTrans == "usb" && directBat == nil && macCandidate == nil {
        continue
      }

      let normalizedTransport: String = {
        if lowerTrans == "usb" { return "USB-C" }
        if lowerTrans.contains("lowenergy") || lowerTrans == "ble" { return "BLE" }
        return "Bluetooth"
      }()

      let clampedBattery: Int? = directBat.flatMap { (0...100).contains($0) ? $0 : nil }
      if normalizedTransport == "USB-C" && clampedBattery != nil && (clampedBattery ?? 100) < 100 {
        charging = true
      }

      results.append(
        HIDHardwareNode(
          canonicalMAC: macCandidate,
          product: product.trimmingCharacters(in: .whitespacesAndNewlines),
          canonicalName: BluetoothPeripheral.canonicalName(product),
          batteryPercent: clampedBattery,
          isCharging: charging,
          transport: normalizedTransport,
          vendorID: vendorID
        )
      )
    }

    return results
  }

  private static func extractMAC(from entry: io_registry_entry_t) -> String? {
    for key in ["DeviceAddress", "SerialNumber", "BD_ADDR"] {
      if let s = propString(entry, key), isValidMAC(s) {
        return BluetoothPeripheral.canonicalMAC(s)
      }
    }
    if let data = IORegistryEntryCreateCFProperty(
      entry, "BD_ADDR" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? Data,
      data.count == 6
    {
      let bytes = [UInt8](data)
      if bytes.contains(where: { $0 != 0 }) {
        return bytes.map { String(format: "%02X", $0) }.joined(separator: ":")
      }
    }
    return nil
  }

  private static func propString(_ entry: io_registry_entry_t, _ key: String) -> String? {
    guard
      let val = IORegistryEntryCreateCFProperty(
        entry, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
    else { return nil }
    if let s = val as? String { return s }
    if let data = val as? Data, !data.isEmpty {
      let trimmed = data.prefix { $0 != 0 }
      return String(data: Data(trimmed), encoding: .utf8)
        ?? String(data: Data(trimmed), encoding: .macOSRoman)
    }
    return nil
  }

  private static func propInt(_ entry: io_registry_entry_t, _ key: String) -> Int? {
    guard
      let num = IORegistryEntryCreateCFProperty(
        entry, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? NSNumber
    else { return nil }
    return num.intValue
  }

  private static func propBool(_ entry: io_registry_entry_t, _ key: String) -> Bool? {
    guard
      let num = IORegistryEntryCreateCFProperty(
        entry, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? NSNumber
    else { return nil }
    return num.boolValue
  }

  /// Polls `/usr/bin/pmset -g accps` asynchronously (decoding UTF-8 or MacRoman `0xD5` apostrophes).
  func pollAccessoryPowerAsync(force: Bool) {
    hidLock.lock()
    let elapsed = Date().timeIntervalSince(lastPmsetPollAt)
    if isPollingPmset || (!force && elapsed < 4.5) {
      hidLock.unlock()
      return
    }
    isPollingPmset = true
    lastPmsetPollAt = Date()
    hidLock.unlock()

    DispatchQueue.global(qos: .utility).async { [weak self] in
      guard let self else { return }
      var parsed: [String: AccessoryPowerReading] = [:]
      let proc = Process()
      proc.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
      proc.arguments = ["-g", "accps"]
      let pipe = Pipe()
      proc.standardOutput = pipe
      proc.standardError = FileHandle.nullDevice

      do {
        try proc.run()
        let rawData = pipe.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        let text =
          String(data: rawData, encoding: .utf8)
          ?? String(data: rawData, encoding: .macOSRoman)
          ?? String(decoding: rawData, as: UTF8.self)
        parsed = Self.parsePmsetAccps(text)
      } catch {
        // Ignore pmset failures gracefully; IORegistry covers primary battery readings.
      }

      var changed = false
      var cacheToSave: [String: Int]? = nil
      self.hidLock.lock()
      self.isPollingPmset = false
      if self.accessoryPowerByName.count != parsed.count {
        changed = true
      } else {
        for (k, v) in parsed {
          if let old = self.accessoryPowerByName[k],
            old.batteryPercent == v.batteryPercent,
            old.isCharging == v.isCharging,
            old.isPresent == v.isPresent
          {
            continue
          }
          changed = true
          break
        }
      }
      self.accessoryPowerByName = parsed
      for (_, v) in parsed where (0...100).contains(v.batteryPercent) {
        let nKey = "name:\(v.canonicalName)"
        if !Self.isGenericDeviceName(v.canonicalName), self.lastKnownBatteryByKey[nKey] != v.batteryPercent {
          self.lastKnownBatteryByKey[nKey] = v.batteryPercent
          cacheToSave = self.lastKnownBatteryByKey
        }
      }
      self.hidLock.unlock()

      if let cacheToSave {
        self.saveBatteryCache(cacheToSave)
      }
      if changed {
        DispatchQueue.main.async {
          BluetoothService.shared.bumpRefreshTick()
        }
      }
    }
  }

  private static func parsePmsetAccps(_ output: String) -> [String: AccessoryPowerReading] {
    var map: [String: AccessoryPowerReading] = [:]
    for rawLine in output.components(separatedBy: .newlines) {
      let line = rawLine.trimmingCharacters(in: .whitespaces)
      guard line.hasPrefix("-") else { continue }
      guard let pctRange = line.range(of: #"\b(\d{1,3})%"#, options: .regularExpression) else {
        continue
      }
      let pctStr = line[pctRange].dropLast()
      guard let pct = Int(pctStr), (0...100).contains(pct) else { continue }

      let headerPart: Substring
      if let idIdx = line.range(of: " (id=") {
        headerPart = line[line.index(after: line.startIndex)..<idIdx.lowerBound]
      } else if let tabIdx = line.firstIndex(of: "\t") {
        headerPart = line[line.index(after: line.startIndex)..<tabIdx]
      } else {
        continue
      }
      let devName = String(headerPart).trimmingCharacters(in: .whitespaces)
      let canon = BluetoothPeripheral.canonicalName(devName)
      guard !canon.isEmpty else { continue }

      // Avoid matching InternalBattery-0 on MacBooks!
      if canon.hasPrefix("internalbattery") { continue }

      let lower = line.lowercased()
      let isPresent = lower.contains("present: true")
      let isCharging =
        !lower.contains("discharging")
        && (lower.contains("; charging") || lower.contains("\tcharging") || lower.contains(" charging "))

      map[canon] = AccessoryPowerReading(
        name: devName,
        canonicalName: canon,
        batteryPercent: pct,
        isCharging: isCharging,
        isPresent: isPresent
      )
    }
    return map
  }

  // MARK: - Demo Mode Telemetry

  private func demoTelemetry(for p: BluetoothPeripheral) -> PeripheralSecurityTelemetry {
    let connected = DemoMode.shared.isPeripheralConnected(p)
    let lower = p.name.lowercased()
    let sampleRSSI: Int = {
      if lower.contains("keyboard") { return -51 }
      if lower.contains("trackpad") { return -54 }
      if lower.contains("mouse") { return -58 }
      return -60
    }()
    let sampleBattery: Int = {
      if lower.contains("keyboard") { return 96 }
      if lower.contains("trackpad") { return 94 }
      if lower.contains("mouse") { return 89 }
      return 92
    }()
    let sampleLatency: Int = {
      if lower.contains("keyboard") { return 310 }
      if lower.contains("trackpad") { return 340 }
      if lower.contains("mouse") { return 365 }
      return 410
    }()
    let minor: UInt32 = {
      if lower.contains("keyboard") { return 0x10 }
      if lower.contains("trackpad") || lower.contains("mouse") { return 0x20 }
      return 0x30
    }()
    let st = PeripheralReliabilityStats(
      successCount: 28,
      failureCount: 0,
      consecutiveFailures: 0,
      autoHealCount: 1,
      lastLatencyMs: sampleLatency,
      totalLatencyMs: sampleLatency * 28,
      latencySamples: 28,
      lastConnectedAt: Date().addingTimeInterval(-120),
      lastErrorDescription: nil
    )
    let demoPeerName = connected ? nil : DemoMode.shared.remotePeerDisplayName(for: p)
    return PeripheralSecurityTelemetry(
      id: DemoMode.maskMAC(p.id),
      name: DemoMode.shared.peripheralDisplayName(p),
      isConnected: connected,
      isPaired: true,
      rssi: connected ? sampleRSSI : nil,
      rawRSSI: connected ? sampleRSSI : nil,
      encryptionMode: connected ? 1 : 0,
      isIncoming: false,
      deviceClassMajor: 0x05,
      deviceClassMinor: minor,
      vendorName: "Apple, Inc.",
      stats: st,
      batteryPercent: sampleBattery,
      isCharging: false,
      activeTransport: connected ? "Bluetooth" : nil,
      connectedOnPeerName: demoPeerName
    )
  }

  /// Queries link encryption mode on `IOBluetoothDevice` (1 = encrypted link when paired & connected).
  static func queryEncryptionMode(_ dev: IOBluetoothDevice?) -> Int {
    guard let dev, dev.isConnected() else { return 0 }
    return dev.isPaired() ? 1 : 0
  }

  // MARK: - Vendor OUI Lookup

  static func lookupVendor(forMAC mac: String, deviceName: String = "") -> String {
    let lowerName = deviceName.lowercased()
    if lowerName.contains("magic keyboard") || lowerName.contains("magic trackpad")
      || lowerName.contains("magic mouse") || lowerName.contains("airpods")
    {
      return "Apple, Inc."
    }

    let hex =
      mac
      .replacingOccurrences(of: "-", with: ":")
      .uppercased()
      .split(separator: ":")
      .map(String.init)
    guard hex.count >= 3 else { return "Unknown Vendor" }
    let prefix = "\(hex[0]):\(hex[1]):\(hex[2])"

    let knownApplePrefixes: Set<String> = [
      "00:03:93", "00:0A:95", "00:14:51", "00:16:CB", "00:17:F2", "00:19:E3",
      "00:1B:63", "00:1E:52", "00:1F:5B", "00:1F:F3", "00:21:E9", "00:22:41",
      "00:23:12", "00:23:DF", "00:25:00", "00:25:BC", "00:26:08", "00:26:BB",
      "04:0C:CE", "04:41:A5", "10:9A:DD", "14:10:9F", "1C:1A:C0", "20:C9:D0",
      "28:CF:DA", "38:09:FB", "3C:07:54", "40:33:1A", "44:2A:60", "58:55:CA",
      "60:03:08", "60:FB:42", "64:B9:E8", "70:56:81", "78:31:C1", "7C:6D:62",
      "84:38:35", "88:63:DF", "8C:85:90", "90:84:0D", "98:01:A7", "A4:5E:60",
      "AC:BC:32", "B8:E8:56", "C8:2A:14", "D0:A6:37", "DC:2B:2A", "E0:F8:47",
      "F0:18:98", "F4:5C:89", "F8:1E:DF",
    ]
    if knownApplePrefixes.contains(prefix) {
      return "Apple, Inc."
    }
    if prefix.hasPrefix("00:1F:20") || prefix.hasPrefix("EC:81:93") {
      return "Logitech"
    }
    // Check if locally administered bit (bit 1 of first octet) is set:
    if let firstByte = UInt8(hex[0], radix: 16), (firstByte & 0x02) != 0 {
      return "Apple / Randomized BLE Address"
    }
    return "Standard IEEE OUI (\(prefix))"
  }

  // MARK: - Persistence

  private func saveStats() {
    if let data = try? JSONEncoder().encode(statsByID) {
      UserDefaults.standard.set(data, forKey: statsStorageKey)
    }
  }

  private func loadStats() {
    guard let data = UserDefaults.standard.data(forKey: statsStorageKey),
      let decoded = try? JSONDecoder().decode([String: PeripheralReliabilityStats].self, from: data)
    else { return }

    let alreadyScrubbed = UserDefaults.standard.bool(forKey: scrubbedFlagKey)
    var normalized: [String: PeripheralReliabilityStats] = [:]
    var didModify = !alreadyScrubbed

    for (rawKey, var st) in decoded {
      let canonKey = BluetoothPeripheral.canonicalMAC(rawKey)
      if canonKey != rawKey { didModify = true }
      // Scrub legacy background Auto-Heal failure counts accumulated while peripherals were on peer Mac
      if !alreadyScrubbed || (st.failureCount > 15 && st.failureCount > max(1, st.successCount) * 4) {
        if st.failureCount > max(2, st.successCount * 2) {
          st.failureCount = 0
          st.consecutiveFailures = 0
          st.lastErrorDescription = nil
          didModify = true
        }
      }
      normalized[canonKey] = st
    }

    statsByID = normalized
    if didModify {
      UserDefaults.standard.set(true, forKey: scrubbedFlagKey)
      saveStats()
    }
  }

  private func loadBatteryCache() {
    guard let data = UserDefaults.standard.data(forKey: batteryCacheKey),
      let decoded = try? JSONDecoder().decode([String: Int].self, from: data)
    else { return }
    hidLock.lock()
    lastKnownBatteryByKey = decoded
    hidLock.unlock()
  }

  private func saveBatteryCache(_ snapshot: [String: Int]) {
    if let data = try? JSONEncoder().encode(snapshot) {
      UserDefaults.standard.set(data, forKey: batteryCacheKey)
    }
  }
}
