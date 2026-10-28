import AppKit
import Combine
import CoreBluetooth
import Foundation
import IOBluetooth

/// Owns the list of managed peripherals and performs connect / release operations.
final class BluetoothService: NSObject, ObservableObject {
  static let shared = BluetoothService()

  private enum Constants {
    static let storageKey = "peripherals"
    static let invalidRSSI: BluetoothHCIRSSIValue = 127
  }

  /// Tracks live state of an in-flight `IOBluetoothDevicePair` run-loop session.
  private final class PairSession {
    let id: String
    var started = false
    var handshaking = false
    var finished = false
    var error: IOReturn = kIOReturnSuccess
    var extendedDeadline = false

    init(id: String) { self.id = id }
  }

  @Published private(set) var peripherals: [BluetoothPeripheral] = [] {
    didSet {
      save()
      peripheralsChanged.send(peripherals)
    }
  }
  /// Paired devices on this Mac that are not yet managed.
  @Published private(set) var availablePeripherals: [BluetoothPeripheral] = []
  @Published private(set) var isPoweredOn = true
  /// Bumped on every refresh so views re-read live `isConnected` state.
  @Published private(set) var refreshTick = 0
  /// IDs currently being connected (for spinners in the UI).
  @Published private(set) var busyIDs: Set<String> = []
  /// macOS Bluetooth privacy permission for this app.
  @Published private(set) var authorization: CBManagerAuthorization = CBManager.authorization

  let peripheralsChanged = PassthroughSubject<[BluetoothPeripheral], Never>()

  private let queue = DispatchQueue(label: "com.blueswitch.bluetooth", qos: .userInitiated)
  private var activePairs: [String: IOBluetoothDevicePair] = [:]
  private var pairSessions: [String: PairSession] = [:]
  private var refreshTimer: Timer?
  private var centralManager: CBCentralManager?
  private var settings: AppSettings { .shared }

  private override init() {
    super.init()
    load()
  }

  // MARK: - Permission

  var isAuthorized: Bool { authorization == .allowedAlways }

  var authorizationText: String {
    switch authorization {
    case .allowedAlways: return "Allowed"
    case .denied: return "Denied"
    case .restricted: return "Restricted by system policy"
    case .notDetermined: return "Not requested yet"
    @unknown default: return "Unknown"
    }
  }

  /// Creating a CBCentralManager is what makes macOS show the Bluetooth permission prompt
  /// (IOBluetooth alone silently returns no devices when unauthorized). Same as upstream.
  func requestAccess() {
    authorization = CBManager.authorization
    Log.info("Bluetooth permission: \(authorizationText)", "Bluetooth")
    if centralManager == nil {
      centralManager = CBCentralManager(delegate: self, queue: .main)
    }
    refresh()
  }

  func openPrivacySettings() {
    let url = URL(
      string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Bluetooth")!
    NSWorkspace.shared.open(url)
  }

  // MARK: - Status

  func startMonitoring() {
    refreshTimer?.invalidate()
    let interval = max(1.0, settings.statusRefreshInterval)
    refreshTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) {
      [weak self] _ in
      self?.refreshStatusOnly()
    }
  }

  func isConnected(_ p: BluetoothPeripheral) -> Bool {
    IOBluetoothDevice(addressString: p.id)?.isConnected() ?? false
  }

  var enabledPeripherals: [BluetoothPeripheral] { peripherals.filter(\.isEnabled) }

  var connectionState: PeripheralConnectionState {
    let list = enabledPeripherals
    guard !list.isEmpty else { return .none }
    let connected = list.filter { isConnected($0) }.count
    if connected == list.count { return .allConnected }
    if connected == 0 { return .allDisconnected }
    return .partial
  }

  private func refreshStatusOnly() {
    isPoweredOn = IOBluetoothHostController.default()?.powerState == kBluetoothHCIPowerStateON
    refreshTick &+= 1
  }

