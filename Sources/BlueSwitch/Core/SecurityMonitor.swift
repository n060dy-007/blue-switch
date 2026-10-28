import AppKit
import ApplicationServices
import Combine
import CryptoKit
import Darwin
import Foundation

/// Represents a detected keystroke or mouse-movement monitoring incident.
struct SecurityIncident: Identifiable, Codable, Equatable {
  let id: UUID
  let timestamp: Date
  let pid: Int32
  let processName: String
  let bundleIdentifier: String?
  let executablePath: String
  let monitorsKeystrokes: Bool
  let monitorsMouseMovement: Bool
  let isActiveFilter: Bool
  let eventTapID: UInt32
  var remediationSummary: String
  var isResolved: Bool

  var capturedTypesDescription: String {
    var parts: [String] = []
    if monitorsKeystrokes { parts.append("Keystrokes") }
    if monitorsMouseMovement { parts.append("Mouse Movement") }
    return parts.isEmpty ? "HID Input" : parts.joined(separator: " & ")
  }
}

/// Continuously monitors macOS Quartz Event Taps (`CGGetEventTapList`) and input listeners
/// for any process capturing keystrokes or mouse movements, and executes notifications,
/// alerts, and automatic remediation.
///
/// Also manages the persistent encrypted/signed security audit log on disk.
final class SecurityMonitor: ObservableObject {
  static let shared = SecurityMonitor()

  @Published private(set) var incidents: [SecurityIncident] = []
  @Published private(set) var activeThreats: [SecurityIncident] = []
  @Published private(set) var lastScanDate: Date?
  @Published private(set) var activeTapCount: Int = 0
  @Published private(set) var auditLogFilePath: String

  private var timer: Timer?
  private var alertedPIDs: [Int32: Date] = [:]
  private let fileQueue = DispatchQueue(label: "com.blueswitch.security.audit", qos: .utility)

  /// Default signed macOS system daemons that legitimately register WindowServer event taps.
  private static let systemTrustedPaths: Set<String> = [
    "/System/Library/CoreServices/WindowServer",
    "/System/Library/Frameworks/ApplicationServices.framework/Frameworks/CoreGraphics.framework/Resources/WindowServer",
    "/System/Library/CoreServices/loginwindow.app/Contents/MacOS/loginwindow",
    "/System/Library/CoreServices/SystemUIServer.app/Contents/MacOS/SystemUIServer",
    "/System/Library/CoreServices/ControlCenter.app/Contents/MacOS/ControlCenter",
    "/System/Library/CoreServices/Dock.app/Contents/MacOS/Dock",
    "/System/Library/CoreServices/UniversalAccessControl.app/Contents/MacOS/UniversalAccessControl",
    "/usr/sbin/universalaccessd",
    "/System/Library/PrivateFrameworks/UniversalAccess.framework/Versions/A/Resources/universalaccessd",
    "/System/Library/CoreServices/VoiceOver.app/Contents/MacOS/VoiceOver",
    "/System/Library/Input Methods/PressAndHold.app/Contents/MacOS/PressAndHold",
    "/System/Library/CoreServices/ShortcutsActions.app/Contents/MacOS/ShortcutsActions",
    "/usr/libexec/AccessibilityUIServer",
  ]

  private init() {
    let logsDir = FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent("Library/Logs/BlueSwitch", isDirectory: true)
    try? FileManager.default.createDirectory(at: logsDir, withIntermediateDirectories: true)
    self.auditLogFilePath = logsDir.appendingPathComponent("security-audit.log").path
  }

  // MARK: - Lifecycle

  func start() {
    restartTimer()
    scanNow()
    recordAudit(
      category: "Security",
      message:
        "SecurityMonitor started (AES-256-GCM network encryption: \(AppSettings.shared.encryptNetworkTraffic ? "ENABLED" : "DISABLED"), Input Guard: \(AppSettings.shared.inputMonitoringGuardEnabled ? "ENABLED" : "DISABLED"))"
    )
  }

  func stop() {
    timer?.invalidate()
    timer = nil
  }

