import AppKit
import Foundation
import SwiftUI

// MARK: - Option Enums

enum LeftClickAction: String, CaseIterable, Identifiable {
  case switchDevices, showDashboard, showMenu
  var id: String { rawValue }
  var label: String {
    switch self {
    case .switchDevices: return "Switch peripherals (upstream behavior)"
    case .showDashboard: return "Open dashboard"
    case .showMenu: return "Show menu"
    }
  }
}

enum PartialStateBehavior: String, CaseIterable, Identifiable {
  case smart, pushToPeer, pullFromPeer, warn
  var id: String { rawValue }
  var label: String {
    switch self {
    case .smart: return "Smart (send if peer has none, otherwise take)"
    case .pushToPeer: return "Send everything to the peer Mac"
    case .pullFromPeer: return "Take everything to this Mac"
    case .warn: return "Warn and do nothing (upstream behavior)"
    }
  }
}

enum AutoAcceptScope: String, CaseIterable, Identifiable {
  case whenConnectingOrManaged, onlyWhileConnecting, always
  var id: String { rawValue }
  var label: String {
    switch self {
    case .whenConnectingOrManaged:
      return "Managed peripherals & active switches (recommended)"
    case .onlyWhileConnecting:
      return "Only while BlueSwitch is switching or connecting"
    case .always:
      return "All Bluetooth connection requests"
    }
  }
}

enum DisconnectMethod: String, CaseIterable, Identifiable {
  case unpair, closeConnection
  var id: String { rawValue }
  var label: String {
    switch self {
    case .unpair: return "Unpair from this Mac (recommended for Magic devices)"
    case .closeConnection: return "Close connection only"
    }
  }
}

enum MenuBarIconStyle: String, CaseIterable, Identifiable {
  case asterisk, keyboard, arrows, radiowaves, mouse
  var id: String { rawValue }
  var symbolName: String {
    switch self {
    case .asterisk: return "staroflife.fill"
    case .keyboard: return "keyboard"
    case .arrows: return "arrow.left.arrow.right.circle.fill"
    case .radiowaves: return "dot.radiowaves.left.and.right"
    case .mouse: return "computermouse.fill"
    }
  }
  var label: String {
    switch self {
    case .asterisk: return "Asterisk (classic)"
    case .keyboard: return "Keyboard"
    case .arrows: return "Switch arrows"
    case .radiowaves: return "Radio waves"
    case .mouse: return "Mouse"
    }
  }
}

enum AppearanceMode: String, CaseIterable, Identifiable {
  case system, light, dark
  var id: String { rawValue }
  var label: String { rawValue.capitalized }
  var nsAppearance: NSAppearance? {
    switch self {
    case .system: return nil
    case .light: return NSAppearance(named: .aqua)
    case .dark: return NSAppearance(named: .darkAqua)
    }
  }
}

enum LogLevel: Int, CaseIterable, Identifiable, Comparable {
  case debug = 0, info, warning, error
  var id: Int { rawValue }
  var label: String {
    switch self {
    case .debug: return "Debug"
    case .info: return "Info"
    case .warning: return "Warning"
    case .error: return "Error"
    }
  }
  static func < (a: LogLevel, b: LogLevel) -> Bool { a.rawValue < b.rawValue }
}

/// A keyboard shortcut stored as a Carbon key code plus Cocoa modifier flags.
struct KeyCombo: Equatable {
  var keyCode: Int
  var modifiers: Int

  static let none = KeyCombo(keyCode: -1, modifiers: 0)
  var isEmpty: Bool { keyCode < 0 }

  var encoded: String { "\(keyCode):\(modifiers)" }
  init(keyCode: Int, modifiers: Int) {
    self.keyCode = keyCode
    self.modifiers = modifiers
  }
  init(encoded: String) {
    let parts = encoded.split(separator: ":").compactMap { Int($0) }
    if parts.count == 2 {
      keyCode = parts[0]
      modifiers = parts[1]
    } else {
      keyCode = -1
      modifiers = 0
    }
  }
}

// MARK: - Settings Store

/// Central, persisted store for every configurable BlueSwitch option.
final class AppSettings: ObservableObject {
  static let shared = AppSettings()