  /// Re-reads paired devices and connection state.
  func refresh() {
    refreshStatusOnly()
    authorization = CBManager.authorization
    queue.async { [weak self] in
      guard let self else { return }
      let paired = (IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice]) ?? []
      if paired.isEmpty {
        Log.debug(
          "IOBluetooth returned no paired devices (permission: \(self.authorizationText))",
          "Bluetooth")
      }
      let list = paired.compactMap { dev -> BluetoothPeripheral? in
        guard let addr = dev.addressString else { return nil }
        return BluetoothPeripheral(id: addr, name: dev.name ?? "Unknown Device")
      }
      DispatchQueue.main.async {
        let managed = Set(self.peripherals.map(\.id))
        self.availablePeripherals = list.filter { !managed.contains($0.id) }
      }
    }
  }

  // MARK: - List Management

  func add(_ p: BluetoothPeripheral) {
    guard !peripherals.contains(where: { $0.id == p.id }) else { return }
    peripherals.append(p)
    availablePeripherals.removeAll { $0.id == p.id }
    Log.info("Added peripheral \(p.displayName)", "Bluetooth")
  }

  func remove(_ p: BluetoothPeripheral) {
    peripherals.removeAll { $0.id == p.id }
    Log.info("Removed peripheral \(p.displayName) from list", "Bluetooth")
    refresh()
  }

  func removeAll() {
    peripherals.removeAll()
    refresh()
  }

  func update(_ p: BluetoothPeripheral) {
    guard let i = peripherals.firstIndex(where: { $0.id == p.id }) else { return }
    peripherals[i] = p
  }

  func move(from source: IndexSet, to destination: Int) {
    peripherals.move(fromOffsets: source, toOffset: destination)
  }

  /// Replaces the list with one received from a peer (keeps local alias/enabled when present).
  func replace(with incoming: [BluetoothPeripheral]) {
    let local = Dictionary(uniqueKeysWithValues: peripherals.map { ($0.id, $0) })
    peripherals = incoming.map { p in
      var merged = p
      if let l = local[p.id] {
        if merged.alias.isEmpty { merged.alias = l.alias }
      }
      return merged
    }
    refresh()
  }

  /// Adopts any peripherals sent in a peer's switch request that aren't registered locally yet.
  func adoptPeripheralsIfMissing(_ incoming: [BluetoothPeripheral]?) {
    guard let incoming, !incoming.isEmpty else { return }
    let existing = Set(peripherals.map { $0.id.lowercased() })
    var added = 0
    for p in incoming where !existing.contains(p.id.lowercased()) {
      peripherals.append(p)
      added += 1
    }
    if added > 0 {
      Log.info("Auto-registered \(added) peripheral(s) from peer switch request", "Bluetooth")
      refresh()
    }
  }

  // MARK: - Connect

  /// Connects a single peripheral to this Mac, retrying according to settings.
  func connect(_ p: BluetoothPeripheral, completion: ((Bool) -> Void)? = nil) {
    connectPeripherals([p]) { success, _ in
      completion?(success == 1)
    }
  }

  /// Connects all enabled peripherals sequentially in round-robin passes so Bluetooth HCI
  /// page/pair requests never collide. Completion receives `(succeededCount, totalCount)`.
  func connectAll(completion: ((Int, Int) -> Void)? = nil) {
    let list = enabledPeripherals
    guard !list.isEmpty else {
      completion?(0, 0)
      return
    }
    connectPeripherals(list, completion: completion)
  }

  private func connectPeripherals(
    _ list: [BluetoothPeripheral], completion: ((Int, Int) -> Void)?
  ) {
    guard isPoweredOn || IOBluetoothHostController.default()?.powerState == kBluetoothHCIPowerStateON
    else {
      Log.error("Bluetooth is turned off", "Bluetooth")
      completion?(0, list.count)
      return
    }

    let attempts = max(1, settings.connectRetryCount + 1)
    let retryDelay = max(0.2, settings.connectRetryDelay)
    let settle = max(0, settings.settleDelay)
    let pairTimeout = max(2.5, settings.pairAttemptTimeout)

    // Activate high-frequency auto-clicker for the expected duration of this connect batch.
    let estimatedWindow = settle + Double(attempts * list.count) * (pairTimeout + retryDelay) + 5.0
    BluetoothAutoClicker.shared.beginConnectingWindow(for: list, duration: estimatedWindow)

    DispatchQueue.main.async {
      for p in list where !self.isConnected(p) {
        self.busyIDs.insert(p.id)
      }
    }

    queue.async { [weak self] in
      guard let self else { return }

      // Wait for peripherals to finish tearing down their radio link with the previous Mac.
      if settle > 0 {
        Thread.sleep(forTimeInterval: settle)
      }

      // Round-robin passes across all requested peripherals so we never run two simultaneous
      // HCI page/pair operations and one slow/off device doesn't block the others for all retries.
      for pass in 1...attempts {
        let pending = list.filter { !self.isConnected($0) }
        if pending.isEmpty { break }

        for (idx, p) in pending.enumerated() {
          if self.isConnected(p) {
            self.markFinished(p, connected: true)
            continue
          }

          let connected = self.performConnectPass(
            for: p, pass: pass, totalPasses: attempts, pairTimeout: pairTimeout)
          if connected {
            let paired = IOBluetoothDevice(addressString: p.id)?.isPaired() ?? true
            SecurityMonitor.shared.recordAudit(
              category: "Bluetooth",
              message:
                "Connected \(p.displayName) (\(p.id)) on attempt \(pass)/\(attempts) [Link Security: \(paired ? "Paired & Encrypted (Bluetooth Link Key)" : "Unpaired")]",
              level: .info
            )
            DispatchQueue.main.async {
              SecurityMonitor.shared.scanNow()
            }
            self.markFinished(p, connected: true)
          } else {
            Log.debug(
              "Attempt \(pass)/\(attempts) for \(p.displayName) did not complete", "Bluetooth")
          }

          // Small pause between consecutive devices to avoid HCI controller busy errors.
          if idx + 1 < pending.count {
            Thread.sleep(forTimeInterval: 0.35)
          }
        }

        let stillPending = list.filter { !self.isConnected($0) }
        if stillPending.isEmpty { break }
        if pass < attempts {
          Thread.sleep(forTimeInterval: retryDelay)
        }
      }

      let connectedCount = list.filter { self.isConnected($0) }.count
      DispatchQueue.main.async {
        for p in list {
          self.busyIDs.remove(p.id)
          if !self.isConnected(p) {
            Log.error("Could not connect \(p.displayName) after \(attempts) attempt(s)", "Bluetooth")
          }
        }
        self.refresh()
        completion?(connectedCount, list.count)
      }
    }
  }

  /// Performs a single connection/pairing pass for one peripheral on `queue` while coordinating
  /// `IOBluetoothDevicePair` on the main run loop.
  private func performConnectPass(
    for p: BluetoothPeripheral, pass: Int, totalPasses: Int, pairTimeout: TimeInterval
  ) -> Bool {
    guard var device = IOBluetoothDevice(addressString: p.id) else {
      Log.error("\(p.displayName) (\(p.id)) not found", "Bluetooth")
      return false
    }
    if device.isConnected() { return true }

    if settings.requireInRange && device.rssi() == Constants.invalidRSSI {
      Log.warn("\(p.displayName) appears out of range (RSSI check)", "Bluetooth")
      return false
    }

    // 1. If macOS thinks the device is already paired here:
    //    - Try a direct connection first (works when link key is still valid).
    //    - If that fails, the stored link key is stale (because the other Mac paired with
    //      the device), so we must remove the stale pairing record before re-pairing.
    if device.isPaired() {
      Log.debug("\(p.displayName) is marked paired locally; trying direct openConnection", "Bluetooth")
      let openRes = device.openConnection()
      if openRes == kIOReturnSuccess && device.isConnected() {
        Thread.sleep(forTimeInterval: 0.2)
        if device.isConnected() { return true }
      }
      Log.info(
        "Direct connect to paired \(p.displayName) failed (\(openRes)); clearing stale pairing to re-pair",
        "Bluetooth")
      unpairOnMain(device, name: p.displayName)
      Thread.sleep(forTimeInterval: 0.45)
      if let refreshed = IOBluetoothDevice(addressString: p.id) {
        device = refreshed
      }
    }

    // 2. Start IOBluetoothDevicePair on the main run loop so delegate callbacks and
    //    BluetoothUIServer / NotificationCenter prompts fire properly.
    let session = PairSession(id: p.id)
    var startResult: IOReturn = kIOReturnError

    DispatchQueue.main.sync {
      self.cleanupPairOnMain(for: p.id, stopIfRunning: true)
      if let pair = IOBluetoothDevicePair(device: device) {
        pair.delegate = self
        self.activePairs[p.id] = pair
        self.pairSessions[p.id] = session
        startResult = pair.start()
      }
      if self.settings.autoAcceptBluetoothRequests {
        BluetoothAutoClicker.shared.scanAndClickNow()
      }
    }

    if startResult != kIOReturnSuccess {
      Log.debug(
        "IOBluetoothDevicePair.start() for \(p.displayName) returned \(startResult)", "Bluetooth")
    }

    // 3. Wait for pairing + user confirmation (auto-clicked) WITHOUT calling openConnection()
    //    concurrently (calling openConnection() mid-pair aborts the pairing channel).
    var deadline = Date().addingTimeInterval(pairTimeout)
    let pollStep: TimeInterval = 0.2

    while Date() < deadline {
      Thread.sleep(forTimeInterval: pollStep)

      if settings.autoAcceptBluetoothRequests {
        DispatchQueue.main.async {
          BluetoothAutoClicker.shared.scanAndClickNow()
        }
      }

      if let live = IOBluetoothDevice(addressString: p.id) {
        device = live
      }

      // If the device is actively shaking hands / waiting for prompt click, extend once
      // so we don't cut off an active pairing right as the prompt is accepted.
      if session.handshaking && !session.extendedDeadline {
        session.extendedDeadline = true
        deadline = max(deadline, Date().addingTimeInterval(3.5))
      }

      if device.isConnected() && device.isPaired() {
        break
      }

      if session.finished {
        break
      }
    }

    // 4. If pairing finished or the device is now paired, ensure the baseband/HID connection is open.
    if let live = IOBluetoothDevice(addressString: p.id) {
      device = live
    }
    if !device.isConnected() && (device.isPaired() || session.error == kIOReturnSuccess) {
      let r = device.openConnection()
      Log.debug("Post-pair openConnection for \(p.displayName) returned \(r)", "Bluetooth")
      for _ in 0..<5 {
        if device.isConnected() { break }
        Thread.sleep(forTimeInterval: 0.2)
      }
    }

    let connected = device.isConnected()

    // 5. Clean up the pairing object. IMPORTANT: IOBluetoothDevicePair.stop() disconnects
    //    the device if called while connected, so only call stop() when not connected!
    DispatchQueue.main.sync {
      self.cleanupPairOnMain(for: p.id, stopIfRunning: !connected)
    }

    return connected
  }

  private func markFinished(_ p: BluetoothPeripheral, connected: Bool) {
    DispatchQueue.main.async {
      self.busyIDs.remove(p.id)
      self.refreshStatusOnly()
    }
  }

  private func cleanupPairOnMain(for id: String, stopIfRunning: Bool) {
    if let pair = activePairs.removeValue(forKey: id) {
      pair.delegate = nil
      if stopIfRunning {
        pair.stop()
      }
    }
    pairSessions.removeValue(forKey: id)
  }

  private func unpairOnMain(_ device: IOBluetoothDevice, name: String) {
    let block = {
      let sel = Selector(("remove"))
      if device.responds(to: sel) {
        _ = device.perform(sel)
        Log.debug("Removed pairing record for \(name)", "Bluetooth")
      }
    }
    if Thread.isMainThread {
      block()
    } else {
      DispatchQueue.main.sync(execute: block)
    }
  }

  // MARK: - Release

  /// Releases a peripheral from this Mac so another Mac can claim it.
  func release(_ p: BluetoothPeripheral) {
    BluetoothAutoClicker.shared.suppressAfterRelease(duration: 10)
    DispatchQueue.main.async {
      self.cleanupPairOnMain(for: p.id, stopIfRunning: true)
    }
    guard let device = IOBluetoothDevice(addressString: p.id) else {
      Log.error("\(p.displayName) not found", "Bluetooth")
      return
    }
    switch settings.disconnectMethod {
    case .unpair:
      // Private API used by upstream Blue Switch: removes pairing so the peer Mac can pair.
      let sel = Selector(("remove"))
      if device.responds(to: sel) {
        unpairOnMain(device, name: p.displayName)
        SecurityMonitor.shared.recordAudit(
          category: "Bluetooth",
          message: "Released & unpaired \(p.displayName) (\(p.id)) from this Mac",
          level: .info
        )
      } else {
        Log.warn("Unpair unavailable; closing connection for \(p.displayName)", "Bluetooth")
        device.closeConnection()
      }
    case .closeConnection:
      if device.isConnected() {
        let r = device.closeConnection()
        SecurityMonitor.shared.recordAudit(
          category: "Bluetooth",
          message: "Closed Bluetooth connection to \(p.displayName) (\(p.id)) (status \(r))",
          level: .info
        )
      }
    }
  }

  /// Releases all enabled peripherals and waits until they are disconnected.
  func releaseAll(completion: @escaping (Bool) -> Void) {
    BluetoothAutoClicker.shared.suppressAfterRelease(duration: 12)
    let list = enabledPeripherals
    list.forEach(release)
    waitForDisconnection(of: list, completion: completion)
  }

  private func waitForDisconnection(
    of list: [BluetoothPeripheral], completion: @escaping (Bool) -> Void
  ) {
    let interval = max(0.1, settings.disconnectPollInterval)
    let maxAttempts = max(1, settings.disconnectMaxAttempts)
    var attempts = 0

    func check() {
      attempts += 1
      let stillConnected = list.filter { isConnected($0) }
      if stillConnected.isEmpty {
        // Give the Bluetooth baseband ACL link a brief moment to finish closing in hardware
        // before telling the peer Mac to start paging the peripheral.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
          self?.refresh()
          completion(true)
        }
      } else if attempts < maxAttempts {
        // If a device is still connected after the first check, nudge it with closeConnection + remove.
        if attempts == 2 {
          for p in stillConnected {
            if let dev = IOBluetoothDevice(addressString: p.id) {
              dev.closeConnection()
              if settings.disconnectMethod == .unpair {
                unpairOnMain(dev, name: p.displayName)
              }
            }
          }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + interval, execute: check)
      } else {
        Log.warn("Timed out waiting for peripherals to disconnect", "Bluetooth")
        refresh()
        completion(false)
      }
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + interval, execute: check)
  }

  // MARK: - Persistence

  private func save() {
    if let data = try? JSONEncoder().encode(peripherals) {
      UserDefaults.standard.set(data, forKey: Constants.storageKey)
    }
  }

  private func load() {
    guard let data = UserDefaults.standard.data(forKey: Constants.storageKey) else { return }
    peripherals = (try? JSONDecoder().decode([BluetoothPeripheral].self, from: data)) ?? []
  }

  func exportData() -> Data? { try? JSONEncoder().encode(peripherals) }
  func importData(_ data: Data) {
    if let list = try? JSONDecoder().decode([BluetoothPeripheral].self, from: data) {
      peripherals = list
      refresh()
    }
  }
}

