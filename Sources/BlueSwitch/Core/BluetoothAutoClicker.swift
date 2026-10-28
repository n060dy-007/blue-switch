import AppKit
import ApplicationServices
import Combine
import Foundation

/// Watches for macOS Bluetooth pairing / connection confirmation dialogs and notification
/// banners (from `BluetoothUIServer`, `BluetoothUIService`, `NotificationCenter`, etc.)
/// and automatically clicks the "Connect" / "Allow" action using the Accessibility API.
final class BluetoothAutoClicker: ObservableObject {
  static let shared = BluetoothAutoClicker()

  @Published private(set) var isAccessibilityTrusted: Bool = AXIsProcessTrusted()
  @Published private(set) var autoClickCount: Int = 0
  @Published private(set) var lastAutoClickedAt: Date?
  @Published private(set) var lastAutoClickedSummary: String?

  private var timer: Timer?
  private var boostTimer: Timer?
  private var activeUntil: Date = .distantPast
  private var suppressUntil: Date = .distantPast
  private var lastClickTime: Date = .distantPast
  private var activeDeviceNames: Set<String> = []
  private var workspaceObservers: [NSObjectProtocol] = []
  private var settings: AppSettings { .shared }

  /// Dedicated Bluetooth pairing UI processes where any connection dialog is a Bluetooth prompt.
  private static let dedicatedBluetoothBundleIDs: Set<String> = [
    "com.apple.BluetoothUIServer",
    "com.apple.BluetoothUIService",
    "com.apple.BluetoothSetupAssistant",
  ]

  private static let dedicatedBluetoothProcessNames: Set<String> = [
    "BluetoothUIServer",
    "BluetoothUIService",
    "BluetoothSetupAssistant",
  ]

  /// General notification / alert host processes where we first verify the banner/dialog is a Bluetooth prompt.
  private static let notificationHostBundleIDs: Set<String> = [
    "com.apple.notificationcenterui",
    "com.apple.UserNotificationCenter",
    "com.apple.coreservices.uiagent",
    "com.apple.systempreferences",
    "com.apple.Preferences",
  ]

  /// Button titles / action descriptions that accept a Bluetooth connection request.
  private static let acceptLabels: Set<String> = [
    "connect", "allow", "pair", "use", "accept", "continue",
    // Common localized labels for "Connect" / "Allow" in BluetoothUIServer.loctable
    "接続", "許可", "ペアリング",
    "verbinden", "erlauben",
    "connecter", "se connecter", "autoriser",
    "conectar", "permitir",
    "connetti", "consenti",
    "연결", "허용",
    "连接", "允许", "連線", "允許",
    "verbind", "anslut", "tilslut", "kob til", "połącz", "připojit", "подключить",
  ]

  /// Button titles / action descriptions that must NEVER be clicked.
  private static let rejectLabels: Set<String> = [
    "cancel", "don't allow", "don’t allow", "ignore", "ignore this device",
    "forget", "deny", "close", "clear", "clear all", "later", "learn more",
    "learn more…", "options", "ok", "キャンセル", "許可しない", "無視",
    "abbrechen", "annuler", "cancelar", "annulla", "취소", "取消",
  ]

  /// Phrases in a notification banner or dialog that identify a macOS Bluetooth connection request.
  private static let bluetoothPromptPhrases: [String] = [
    "connection request",
    "pairing request",
    "security request",
    "unsecured bluetooth",
    "would you like to use",
    "would you like to connect",
    "to connect to the device",
    "click connect",
    "click use",
    "magic keyboard found",
    "magic mouse found",
    "magic trackpad found",
    "接続リクエスト",
    "verbindungsanfrage",
    "demande de connexion",
    "solicitud de conexión",
  ]

  private init() {}

  // MARK: - Lifecycle

  func start() {
    refreshPermission()
    setupWorkspaceObservers()
    restartTimer()
  }

  func stop() {
    timer?.invalidate()
    timer = nil
    boostTimer?.invalidate()
    boostTimer = nil
    for obs in workspaceObservers {
      NSWorkspace.shared.notificationCenter.removeObserver(obs)
    }
    workspaceObservers.removeAll()
  }

