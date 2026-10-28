import AppKit
import Combine
import Foundation

/// Orchestrates switching peripherals between this Mac and the active peer.
final class SwitchCoordinator: ObservableObject {
  static let shared = SwitchCoordinator()

  enum Phase: Equatable {
    case idle
    case working(String)
    case success(String)
    case failure(String)

    var isWorking: Bool { if case .working = self { return true } else { return false } }
  }

  @Published private(set) var phase: Phase = .idle

  private let bt = BluetoothService.shared
  private let net = NetworkService.shared
  private var settings: AppSettings { .shared }
  private var cancellables = Set<AnyCancellable>()
  private var resetWorkItem: DispatchWorkItem?

  private init() {}

  func start() {
    net.requestHandler = { [weak self] msg, reply in self?.handle(msg, reply: reply) }

    // Auto-sync the peripheral list to the active peer when it changes.
    bt.peripheralsChanged
      .debounce(for: .seconds(1.5), scheduler: DispatchQueue.main)
      .sink { [weak self] list in
        guard let self, self.settings.autoSyncPeripherals, let peer = self.net.activePeer else {
          return
        }
        self.syncPeripherals(to: peer, list: list, silent: true)
      }
      .store(in: &cancellables)

    // Sleep / wake behavior.
    let ws = NSWorkspace.shared.notificationCenter
    ws.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) {
      [weak self] _ in
      guard let self, self.settings.releaseOnSleep else { return }
      Log.info("System sleeping: sending peripherals to peer", "Switch")
      self.sendToPeer()
    }
    ws.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) {
      [weak self] _ in
      guard let self, self.settings.reclaimOnWake else { return }
      Log.info("System woke: reclaiming peripherals", "Switch")
      DispatchQueue.main.asyncAfter(deadline: .now() + 3) { self.takeFromPeer() }
    }

    if settings.reclaimOnLaunch {
      DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in self?.takeFromPeer() }
    }
  }

  // MARK: - Public Actions

  /// Upstream left-click behavior: toggle peripherals between this Mac and the peer.
  func switchDevices() {
    guard !phase.isWorking else { return }
    if settings.confirmBeforeSwitching && !confirm() { return }
    guard let peer = requirePeer() else { return }

    setPhase(.working("Checking \(peer.name)…"))
    net.ping(id: peer.id) { [weak self] result in
      guard let self else { return }
      switch result {
      case .failure(let e):
        self.fail("Can't reach \(peer.name): \(e.localizedDescription)")
      case .success(let pong):
        switch self.bt.connectionState {
        case .none:
          if (pong.connectedCount ?? 0) > 0 {
            self.performTake(from: peer)
          } else {
            self.fail("No peripherals registered. Add them in Settings → Peripherals.")
          }
        case .allConnected:
          self.performSend(to: peer)
        case .allDisconnected:
          self.performTake(from: peer)
        case .partial:
          switch self.settings.partialStateBehavior {
          case .smart:
            if (pong.connectedCount ?? 0) == 0 {
              self.performSend(to: peer)
            } else {
              self.performTake(from: peer)
            }
          case .warn:
            self.fail(
              "Some peripherals are connected and others are not. Make sure all are in the same state.",
              title: "Warning")
          case .pushToPeer: self.performSend(to: peer)
          case .pullFromPeer: self.performTake(from: peer)
          }
        }
      }
    }
  }

  /// Release peripherals here and ask the peer to connect them.
  func sendToPeer() {
    guard !phase.isWorking, let peer = requirePeer() else { return }
    performSend(to: peer)
  }

  /// Ask the peer to release peripherals, then connect them here.
  func takeFromPeer() {
    guard !phase.isWorking, let peer = requirePeer() else { return }
    performTake(from: peer)
  }

  func sendTestNotification(to peer: PeerDevice) {
    var msg = PeerMessage.make(.notify)
    msg.title = settings.customNotifyTitle
    msg.body = settings.customNotifyBody.replacingOccurrences(
      of: "{device}", with: settings.effectiveDeviceName)
    net.send(msg, to: peer) { [weak self] result in
      guard let self else { return }
      switch result {
      case .success:
        if self.settings.confirmSentNotification {
          NotificationService.post(
            title: "Notification Sent", body: "Notification sent to \(peer.name)")
        }
        Log.info("Notification sent to \(peer.name)", "Switch")
      case .failure(let e):
        NotificationService.post(
          title: "Error", body: "Couldn't notify \(peer.name): \(e.localizedDescription)",
          kind: .error)
      }
    }
  }

  func syncPeripherals(to peer: PeerDevice, list: [BluetoothPeripheral]? = nil, silent: Bool = false)
  {
    var msg = PeerMessage.make(.syncPeripherals)
    msg.peripherals = list ?? bt.peripherals
    net.send(msg, to: peer) { result in
      switch result {
      case .success:
        Log.info("Synced \(msg.peripherals?.count ?? 0) peripherals to \(peer.name)", "Switch")
        if !silent {
          NotificationService.post(
            title: "Peripherals synced", body: "Sent peripheral list to \(peer.name)",
            kind: .switchResult)
        }
      case .failure(let e):
        Log.error("Sync to \(peer.name) failed: \(e.localizedDescription)", "Switch")
        if !silent {
          NotificationService.post(
            title: "Sync failed", body: e.localizedDescription, kind: .error)
        }
      }
    }
  }

  // MARK: - Flows

  private func performSend(to peer: PeerDevice) {
    setPhase(.working("Releasing peripherals…"))
    let listToSend = bt.enabledPeripherals
    bt.releaseAll { [weak self] allReleased in
      guard let self else { return }
      if !allReleased {
        self.fail("Failed to disconnect peripherals from this Mac")
        return
      }
      self.setPhase(.working("Handing off to \(peer.name)…"))
      var msg = PeerMessage.make(.connectAll)
      msg.peripherals = listToSend
      self.net.send(msg, to: peer) { result in
        switch result {
        case .success(let r) where r.kind == .ok:
          self.succeed("Peripherals sent to \(peer.name)")
        case .success:
          self.fail("Connection process failed on \(peer.name)")
        case .failure(let e):
          self.fail("Couldn't hand off to \(peer.name): \(e.localizedDescription)")
        }
      }
    }
  }

  private func performTake(from peer: PeerDevice) {
    setPhase(.working("Asking \(peer.name) to release…"))
    var msg = PeerMessage.make(.releaseAll)
    msg.peripherals = bt.enabledPeripherals
    net.send(msg, to: peer) { [weak self] result in
      guard let self else { return }
      switch result {
      case .success(let r) where r.kind == .ok:
        self.bt.adoptPeripheralsIfMissing(r.peripherals)
        self.connectHere(peer: peer)
      case .success(let r):
        // Peer replied but couldn't confirm release; try anyway.
        Log.warn("\(peer.name) could not confirm release; trying to connect anyway", "Switch")
        self.bt.adoptPeripheralsIfMissing(r.peripherals)
        self.connectHere(peer: peer)
      case .failure(let e):
        self.fail("\(peer.name) didn't release peripherals: \(e.localizedDescription)")
      }
    }
  }

  private func connectHere(peer: PeerDevice) {
    setPhase(.working("Connecting peripherals…"))
    bt.connectAll { [weak self] ok, total in
      guard let self else { return }
      if total == 0 {
        self.fail("No peripherals registered. Add them in Settings → Peripherals.")
      } else if ok == total {
        self.succeed("Peripherals connected to this Mac")
      } else if ok > 0 {
        self.fail("Connected \(ok) of \(total) peripherals", title: "Partially switched")
      } else {
        self.fail("Couldn't connect peripherals to this Mac")
      }
    }
  }

  // MARK: - Incoming Requests

  private func handle(_ msg: PeerMessage, reply: @escaping (PeerMessage) -> Void) {
    switch msg.kind {
    case .ping:
      var pong = PeerMessage.make(.pong)
      pong.connectedCount = bt.enabledPeripherals.filter { bt.isConnected($0) }.count
      reply(pong)

    case .releaseAll:
      Log.info("\(msg.sender) requested release", "Switch")
      bt.adoptPeripheralsIfMissing(msg.peripherals)
      setPhase(.working("\(msg.sender) is taking peripherals…"))
      let snapshot = bt.enabledPeripherals
      bt.releaseAll { [weak self] ok in
        var resp = PeerMessage.make(ok ? .ok : .error)
        resp.peripherals = snapshot
        reply(resp)
        if ok {
          self?.succeed("Peripherals handed to \(msg.sender)", kind: .remoteRequest)
        } else {
          self?.fail("Couldn't release peripherals for \(msg.sender)")
        }
      }

    case .connectAll:
      Log.info("\(msg.sender) requested connect", "Switch")
      bt.adoptPeripheralsIfMissing(msg.peripherals)
      // Respond immediately (upstream behavior) so the sender isn't blocked by retries.
      reply(PeerMessage.make(.ok))
      setPhase(.working("Receiving peripherals from \(msg.sender)…"))
      bt.connectAll { [weak self] ok, total in
        if total == 0 {
          self?.fail("No peripherals registered to receive from \(msg.sender)")
        } else if ok == total {
          self?.succeed("Peripherals received from \(msg.sender)", kind: .remoteRequest)
        } else {
          self?.fail("Connected \(ok) of \(total) peripherals from \(msg.sender)")
        }
      }

    case .notify:
      NotificationService.post(
        title: msg.title ?? "BlueSwitch", body: msg.body ?? "Message from \(msg.sender)",
        kind: .message)
      reply(PeerMessage.make(.ok))

    case .syncPeripherals:
      if let list = msg.peripherals {
        bt.replace(with: list)
        Log.info("Received \(list.count) peripherals from \(msg.sender)", "Switch")
        NotificationService.post(
          title: "Peripherals synced", body: "Peripheral list received from \(msg.sender)",
          kind: .remoteRequest)
        reply(PeerMessage.make(.ok))
      } else {
        reply(PeerMessage.make(.error))
      }

    case .installUpdate:
      UpdateChecker.shared.handleIncomingUpdate(msg, reply: reply)

    case .pong, .ok, .error:
      reply(PeerMessage.make(.error))
    }
  }

  // MARK: - Helpers

  private func requirePeer() -> PeerDevice? {
    guard let peer = net.activePeer else {
      fail("No Mac registered. Add one in Settings → Devices.")
      return nil
    }
    return peer
  }

  private func confirm() -> Bool {
    NSApp.activate(ignoringOtherApps: true)
    let alert = NSAlert()
    alert.messageText = "Switch peripherals?"
    alert.informativeText =
      "Your keyboard and trackpad will move to \(net.activePeer?.name ?? "the other Mac")."
    alert.addButton(withTitle: "Switch")
    alert.addButton(withTitle: "Cancel")
    return alert.runModal() == .alertFirstButtonReturn
  }

  private func setPhase(_ p: Phase) {
    resetWorkItem?.cancel()
    phase = p
    if case .working(let m) = p { Log.debug(m, "Switch") }
  }

  private func succeed(_ message: String, kind: NotificationService.Kind = .switchResult) {
    setPhase(.success(message))
    Log.info(message, "Switch")
    NotificationService.post(title: "BlueSwitch", body: message, kind: kind)
    scheduleReset()
  }

  private func fail(_ message: String, title: String = "Error") {
    setPhase(.failure(message))
    Log.error(message, "Switch")
    NotificationService.post(title: title, body: message, kind: .error)
    scheduleReset()
  }

  private func scheduleReset() {
    let item = DispatchWorkItem { [weak self] in self?.phase = .idle }
    resetWorkItem = item
    DispatchQueue.main.asyncAfter(deadline: .now() + 6, execute: item)
    bt.refresh()
  }
}