// MARK: - CBCentralManagerDelegate

extension BluetoothService: CBCentralManagerDelegate {
  func centralManagerDidUpdateState(_ central: CBCentralManager) {
    authorization = CBManager.authorization
    let state: String
    switch central.state {
    case .poweredOn: state = "available"
    case .poweredOff: state = "powered off"
    case .unauthorized: state = "not authorized — allow BlueSwitch in Privacy & Security → Bluetooth"
    case .unsupported: state = "unsupported"
    case .resetting: state = "resetting"
    default: state = "unknown"
    }
    Log.info("Bluetooth \(state)", "Bluetooth")
    if central.state == .unauthorized {
      NotificationService.post(
        title: "BlueSwitch needs Bluetooth access",
        body: "Open System Settings → Privacy & Security → Bluetooth and turn on BlueSwitch.",
        kind: .error)
    }
    refresh()
  }
}

// MARK: - IOBluetoothDevicePairDelegate

extension BluetoothService: IOBluetoothDevicePairDelegate {
  private func session(for sender: Any?) -> PairSession? {
    if let pair = sender as? IOBluetoothDevicePair,
      let addr = pair.device()?.addressString
    {
      return pairSessions[addr]
        ?? pairSessions.first(where: { $0.key.caseInsensitiveCompare(addr) == .orderedSame })?.value
    }
    return pairSessions.values.first
  }