  func restartTimer() {
    timer?.invalidate()
    timer = nil
    guard settings.autoAcceptBluetoothRequests else { return }
    let interval = max(0.1, min(2.0, settings.autoAcceptPollInterval))
    timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
      self?.tick()
    }
  }

  // MARK: - Permissions

  @discardableResult
  func refreshPermission() -> Bool {
    let trusted = AXIsProcessTrusted()
    if trusted != isAccessibilityTrusted {
      isAccessibilityTrusted = trusted
    }
    return trusted
  }

  /// Triggers the macOS Accessibility permission prompt if not yet trusted.
  func requestPermission() {
    let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
    let trusted = AXIsProcessTrustedWithOptions(options)
    isAccessibilityTrusted = trusted
    Log.info("Requested Accessibility permission (trusted: \(trusted))", "Bluetooth")
  }

  func openAccessibilitySettings() {
    if let url = URL(
      string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
    {
      NSWorkspace.shared.open(url)
    }
  }

  // MARK: - Active / Suppressed Windows

  /// Called when THIS Mac begins connecting peripherals so we poll at high frequency (150ms)
  /// and clear any release suppression.
  func beginConnectingWindow(for peripherals: [BluetoothPeripheral], duration: TimeInterval = 18) {
    DispatchQueue.main.async {
      self.suppressUntil = .distantPast
      self.activeUntil = max(self.activeUntil, Date().addingTimeInterval(duration))
      for p in peripherals {
        self.activeDeviceNames.insert(p.name.lowercased())
        if !p.alias.isEmpty { self.activeDeviceNames.insert(p.alias.lowercased()) }
        self.activeDeviceNames.insert(p.id.lowercased())
      }
      self.startBoostTimer()
      self.scanAndClickNow()
    }
  }

  /// Called when THIS Mac releases peripherals to another Mac so we don't accidentally
  /// click "Connect" on a prompt that pops up on the releasing Mac.
  func suppressAfterRelease(duration: TimeInterval = 10) {
    DispatchQueue.main.async {
      self.activeUntil = .distantPast
      self.activeDeviceNames.removeAll()
      self.suppressUntil = Date().addingTimeInterval(duration)
      self.boostTimer?.invalidate()
      self.boostTimer = nil
    }
  }

  var isActivelyConnecting: Bool {
    Date() < activeUntil && Date() >= suppressUntil
  }

  private func startBoostTimer() {
    boostTimer?.invalidate()
    boostTimer = Timer.scheduledTimer(withTimeInterval: 0.15, repeats: true) { [weak self] t in
      guard let self else {
        t.invalidate()
        return
      }
      if Date() >= self.activeUntil {
        t.invalidate()
        self.boostTimer = nil
        self.activeDeviceNames.removeAll()
        return
      }
      self.tick()
    }
  }

  private func setupWorkspaceObservers() {
    guard workspaceObservers.isEmpty else { return }
    let nc = NSWorkspace.shared.notificationCenter
    let handler: (Notification) -> Void = { [weak self] note in
      guard let self, self.settings.autoAcceptBluetoothRequests else { return }
      guard
        let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
      else { return }
      let bundleID = app.bundleIdentifier ?? ""
      let name = app.localizedName ?? ""
      if Self.dedicatedBluetoothBundleIDs.contains(bundleID)
        || Self.dedicatedBluetoothProcessNames.contains(name)
        || Self.notificationHostBundleIDs.contains(bundleID)
      {
        // Scan shortly after launch/activation so the window has time to populate its AX tree.
        for delay in [0.08, 0.25, 0.5, 0.9] {
          DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            self?.tick()
          }
        }
      }
    }
    workspaceObservers.append(
      nc.addObserver(
        forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main,
        using: handler))
    workspaceObservers.append(
      nc.addObserver(
        forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main,
        using: handler))
  }

  // MARK: - Scanning & Clicking

  /// Immediate scan (also callable from UI "Scan & Click Now").
  @discardableResult
  func scanAndClickNow(forceScope: Bool = false) -> Bool {
    guard refreshPermission() else { return false }
    if !forceScope {
      guard Date() >= suppressUntil else { return false }
      if settings.autoAcceptScope == .onlyWhileConnecting && !isActivelyConnecting {
        return false
      }
    }
    return scanRunningProcesses(forceScope: forceScope)
  }

  private func tick() {
    guard settings.autoAcceptBluetoothRequests else { return }
    // Cooldown of 0.5s after a successful click so closing animations don't re-trigger.
    guard Date().timeIntervalSince(lastClickTime) >= 0.5 else { return }
    _ = scanAndClickNow(forceScope: false)
  }

  private func scanRunningProcesses(forceScope: Bool) -> Bool {
    let apps = NSWorkspace.shared.runningApplications
    let managedNames = currentManagedTokens()

    // 1. Check dedicated Bluetooth UI processes first (BluetoothUIServer, BluetoothUIService, etc.).
    for app in apps {
      let bundleID = app.bundleIdentifier ?? ""
      let procName = app.localizedName ?? app.executableURL?.lastPathComponent ?? ""
      if Self.dedicatedBluetoothBundleIDs.contains(bundleID)
        || Self.dedicatedBluetoothProcessNames.contains(procName)
      {
        if inspectDedicatedBluetoothApp(app, managedNames: managedNames, forceScope: forceScope) {
          return true
        }
      }
    }

    // 2. Check NotificationCenter / UserNotificationCenter / CoreServicesUIAgent banners & alerts.
    for app in apps {
      guard let bundleID = app.bundleIdentifier,
        Self.notificationHostBundleIDs.contains(bundleID)
      else { continue }
      if inspectNotificationHostApp(app, managedNames: managedNames, forceScope: forceScope) {
        return true
      }
    }

    return false
  }

  private func currentManagedTokens() -> Set<String> {
    var tokens = activeDeviceNames
    for p in BluetoothService.shared.peripherals {
      let n = p.name.trimmingCharacters(in: .whitespaces).lowercased()
      if !n.isEmpty { tokens.insert(n) }
      let a = p.alias.trimmingCharacters(in: .whitespaces).lowercased()
      if !a.isEmpty { tokens.insert(a) }
      tokens.insert(p.id.lowercased())
      tokens.insert(p.id.replacingOccurrences(of: "-", with: ":").lowercased())
    }
    return tokens
  }

  // MARK: - Dedicated Bluetooth UI Apps (BluetoothUIServer / BluetoothUIService)

  private func inspectDedicatedBluetoothApp(
    _ app: NSRunningApplication, managedNames: Set<String>, forceScope: Bool
  ) -> Bool {
    let appEl = AXUIElementCreateApplication(app.processIdentifier)
    let windows = collectRootWindows(of: appEl)
    guard !windows.isEmpty else { return false }

    for window in windows {
      let texts = collectTexts(in: window, maxDepth: 10)
      let joined = texts.joined(separator: " ").lowercased()

      // Don't click "OK" on a failure alert ("Connection to this device was unsuccessful").
      if joined.contains("unsuccessful") { continue }

      if !forceScope && settings.autoAcceptScope == .whenConnectingOrManaged && !isActivelyConnecting
      {
        let matchesManaged = managedNames.contains { !$0.isEmpty && joined.contains($0) }
        let matchesGenericBT = Self.bluetoothPromptPhrases.contains { joined.contains($0) }
        if !matchesManaged && !matchesGenericBT { continue }
      }

      // First try explicit accept button ("Connect", "Allow", "Pair", "Use", etc.)
      if let (button, label) = findAcceptButton(in: window, maxDepth: 10) {
        if AXUIElementPerformAction(button, kAXPressAction as CFString) == .success {
          recordClick(source: app.localizedName ?? "BluetoothUIServer", label: label, texts: texts)
          return true
        }
      }

      // Fallback: if BluetoothUIServer window has a default button and also a cancel button,
      // the default button is "Connect" (e.g. JustWorksWindowController button 36).
      if let defaultBtn: AXUIElement = copyAttribute(window, kAXDefaultButtonAttribute),
        role(of: defaultBtn) == (kAXButtonRole as String)
      {
        let title = (stringAttribute(defaultBtn, kAXTitleAttribute) ?? "").trimmingCharacters(
          in: .whitespaces)
        let lower = title.lowercased()
        let hasCancel: AXUIElement? = copyAttribute(window, kAXCancelButtonAttribute)
        if !Self.rejectLabels.contains(lower) && (hasCancel != nil || Self.acceptLabels.contains(lower))
        {
          if AXUIElementPerformAction(defaultBtn, kAXPressAction as CFString) == .success {
            recordClick(
              source: app.localizedName ?? "BluetoothUIServer",
              label: title.isEmpty ? "Default (Connect)" : title, texts: texts)
            return true
          }
        }
      }
    }
    return false
  }

  // MARK: - NotificationCenter / Alert Host Apps

  private func inspectNotificationHostApp(
    _ app: NSRunningApplication, managedNames: Set<String>, forceScope: Bool
  ) -> Bool {
    let appEl = AXUIElementCreateApplication(app.processIdentifier)
    let windows = collectRootWindows(of: appEl)
    guard !windows.isEmpty else { return false }

    for window in windows {
      // Find candidate alert/banner containers (or check the window itself).
      let containers = findAlertContainers(in: window, maxDepth: 8)
      let targets = containers.isEmpty ? [window] : containers

      for container in targets {
        let texts = collectTexts(in: container, maxDepth: 10)
        guard !texts.isEmpty else { continue }
        let joined = texts.joined(separator: " ").lowercased()

        // Never auto-click notifications posted by BlueSwitch itself.
        if joined.contains("blueswitch") || joined.contains("peripherals sent")
          || joined.contains("peripherals received")
        {
          continue
        }

        let hasPromptPhrase = Self.bluetoothPromptPhrases.contains { joined.contains($0) }
        let matchesManaged = managedNames.contains { !$0.isEmpty && joined.contains($0) }
        let hasBluetoothWord = joined.contains("bluetooth")
        let isBluetoothPrompt =
          hasPromptPhrase
          || (hasBluetoothWord && (matchesManaged || joined.contains("connect") || joined.contains("pair")))
          || (isActivelyConnecting && matchesManaged)

        guard isBluetoothPrompt else { continue }

        if !forceScope && settings.autoAcceptScope == .whenConnectingOrManaged
          && !isActivelyConnecting && !matchesManaged && !hasPromptPhrase
        {
          continue
        }

        // Method 1: NotificationCenter banners expose actions ("Connect", "Allow") as custom AXActions
        // on the alert element itself (even when the button is not hovered/expanded).
        if let actionLabel = performCustomAcceptAction(in: container, maxDepth: 8) {
          recordClick(
            source: app.localizedName ?? "NotificationCenter", label: actionLabel, texts: texts)
          return true
        }

        // Method 2: Standard AXButton inside the alert/banner or dialog.
        if let (button, label) = findAcceptButton(in: container, maxDepth: 10) {
          if AXUIElementPerformAction(button, kAXPressAction as CFString) == .success {
            recordClick(
              source: app.localizedName ?? "NotificationCenter", label: label, texts: texts)
            return true
          }
        }
      }
    }
    return false
  }

  // MARK: - AX Tree Helpers

  private func collectRootWindows(of appEl: AXUIElement) -> [AXUIElement] {
    var result: [AXUIElement] = []
    if let windows: [AXUIElement] = copyAttribute(appEl, kAXWindowsAttribute) {
      result.append(contentsOf: windows)
    }
    if let mainWin: AXUIElement = copyAttribute(appEl, kAXMainWindowAttribute),
      !result.contains(where: { CFEqual($0, mainWin) })
    {
      result.append(mainWin)
    }
    if let focusedWin: AXUIElement = copyAttribute(appEl, kAXFocusedWindowAttribute),
      !result.contains(where: { CFEqual($0, focusedWin) })
    {
      result.append(focusedWin)
    }
    if let children: [AXUIElement] = copyAttribute(appEl, kAXChildrenAttribute) {
      for child in children where !result.contains(where: { CFEqual($0, child) }) {
        let r = role(of: child)
        if r == (kAXWindowRole as String) || r == "AXSystemDialog" || r == (kAXSheetRole as String)
        {
          result.append(child)
        }
      }
    }
    return result
  }

  private func findAlertContainers(in root: AXUIElement, maxDepth: Int) -> [AXUIElement] {
    var containers: [AXUIElement] = []
    func walk(_ el: AXUIElement, depth: Int) {
      guard depth <= maxDepth else { return }
      let subrole = stringAttribute(el, kAXSubroleAttribute) ?? ""
      let r = role(of: el) ?? ""
      if subrole.contains("NotificationCenterAlert")
        || subrole.contains("NotificationCenterBanner")
        || r == (kAXSheetRole as String)
        || r == "AXDialog"
        || r == "AXSystemDialog"
      {
        containers.append(el)
        return
      }
      if let children: [AXUIElement] = copyAttribute(el, kAXChildrenAttribute) {
        for c in children { walk(c, depth: depth + 1) }
      }
    }
    walk(root, depth: 0)
    return containers
  }

  private func collectTexts(in root: AXUIElement, maxDepth: Int) -> [String] {
    var out: [String] = []
    func walk(_ el: AXUIElement, depth: Int) {
      guard depth <= maxDepth else { return }
      let r = role(of: el) ?? ""
      // Skip button labels when collecting prompt body text so a button titled "Connect" alone doesn't trigger.
      if r != (kAXButtonRole as String) {
        for attr in [
          kAXValueAttribute, kAXTitleAttribute, kAXDescriptionAttribute, kAXHelpAttribute,
        ] {
          if let s = stringAttribute(el, attr)?.trimmingCharacters(in: .whitespacesAndNewlines),
            !s.isEmpty
          {
            out.append(s)
          }
        }
      }
      if let children: [AXUIElement] = copyAttribute(el, kAXChildrenAttribute) {
        for c in children { walk(c, depth: depth + 1) }
      }
    }
    walk(root, depth: 0)
    return out
  }

  private func findAcceptButton(in root: AXUIElement, maxDepth: Int) -> (AXUIElement, String)? {
    func walk(_ el: AXUIElement, depth: Int) -> (AXUIElement, String)? {
      guard depth <= maxDepth else { return nil }
      let r = role(of: el) ?? ""
      // Never click checkboxes (e.g., "Ignore this device" in BluetoothUIServer).
      if r == (kAXCheckBoxRole as String) { return nil }

      if r == (kAXButtonRole as String) || r == "AXMenuItem" {
        let candidates = [
          stringAttribute(el, kAXTitleAttribute),
          stringAttribute(el, kAXDescriptionAttribute),
          stringAttribute(el, kAXValueAttribute),
        ].compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }

        for label in candidates {
          let lower = label.lowercased()
          if Self.rejectLabels.contains(lower) { continue }
          if Self.acceptLabels.contains(lower) {
            return (el, label)
          }
        }
      }

      if let children: [AXUIElement] = copyAttribute(el, kAXChildrenAttribute) {
        for c in children {
          if let found = walk(c, depth: depth + 1) { return found }
        }
      }
      return nil
    }
    return walk(root, depth: 0)
  }

  private func performCustomAcceptAction(in root: AXUIElement, maxDepth: Int) -> String? {
    func walk(_ el: AXUIElement, depth: Int) -> String? {
      guard depth <= maxDepth else { return nil }
      var namesRef: CFArray?
      if AXUIElementCopyActionNames(el, &namesRef) == .success,
        let names = namesRef as? [String]
      {
        for rawName in names {
          // Skip standard press/cancel/showmenu actions; we're looking for custom notification actions.
          if rawName == (kAXPressAction as String) || rawName == (kAXCancelAction as String)
            || rawName == (kAXShowMenuAction as String)
          {
            continue
          }
          var descRef: CFString?
          _ = AXUIElementCopyActionDescription(el, rawName as CFString, &descRef)
          let desc = ((descRef as String?) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)

          // NotificationCenter custom actions often format rawName as "Name:Connect\nTarget:0x0\n..."
          let parsedName = Self.extractActionLabel(from: rawName)
          let candidates = [desc, parsedName].filter { !$0.isEmpty }

          for candidate in candidates {
            let lower = candidate.lowercased()
            if Self.rejectLabels.contains(lower) { continue }
            if Self.acceptLabels.contains(lower) {
              if AXUIElementPerformAction(el, rawName as CFString) == .success {
                return candidate
              }
            }
          }
        }
      }

      if let children: [AXUIElement] = copyAttribute(el, kAXChildrenAttribute) {
        for c in children {
          if let hit = walk(c, depth: depth + 1) { return hit }
        }
      }
      return nil
    }
    return walk(root, depth: 0)
  }

  private static func extractActionLabel(from rawAction: String) -> String {
    if rawAction.hasPrefix("Name:") {
      let afterPrefix = rawAction.dropFirst("Name:".count)
      if let newline = afterPrefix.firstIndex(of: "\n") {
        return String(afterPrefix[..<newline]).trimmingCharacters(in: .whitespaces)
      }
      return String(afterPrefix).trimmingCharacters(in: .whitespaces)
    }
    return rawAction.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private func role(of el: AXUIElement) -> String? {
    stringAttribute(el, kAXRoleAttribute)
  }

  private func stringAttribute(_ el: AXUIElement, _ attr: String) -> String? {
    var val: CFTypeRef?
    guard AXUIElementCopyAttributeValue(el, attr as CFString, &val) == .success, let val else {
      return nil
    }
    if CFGetTypeID(val) == CFStringGetTypeID() {
      return (val as! CFString) as String
    }
    return nil
  }

  private func copyAttribute<T>(_ el: AXUIElement, _ attr: String) -> T? {
    var val: CFTypeRef?
    guard AXUIElementCopyAttributeValue(el, attr as CFString, &val) == .success, let val else {
      return nil
    }
    return val as? T
  }

  private func recordClick(source: String, label: String, texts: [String]) {
    lastClickTime = Date()
    autoClickCount += 1
    lastAutoClickedAt = lastClickTime
    let snippet = texts.first { !$0.isEmpty } ?? "Bluetooth prompt"
    lastAutoClickedSummary = "\(label) (\(source): \(snippet))"
    Log.info("Auto-clicked \"\(label)\" on Bluetooth prompt in \(source) (\(snippet))", "Bluetooth")
  }
}