  /// Every persisted settings key (used for export / import / reset).
  enum Key: String, CaseIterable {
    // General
    case launchAtLogin, showDockIcon, appearance, menuBarIcon, leftClickAction
    case confirmBeforeSwitching, autoCheckUpdates, autoInstallUpdates, updateRepository
    case autoUpdatePeers, allowRemoteUpdates
    // Switching
    case disconnectMethod, disconnectPollInterval, disconnectMaxAttempts
    case connectRetryCount, connectRetryDelay, settleDelay, pairAttemptTimeout, requireInRange
    case autoAcceptBluetoothRequests, autoAcceptScope, autoAcceptPollInterval
    case partialStateBehavior, autoSyncPeripherals, reclaimOnLaunch
    case releaseOnSleep, reclaimOnWake
    // Network & Security
    case deviceName, listenPort, serviceType, healthCheckTimeout
    case commandTimeout, discoveryEnabled, pairingKey, activePeerID
    case encryptNetworkTraffic, requireEncryptedConnections
    case inputMonitoringGuardEnabled, inputGuardPollInterval
    case autoRemediateKillProcess, autoRemediateDisconnectPeripherals
    case securityModalAlerts, notifyOnSecurityAlert, allowedInputMonitorProcesses
    // Notifications
    case notificationsEnabled, notificationSound, notifyOnSwitch, notifyOnError
    case notifyOnPeerFound, notifyOnRemoteRequest, confirmSentNotification
    case customNotifyTitle, customNotifyBody
    // Shortcuts
    case hotkeysEnabled, hotkeySwitch, hotkeySendToPeer, hotkeyTakeFromPeer
    // Advanced
    case logLevel, maxLogEntries, statusRefreshInterval
  }

  private static let d = UserDefaults.standard
  private static func load<T>(_ k: Key, _ def: T) -> T { d.object(forKey: k.rawValue) as? T ?? def }
  private static func loadEnum<E: RawRepresentable>(_ k: Key, _ def: E) -> E {
    guard let raw = d.object(forKey: k.rawValue) as? E.RawValue else { return def }
    return E(rawValue: raw) ?? def
  }
  private static func save(_ k: Key, _ v: Any) { d.set(v, forKey: k.rawValue) }

  // MARK: General
  @Published var launchAtLogin: Bool = AppSettings.load(.launchAtLogin, false) {
    didSet { Self.save(.launchAtLogin, launchAtLogin) }
  }
  @Published var showDockIcon: Bool = AppSettings.load(.showDockIcon, false) {
    didSet { Self.save(.showDockIcon, showDockIcon) }
  }
  @Published var appearance: AppearanceMode = AppSettings.loadEnum(.appearance, AppearanceMode.system) {
    didSet { Self.save(.appearance, appearance.rawValue) }
  }
  @Published var menuBarIcon: MenuBarIconStyle = AppSettings.loadEnum(.menuBarIcon, MenuBarIconStyle.asterisk) {
    didSet { Self.save(.menuBarIcon, menuBarIcon.rawValue) }
  }
  @Published var leftClickAction: LeftClickAction = AppSettings.loadEnum(
    .leftClickAction, LeftClickAction.switchDevices)
  {
    didSet { Self.save(.leftClickAction, leftClickAction.rawValue) }
  }
  @Published var confirmBeforeSwitching: Bool = AppSettings.load(.confirmBeforeSwitching, false) {
    didSet { Self.save(.confirmBeforeSwitching, confirmBeforeSwitching) }
  }
  @Published var autoCheckUpdates: Bool = AppSettings.load(.autoCheckUpdates, true) {
    didSet { Self.save(.autoCheckUpdates, autoCheckUpdates) }
  }
  @Published var autoInstallUpdates: Bool = AppSettings.load(.autoInstallUpdates, false) {
    didSet { Self.save(.autoInstallUpdates, autoInstallUpdates) }
  }
  @Published var updateRepository: String = AppSettings.load(.updateRepository, "n060dy-007/blue-switch") {
    didSet { Self.save(.updateRepository, updateRepository) }
  }
  @Published var autoUpdatePeers: Bool = AppSettings.load(.autoUpdatePeers, true) {
    didSet { Self.save(.autoUpdatePeers, autoUpdatePeers) }
  }
  @Published var allowRemoteUpdates: Bool = AppSettings.load(.allowRemoteUpdates, true) {
    didSet { Self.save(.allowRemoteUpdates, allowRemoteUpdates) }
  }