  func devicePairingStarted(_ sender: Any!) {
    session(for: sender)?.started = true
    Log.debug("Pairing started", "Bluetooth")
    if settings.autoAcceptBluetoothRequests {
      BluetoothAutoClicker.shared.scanAndClickNow()
    }
  }

  func devicePairingConnecting(_ sender: Any!) {
    session(for: sender)?.handshaking = true
    Log.debug("Pairing connecting (baseband)", "Bluetooth")
    if settings.autoAcceptBluetoothRequests {
      BluetoothAutoClicker.shared.scanAndClickNow()
    }
  }

  func devicePairingConnected(_ sender: Any!) {
    session(for: sender)?.handshaking = true
    Log.debug("Pairing connected (baseband)", "Bluetooth")
    if settings.autoAcceptBluetoothRequests {
      BluetoothAutoClicker.shared.scanAndClickNow()
    }
  }

  func devicePairingUserConfirmationRequest(
    _ sender: Any!, numericValue: BluetoothNumericValue
  ) {
    session(for: sender)?.handshaking = true
    Log.info(
      "Bluetooth pairing confirmation requested (code: \(numericValue)) — auto-confirming",
      "Bluetooth")
    if let pair = sender as? IOBluetoothDevicePair {
      pair.replyUserConfirmation(true)
    } else {
      for pair in activePairs.values {
        pair.replyUserConfirmation(true)
      }
    }
    if settings.autoAcceptBluetoothRequests {
      BluetoothAutoClicker.shared.scanAndClickNow()
    }
  }

  func devicePairingPINCodeRequest(_ sender: Any!) {
    session(for: sender)?.handshaking = true
    Log.info("Bluetooth PIN code requested — replying with default 0000", "Bluetooth")
    var pin = BluetoothPINCode()
    pin.data.0 = 0x30
    pin.data.1 = 0x30
    pin.data.2 = 0x30
    pin.data.3 = 0x30
    if let pair = sender as? IOBluetoothDevicePair {
      pair.replyPINCode(4, pinCode: &pin)
    } else {
      for pair in activePairs.values {
        pair.replyPINCode(4, pinCode: &pin)
      }
    }
  }

  func deviceSimplePairingComplete(_ sender: Any!, status: BluetoothHCIEventStatus) {
    Log.debug("Simple pairing complete (status: \(status))", "Bluetooth")
    if status == 0 {
      session(for: sender)?.handshaking = true
    }
  }

  func devicePairingFinished(_ sender: Any!, error: IOReturn) {
    if let s = session(for: sender) {
      s.error = error
      s.finished = true
    }
    if error != kIOReturnSuccess {
      Log.debug("Pairing finished with code \(error)", "Bluetooth")
    } else {
      Log.debug("Pairing finished successfully", "Bluetooth")
    }
  }
}