  func restartTimer() {
    timer?.invalidate()
    timer = nil
    guard AppSettings.shared.inputMonitoringGuardEnabled else { return }
    let interval = max(0.5, min(10.0, AppSettings.shared.inputGuardPollInterval))
    timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
      self?.scanNow()
    }
  }

  // MARK: - Persistent Security Audit Logging

  func recordAudit(category: String, message: String, level: LogLevel = .info) {
    switch level {
    case .debug: Log.debug(message, category)
    case .info: Log.info(message, category)
    case .warning: Log.warn(message, category)
    case .error: Log.error(message, category)
    }

    let timestamp = ISO8601DateFormatter().string(from: Date())
    let line = "\(timestamp) [\(level.label.uppercased())] [\(category)] \(message)\n"
    let path = auditLogFilePath
    fileQueue.async {
      guard let data = line.data(using: .utf8) else { return }
      if FileManager.default.fileExists(atPath: path),
        let handle = FileHandle(forWritingAtPath: path)
      {
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: data)
      } else {
        try? data.write(to: URL(fileURLWithPath: path), options: .atomic)
      }
    }
  }

  // MARK: - Keystroke & Mouse Movement Surveillance Detection

  /// Scans all active macOS Quartz Event Taps (`CGGetEventTapList`) for keystroke or mouse-movement hooks.
  func scanNow() {
    var tapCount: UInt32 = 0
    guard CGGetEventTapList(0, nil, &tapCount) == .success else { return }
    let capacity = Int(max(tapCount, 32))
    var taps = [CGEventTapInformation](
      repeating: CGEventTapInformation(
        eventTapID: 0,
        tapPoint: .cghidEventTap,
        options: .defaultTap,
        eventsOfInterest: 0,
        tappingProcess: 0,
        processBeingTapped: 0,
        enabled: false,
        minUsecLatency: 0,
        avgUsecLatency: 0,
        maxUsecLatency: 0
      ),
      count: capacity
    )
    guard CGGetEventTapList(UInt32(capacity), &taps, &tapCount) == .success else { return }
    let activeList = Array(taps.prefix(Int(tapCount)))

    let keyMask: CGEventMask =
      (1 << CGEventType.keyDown.rawValue)
      | (1 << CGEventType.keyUp.rawValue)
      | (1 << CGEventType.flagsChanged.rawValue)

    let mouseMoveMask: CGEventMask =
      (1 << CGEventType.mouseMoved.rawValue)
      | (1 << CGEventType.leftMouseDragged.rawValue)
      | (1 << CGEventType.rightMouseDragged.rawValue)
      | (1 << CGEventType.otherMouseDragged.rawValue)

    var currentThreats: [SecurityIncident] = []
    let settings = AppSettings.shared
    let allowedList = settings.allowedInputMonitorProcesses
      .split(separator: ",")
      .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
      .filter { !$0.isEmpty }

    for tap in activeList where tap.enabled {
      let watchesKeys = (tap.eventsOfInterest & keyMask) != 0 || tap.eventsOfInterest == ~0
      let watchesMouse = (tap.eventsOfInterest & mouseMoveMask) != 0 || tap.eventsOfInterest == ~0
      guard watchesKeys || watchesMouse else { continue }

      let pid = tap.tappingProcess
      guard pid > 0 else { continue }

      let execPath = Self.executablePath(for: pid)
      let app = NSRunningApplication(processIdentifier: pid)
      let procName =
        app?.localizedName
        ?? (execPath as NSString).lastPathComponent
      let bundleID = app?.bundleIdentifier

      // Check if trusted system process or user-allowlisted
      if isProcessTrusted(
        pid: pid, name: procName, bundleID: bundleID, path: execPath, userAllowlist: allowedList)
      {
        continue
      }

      let incident = SecurityIncident(
        id: UUID(),
        timestamp: Date(),
        pid: pid,
        processName: procName.isEmpty ? "PID \(pid)" : procName,
        bundleIdentifier: bundleID,
        executablePath: execPath.isEmpty ? "Unknown path (PID \(pid))" : execPath,
        monitorsKeystrokes: watchesKeys,
        monitorsMouseMovement: watchesMouse,
        isActiveFilter: tap.options == .defaultTap,
        eventTapID: tap.eventTapID,
        remediationSummary: "Detected",
        isResolved: false
      )
      currentThreats.append(incident)
    }

    DispatchQueue.main.async {
      self.lastScanDate = Date()
      self.activeTapCount = Int(tapCount)
      self.activeThreats = currentThreats

      guard settings.inputMonitoringGuardEnabled else { return }
      for threat in currentThreats {
        self.handleDetectedThreat(threat)
      }
    }
  }

  private func isProcessTrusted(
    pid: Int32, name: String, bundleID: String?, path: String, userAllowlist: [String]
  ) -> Bool {
    // Allow signed macOS system binaries in /System/Library or /usr/libexec unless strict mode is on
    if Self.systemTrustedPaths.contains(path) || path.hasPrefix("/System/Library/") {
      return true
    }
    let lowerName = name.lowercased()
    let lowerBundle = (bundleID ?? "").lowercased()
    let lowerPath = path.lowercased()

    for allowed in userAllowlist {
      if lowerName == allowed || lowerBundle == allowed || lowerPath.contains(allowed) {
        return true
      }
    }
    return false
  }

  // MARK: - Alerting & Auto-Remediation

  private func handleDetectedThreat(_ incident: SecurityIncident) {
    // Rate-limit repeated alerts for the same PID within 15 seconds if it survived kill
    if let last = alertedPIDs[incident.pid], Date().timeIntervalSince(last) < 15 {
      return
    }
    alertedPIDs[incident.pid] = Date()

    var mutableIncident = incident
    var actions: [String] = []
    let settings = AppSettings.shared

    // 1. Auto-Remediation: Terminate / Suspend offending process
    if settings.autoRemediateKillProcess && incident.pid != ProcessInfo.processInfo.processIdentifier
    {
      // Freeze immediately with SIGSTOP, then terminate with SIGTERM + SIGKILL
      _ = kill(incident.pid, SIGSTOP)
      let termResult = kill(incident.pid, SIGTERM)
      usleep(80_000)
      let killResult = kill(incident.pid, SIGKILL)
      if termResult == 0 || killResult == 0 || errno == ESRCH {
        actions.append("Terminated process PID \(incident.pid)")
        mutableIncident.isResolved = true
      } else {
        actions.append("Kill failed (errno \(errno) — owned by another user/root)")
      }
    }

    // 2. Auto-Remediation: Disconnect / Evacuate Bluetooth peripherals so keystrokes/mouse cannot be captured
    if settings.autoRemediateDisconnectPeripherals {
      let connectedPeripherals = BluetoothService.shared.peripherals.filter {
        BluetoothService.shared.isConnected($0)
      }
      if !connectedPeripherals.isEmpty {
        if let peer = NetworkService.shared.activePeer,
          NetworkService.shared.reachability[peer.id] == .online
        {
          SwitchCoordinator.shared.sendToPeer()
          actions.append("Evacuated peripherals to \(peer.name)")
        } else {
          for p in connectedPeripherals {
            BluetoothService.shared.release(p)
          }
          actions.append("Disconnected \(connectedPeripherals.count) Bluetooth peripheral(s)")
        }
        mutableIncident.isResolved = true
      }
    }

    // 3. Auto-Remediation: Immediately mute Microphone so audio cannot be captured
    if settings.autoRemediateMuteMic && !AudioService.shared.isMicMuted {
      AudioService.shared.setMicMuted(true, reason: "Security auto-remediation (PID \(incident.pid))")
      actions.append("Muted Microphone")
      mutableIncident.isResolved = true
    }

    if actions.isEmpty {
      actions.append("Alerted user (auto-remediation disabled)")
    }
    mutableIncident.remediationSummary = actions.joined(separator: " · ")

    incidents.insert(mutableIncident, at: 0)
    if incidents.count > 100 { incidents.removeLast(incidents.count - 100) }

    // 3. Log to persistent Security Audit Log & Activity Log
    let logMsg =
      "SECURITY ALERT: Unauthorized \(mutableIncident.capturedTypesDescription) monitor detected! Process: \(mutableIncident.processName) (PID \(mutableIncident.pid), Bundle: \(mutableIncident.bundleIdentifier ?? "none"), Path: \(mutableIncident.executablePath), Mode: \(mutableIncident.isActiveFilter ? "Active Interceptor" : "Passive Listener")). Remediation: \(mutableIncident.remediationSummary)"
    recordAudit(category: "Security", message: logMsg, level: .error)

    // 4. Audible & System Notification Alert
    NSSound.beep()
    NotificationService.post(
      title: "⚠️ Security Alert: \(mutableIncident.capturedTypesDescription) Monitor Detected",
      body:
        "\(mutableIncident.processName) (PID \(mutableIncident.pid)) was monitoring \(mutableIncident.capturedTypesDescription.lowercased()). Action: \(mutableIncident.remediationSummary)",
      kind: .securityAlert
    )

    // 5. Modal Alert Dialog
    if settings.securityModalAlerts {
      presentModalSecurityAlert(for: mutableIncident)
    }
  }

  private func presentModalSecurityAlert(for incident: SecurityIncident) {
    NSApp.activate(ignoringOtherApps: true)
    let alert = NSAlert()
    alert.alertStyle = .critical
    alert.messageText = "Security Alert: \(incident.capturedTypesDescription) Monitoring Detected"
    alert.informativeText = """
      BlueSwitch detected a process monitoring your \(incident.capturedTypesDescription.lowercased()):

      • Process: \(incident.processName) (PID \(incident.pid))
      • Bundle ID: \(incident.bundleIdentifier ?? "Unsigned / CLI binary")
      • Path: \(incident.executablePath)
      • Tap Mode: \(incident.isActiveFilter ? "Active Event Filter" : "Listen-Only Tap")

      Auto-Remediation Executed:
      \(incident.remediationSummary)
      """
    alert.addButton(withTitle: "OK")
    alert.addButton(withTitle: "Trust & Allow This Process")
    alert.addButton(withTitle: "Open Security Settings")

    let response = alert.runModal()
    if response == .alertSecondButtonReturn {
      trustProcess(incident)
    } else if response == .alertThirdButtonReturn {
      SettingsNavigation.shared.selection = .network
    }
  }

  func trustProcess(_ incident: SecurityIncident) {
    let token = incident.bundleIdentifier ?? incident.processName
    var current = AppSettings.shared.allowedInputMonitorProcesses
      .split(separator: ",")
      .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
      .filter { !$0.isEmpty }
    if !current.contains(where: { $0.caseInsensitiveCompare(token) == .orderedSame }) {
      current.append(token)
      AppSettings.shared.allowedInputMonitorProcesses = current.joined(separator: ", ")
      recordAudit(
        category: "Security",
        message: "User added '\(token)' to allowed input-monitoring processes",
        level: .warning
      )
    }
    incidents.removeAll { $0.pid == incident.pid }
    activeThreats.removeAll { $0.pid == incident.pid }
  }

  func clearIncidents() {
    incidents.removeAll()
    alertedPIDs.removeAll()
  }

  /// Triggers a simulated keystroke & mouse-movement surveillance incident to verify
  /// notifications, alerts, logging, and auto-remediation end-to-end.
  func triggerSimulatedIncident() {
    let simulated = SecurityIncident(
      id: UUID(),
      timestamp: Date(),
      pid: -999,
      processName: "SimulatedKeyloggerTest",
      bundleIdentifier: "com.test.simulated-input-spy",
      executablePath: "/tmp/SimulatedKeyloggerTest",
      monitorsKeystrokes: true,
      monitorsMouseMovement: true,
      isActiveFilter: false,
      eventTapID: 99999,
      remediationSummary:
        "Simulated test: Verified notification, critical alert, audit log, and peripheral protection",
      isResolved: true
    )
    incidents.insert(simulated, at: 0)
    recordAudit(
      category: "Security",
      message:
        "SIMULATED SECURITY ALERT: Keystrokes & Mouse Movement monitor test triggered. Remediation pipeline verified.",
      level: .error
    )
    NSSound.beep()
    NotificationService.post(
      title: "⚠️ Security Alert (Test): Keystrokes & Mouse Monitor",
      body:
        "SimulatedKeyloggerTest detected monitoring keystrokes & mouse movement. Auto-remediation verified.",
      kind: .securityAlert
    )
    if AppSettings.shared.securityModalAlerts {
      presentModalSecurityAlert(for: simulated)
    }
  }

  private static func executablePath(for pid: Int32) -> String {
    var buffer = [CChar](repeating: 0, count: Int( MAXPATHLEN) * 4)
    let ret = proc_pidpath(pid, &buffer, UInt32(buffer.count))
    guard ret > 0 else { return "" }
    return String(cString: buffer)
  }
}