  // MARK: Switching
  @Published var disconnectMethod: DisconnectMethod = AppSettings.loadEnum(
    .disconnectMethod, DisconnectMethod.unpair)
  {
    didSet { Self.save(.disconnectMethod, disconnectMethod.rawValue) }
  }
  @Published var disconnectPollInterval: Double = AppSettings.load(.disconnectPollInterval, 0.5) {
    didSet { Self.save(.disconnectPollInterval, disconnectPollInterval) }
  }
  @Published var disconnectMaxAttempts: Int = AppSettings.load(.disconnectMaxAttempts, 5) {
    didSet { Self.save(.disconnectMaxAttempts, disconnectMaxAttempts) }
  }
  @Published var connectRetryCount: Int = AppSettings.load(.connectRetryCount, 4) {
    didSet { Self.save(.connectRetryCount, connectRetryCount) }
  }
  @Published var connectRetryDelay: Double = AppSettings.load(.connectRetryDelay, 1.0) {
    didSet { Self.save(.connectRetryDelay, connectRetryDelay) }
  }
  @Published var settleDelay: Double = AppSettings.load(.settleDelay, 0.8) {
    didSet { Self.save(.settleDelay, settleDelay) }
  }
  @Published var pairAttemptTimeout: Double = AppSettings.load(.pairAttemptTimeout, 5.0) {
    didSet { Self.save(.pairAttemptTimeout, pairAttemptTimeout) }
  }
  @Published var requireInRange: Bool = AppSettings.load(.requireInRange, false) {
    didSet { Self.save(.requireInRange, requireInRange) }
  }
  @Published var autoAcceptBluetoothRequests: Bool = AppSettings.load(.autoAcceptBluetoothRequests, true) {
    didSet { Self.save(.autoAcceptBluetoothRequests, autoAcceptBluetoothRequests) }
  }
  @Published var autoAcceptScope: AutoAcceptScope = AppSettings.loadEnum(
    .autoAcceptScope, AutoAcceptScope.whenConnectingOrManaged)
  {
    didSet { Self.save(.autoAcceptScope, autoAcceptScope.rawValue) }
  }
  @Published var autoAcceptPollInterval: Double = AppSettings.load(.autoAcceptPollInterval, 0.25) {
    didSet { Self.save(.autoAcceptPollInterval, autoAcceptPollInterval) }
  }
  @Published var partialStateBehavior: PartialStateBehavior = AppSettings.loadEnum(
    .partialStateBehavior, PartialStateBehavior.smart)
  {
    didSet { Self.save(.partialStateBehavior, partialStateBehavior.rawValue) }
  }
  @Published var autoSyncPeripherals: Bool = AppSettings.load(.autoSyncPeripherals, false) {
    didSet { Self.save(.autoSyncPeripherals, autoSyncPeripherals) }
  }
  @Published var reclaimOnLaunch: Bool = AppSettings.load(.reclaimOnLaunch, false) {
    didSet { Self.save(.reclaimOnLaunch, reclaimOnLaunch) }
  }
  @Published var releaseOnSleep: Bool = AppSettings.load(.releaseOnSleep, false) {
    didSet { Self.save(.releaseOnSleep, releaseOnSleep) }
  }
  @Published var reclaimOnWake: Bool = AppSettings.load(.reclaimOnWake, false) {
    didSet { Self.save(.reclaimOnWake, reclaimOnWake) }
  }

  // MARK: Network
  @Published var deviceName: String = AppSettings.load(.deviceName, "") {
    didSet { Self.save(.deviceName, deviceName) }
  }
  @Published var listenPort: Int = AppSettings.load(.listenPort, 0) {
    didSet { Self.save(.listenPort, listenPort) }
  }
  @Published var serviceType: String = AppSettings.load(.serviceType, "_blueswitch._tcp") {
    didSet { Self.save(.serviceType, serviceType) }
  }
  @Published var healthCheckTimeout: Double = AppSettings.load(.healthCheckTimeout, 5.0) {
    didSet { Self.save(.healthCheckTimeout, healthCheckTimeout) }
  }
  @Published var commandTimeout: Double = AppSettings.load(.commandTimeout, 10.0) {
    didSet { Self.save(.commandTimeout, commandTimeout) }
  }
  @Published var discoveryEnabled: Bool = AppSettings.load(.discoveryEnabled, true) {
    didSet { Self.save(.discoveryEnabled, discoveryEnabled) }
  }
  @Published var pairingKey: String = AppSettings.load(.pairingKey, "") {
    didSet { Self.save(.pairingKey, pairingKey) }
  }
  @Published var activePeerID: String = AppSettings.load(.activePeerID, "") {
    didSet { Self.save(.activePeerID, activePeerID) }
  }
  @Published var encryptNetworkTraffic: Bool = AppSettings.load(.encryptNetworkTraffic, true) {
    didSet { Self.save(.encryptNetworkTraffic, encryptNetworkTraffic) }
  }
  @Published var requireEncryptedConnections: Bool = AppSettings.load(.requireEncryptedConnections, true) {
    didSet { Self.save(.requireEncryptedConnections, requireEncryptedConnections) }
  }
  @Published var inputMonitoringGuardEnabled: Bool = AppSettings.load(.inputMonitoringGuardEnabled, true) {
    didSet { Self.save(.inputMonitoringGuardEnabled, inputMonitoringGuardEnabled) }
  }
  @Published var inputGuardPollInterval: Double = AppSettings.load(.inputGuardPollInterval, 2.0) {
    didSet { Self.save(.inputGuardPollInterval, inputGuardPollInterval) }
  }
  @Published var autoRemediateKillProcess: Bool = AppSettings.load(.autoRemediateKillProcess, true) {
    didSet { Self.save(.autoRemediateKillProcess, autoRemediateKillProcess) }
  }
  @Published var autoRemediateDisconnectPeripherals: Bool = AppSettings.load(
    .autoRemediateDisconnectPeripherals, true)
  {
    didSet { Self.save(.autoRemediateDisconnectPeripherals, autoRemediateDisconnectPeripherals) }
  }
  @Published var securityModalAlerts: Bool = AppSettings.load(.securityModalAlerts, true) {
    didSet { Self.save(.securityModalAlerts, securityModalAlerts) }
  }
  @Published var notifyOnSecurityAlert: Bool = AppSettings.load(.notifyOnSecurityAlert, true) {
    didSet { Self.save(.notifyOnSecurityAlert, notifyOnSecurityAlert) }
  }
  @Published var allowedInputMonitorProcesses: String = AppSettings.load(
    .allowedInputMonitorProcesses, "")
  {
    didSet { Self.save(.allowedInputMonitorProcesses, allowedInputMonitorProcesses) }
  }

  // MARK: Notifications
  @Published var notificationsEnabled: Bool = AppSettings.load(.notificationsEnabled, true) {
    didSet { Self.save(.notificationsEnabled, notificationsEnabled) }
  }
  @Published var notificationSound: Bool = AppSettings.load(.notificationSound, true) {
    didSet { Self.save(.notificationSound, notificationSound) }
  }
  @Published var notifyOnSwitch: Bool = AppSettings.load(.notifyOnSwitch, true) {
    didSet { Self.save(.notifyOnSwitch, notifyOnSwitch) }
  }
  @Published var notifyOnError: Bool = AppSettings.load(.notifyOnError, true) {
    didSet { Self.save(.notifyOnError, notifyOnError) }
  }
  @Published var notifyOnPeerFound: Bool = AppSettings.load(.notifyOnPeerFound, false) {
    didSet { Self.save(.notifyOnPeerFound, notifyOnPeerFound) }
  }
  @Published var notifyOnRemoteRequest: Bool = AppSettings.load(.notifyOnRemoteRequest, true) {
    didSet { Self.save(.notifyOnRemoteRequest, notifyOnRemoteRequest) }
  }
  @Published var confirmSentNotification: Bool = AppSettings.load(.confirmSentNotification, true) {
    didSet { Self.save(.confirmSentNotification, confirmSentNotification) }
  }
  @Published var customNotifyTitle: String = AppSettings.load(.customNotifyTitle, "New Notification") {
    didSet { Self.save(.customNotifyTitle, customNotifyTitle) }
  }
  @Published var customNotifyBody: String = AppSettings.load(
    .customNotifyBody, "You have a new notification from {device}")
  {
    didSet { Self.save(.customNotifyBody, customNotifyBody) }
  }

  // MARK: Shortcuts
  @Published var hotkeysEnabled: Bool = AppSettings.load(.hotkeysEnabled, true) {
    didSet { Self.save(.hotkeysEnabled, hotkeysEnabled) }
  }
  @Published var hotkeySwitch = KeyCombo(encoded: AppSettings.load(.hotkeySwitch, "")) {
    didSet { Self.save(.hotkeySwitch, hotkeySwitch.encoded) }
  }
  @Published var hotkeySendToPeer = KeyCombo(encoded: AppSettings.load(.hotkeySendToPeer, "")) {
    didSet { Self.save(.hotkeySendToPeer, hotkeySendToPeer.encoded) }
  }
  @Published var hotkeyTakeFromPeer = KeyCombo(encoded: AppSettings.load(.hotkeyTakeFromPeer, "")) {
    didSet { Self.save(.hotkeyTakeFromPeer, hotkeyTakeFromPeer.encoded) }
  }

  // MARK: Advanced
  @Published var logLevel: LogLevel = AppSettings.loadEnum(.logLevel, LogLevel.info) {
    didSet { Self.save(.logLevel, logLevel.rawValue) }
  }
  @Published var maxLogEntries: Int = AppSettings.load(.maxLogEntries, 500) {
    didSet { Self.save(.maxLogEntries, maxLogEntries) }
  }
  @Published var statusRefreshInterval: Double = AppSettings.load(.statusRefreshInterval, 3.0) {
    didSet { Self.save(.statusRefreshInterval, statusRefreshInterval) }
  }

  // MARK: Derived

  /// Name advertised to other Macs (falls back to the system computer name).
  var effectiveDeviceName: String {
    let trimmed = deviceName.trimmingCharacters(in: .whitespaces)
    return trimmed.isEmpty ? (Host.current().localizedName ?? "Mac") : trimmed
  }

  /// Bonjour type normalized to `_name._tcp` form.
  var effectiveServiceType: String {
    var t = serviceType.trimmingCharacters(in: .whitespaces)
    if t.hasSuffix(".") { t.removeLast() }
    return t.isEmpty ? "_blueswitch._tcp" : t
  }

  private init() {
    let trimmedRepo = updateRepository.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmedRepo.isEmpty || trimmedRepo.caseInsensitiveCompare("Fl0p/BlueSwitch") == .orderedSame {
      updateRepository = "n060dy-007/blue-switch"
    }
  }

  /// Removes every stored setting, then reloads defaults by relaunch-free reassignment.
  func resetToDefaults() {
    for k in Key.allCases { Self.d.removeObject(forKey: k.rawValue) }
    launchAtLogin = false; showDockIcon = false; appearance = .system; menuBarIcon = .asterisk
    leftClickAction = .switchDevices; confirmBeforeSwitching = false; autoCheckUpdates = true
    autoInstallUpdates = false
    updateRepository = "n060dy-007/blue-switch"
    autoUpdatePeers = true; allowRemoteUpdates = true
    disconnectMethod = .unpair; disconnectPollInterval = 0.5; disconnectMaxAttempts = 5
    connectRetryCount = 4; connectRetryDelay = 1.0; settleDelay = 0.8; pairAttemptTimeout = 5.0
    requireInRange = false
    autoAcceptBluetoothRequests = true; autoAcceptScope = .whenConnectingOrManaged
    autoAcceptPollInterval = 0.25
    partialStateBehavior = .smart; autoSyncPeripherals = false; reclaimOnLaunch = false
    releaseOnSleep = false; reclaimOnWake = false
    deviceName = ""; listenPort = 0; serviceType = "_blueswitch._tcp"; healthCheckTimeout = 5
    commandTimeout = 10; discoveryEnabled = true; pairingKey = ""
    encryptNetworkTraffic = true; requireEncryptedConnections = true
    inputMonitoringGuardEnabled = true; inputGuardPollInterval = 2.0
    autoRemediateKillProcess = true; autoRemediateDisconnectPeripherals = true
    securityModalAlerts = true; notifyOnSecurityAlert = true; allowedInputMonitorProcesses = ""
    notificationsEnabled = true; notificationSound = true; notifyOnSwitch = true
    notifyOnError = true; notifyOnPeerFound = false; notifyOnRemoteRequest = true
    confirmSentNotification = true; customNotifyTitle = "New Notification"
    customNotifyBody = "You have a new notification from {device}"
    hotkeysEnabled = true; hotkeySwitch = .none; hotkeySendToPeer = .none
    hotkeyTakeFromPeer = .none
    logLevel = .info; maxLogEntries = 500; statusRefreshInterval = 3
  }

  /// Snapshot of all raw stored values (for export).
  func exportDictionary() -> [String: Any] {
    var out: [String: Any] = [:]
    for k in Key.allCases {
      if let v = Self.d.object(forKey: k.rawValue) { out[k.rawValue] = v }
    }
    return out
  }
}
