import Combine
import Foundation
import Network

/// Publishes this Mac over Bonjour, discovers peers, and carries peer requests.
final class NetworkService: ObservableObject {
  static let shared = NetworkService()

  private enum Constants {
    static let storageKey = "peers"
    static let reachabilityInterval: TimeInterval = 15
  }

  // MARK: Published state

  /// Peers registered by the user (switch targets).
  @Published private(set) var peers: [PeerDevice] = [] { didSet { save() } }
  /// Peers discovered via Bonjour that are not registered.
  @Published private(set) var discovered: [PeerDevice] = []
  @Published private(set) var reachability: [String: PeerReachability] = [:]
  @Published private(set) var listenerStatus = "Stopped"
  @Published private(set) var listeningPort: UInt16?
  @Published private(set) var publishedName: String?
  @Published private(set) var browserStatus = "Stopped"

  /// Handles an authenticated incoming request and produces a response.
  var requestHandler: ((PeerMessage, @escaping (PeerMessage) -> Void) -> Void)?

  private var listener: NWListener?
  private var browser: NWBrowser?
  private var endpoints: [String: NWEndpoint] = [:]
  private var serverConnections: [ObjectIdentifier: ServerConnection] = [:]
  private var reachabilityTimer: Timer?
  private let queue = DispatchQueue(label: "com.blueswitch.network")
  private var settings: AppSettings { .shared }

  private init() { load() }

  // MARK: - Lifecycle

  func start() {
    startListener()
    if settings.discoveryEnabled { startBrowser() } else { browserStatus = "Disabled" }
    reachabilityTimer?.invalidate()
    reachabilityTimer = Timer.scheduledTimer(
      withTimeInterval: Constants.reachabilityInterval, repeats: true
    ) { [weak self] _ in self?.checkAllPeers() }
    checkAllPeers()
  }

  func stop() {
    listener?.cancel()
    listener = nil
    browser?.cancel()
    browser = nil
    reachabilityTimer?.invalidate()
    listenerStatus = "Stopped"
    browserStatus = "Stopped"
    listeningPort = nil
    publishedName = nil
  }

  /// Restarts networking (after name / port / service-type changes).
  func restart() {
    Log.info("Restarting network services", "Network")
    stop()
    discovered.removeAll()
    endpoints.removeAll()
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self.start() }
  }

  // MARK: - Listener

  private func startListener() {
    let params = NWParameters.tcp
    params.includePeerToPeer = true
    let port: NWEndpoint.Port
    if settings.listenPort > 0, let p = NWEndpoint.Port(rawValue: UInt16(settings.listenPort)) {
      port = p
    } else {
      port = .any
    }

    do {
      let l = try NWListener(using: params, on: port)
      l.service = NWListener.Service(
        name: settings.effectiveDeviceName, type: settings.effectiveServiceType)
      l.serviceRegistrationUpdateHandler = { [weak self] change in
        DispatchQueue.main.async {
          switch change {
          case .add(let ep):
            if case .service(let name, _, _, _) = ep {
              self?.publishedName = name
              Log.info("Published as \"\(name)\"", "Network")
            }
          case .remove:
            self?.publishedName = nil
          @unknown default: break
          }
        }
      }
      l.stateUpdateHandler = { [weak self, weak l] state in
        DispatchQueue.main.async {
          guard let self else { return }
          switch state {
          case .ready:
            self.listeningPort = l?.port?.rawValue
            self.listenerStatus = "Listening"
            Log.info("Listening on port \(self.listeningPort ?? 0)", "Network")
          case .failed(let e):
            self.listenerStatus = "Failed: \(e.localizedDescription)"
            Log.error("Listener failed: \(e)", "Network")
          case .cancelled:
            self.listenerStatus = "Stopped"
          case .waiting(let e):
            self.listenerStatus = "Waiting: \(e.localizedDescription)"
          default: break
          }
        }
      }
      l.newConnectionHandler = { [weak self] conn in self?.accept(conn) }
      l.start(queue: queue)
      listener = l
    } catch {
      listenerStatus = "Failed: \(error.localizedDescription)"
      Log.error("Could not create listener: \(error)", "Network")
    }
  }

  private func accept(_ conn: NWConnection) {
    let server = ServerConnection(connection: conn, queue: queue) { [weak self] msg, reply in
      self?.handleIncoming(msg, reply: reply)
    }
    let key = ObjectIdentifier(server)
    server.onClose = { [weak self] in
      DispatchQueue.main.async { self?.serverConnections[key] = nil }
    }
    DispatchQueue.main.async { self.serverConnections[key] = server }
    server.start()
  }

  private func handleIncoming(_ msg: PeerMessage, reply: @escaping (PeerMessage) -> Void) {
    DispatchQueue.main.async {
      let expected = self.settings.pairingKey
      if !expected.isEmpty && msg.key != expected {
        Log.warn("Rejected \(msg.kind.rawValue) from \(msg.sender): bad pairing key", "Network")
        var e = PeerMessage.make(.error)
        e.body = "Pairing key mismatch"
        reply(e)
        return
      }
      Log.debug("Received \(msg.kind.rawValue) from \(msg.sender)", "Network")
      guard let handler = self.requestHandler else {
        reply(PeerMessage.make(.error))
        return
      }
      handler(msg, reply)
    }
  }

  // MARK: - Browser

  private func startBrowser() {
    let params = NWParameters()
    params.includePeerToPeer = true
    let b = NWBrowser(for: .bonjour(type: settings.effectiveServiceType, domain: nil), using: params)
    b.stateUpdateHandler = { [weak self] state in
      DispatchQueue.main.async {
        switch state {
        case .ready: self?.browserStatus = "Browsing"
        case .failed(let e):
          self?.browserStatus = "Failed: \(e.localizedDescription)"
          Log.error("Browser failed: \(e)", "Network")
        case .waiting(let e): self?.browserStatus = "Waiting: \(e.localizedDescription)"
        case .cancelled: self?.browserStatus = "Stopped"
        default: break
        }
      }
    }
    b.browseResultsChangedHandler = { [weak self] _, changes in
      DispatchQueue.main.async { self?.handleBrowse(changes) }
    }
    b.start(queue: queue)
    browser = b
  }

  private var ownName: String { publishedName ?? settings.effectiveDeviceName }

  private func handleBrowse(_ changes: Set<NWBrowser.Result.Change>) {
    for change in changes {
      switch change {
      case .added(let r):
        guard case .service(let name, _, _, _) = r.endpoint, name != ownName else { continue }
        endpoints[name] = r.endpoint
        Log.info("Discovered \(name)", "Network")
        if !peers.contains(where: { $0.id == name }) && !discovered.contains(where: { $0.id == name })
        {
          discovered.append(PeerDevice(id: name, name: name, host: "", port: 0))
          if settings.notifyOnPeerFound {
            NotificationService.post(
              title: "Mac discovered", body: "\(name) is available for switching", kind: .peerFound)
          }
        }
        ping(id: name)
      case .removed(let r):
        guard case .service(let name, _, _, _) = r.endpoint else { continue }
        endpoints[name] = nil
        discovered.removeAll { $0.id == name }
        reachability[name] = .offline
        Log.info("\(name) went away", "Network")
      default:
        break
      }
    }
  }

  // MARK: - Peer Management

  var activePeer: PeerDevice? {
    peers.first { $0.id == settings.activePeerID } ?? peers.first
  }

  func setActive(_ peer: PeerDevice) { settings.activePeerID = peer.id }

  func register(_ peer: PeerDevice) {
    guard !peers.contains(where: { $0.id == peer.id }) else { return }
    peers.append(peer)
    discovered.removeAll { $0.id == peer.id }
    if peers.count == 1 { settings.activePeerID = peer.id }
    Log.info("Registered \(peer.name) as a switch target", "Network")
    ping(id: peer.id)
  }

  func remove(_ peer: PeerDevice) {
    peers.removeAll { $0.id == peer.id }
    if settings.activePeerID == peer.id { settings.activePeerID = peers.first?.id ?? "" }
    if endpoints[peer.id] != nil && !peer.isManual {
      discovered.append(PeerDevice(id: peer.id, name: peer.name, host: peer.host, port: peer.port))
    }
    Log.info("Removed \(peer.name)", "Network")
  }

  func addManual(name: String, host: String, port: Int) {
    let n = name.trimmingCharacters(in: .whitespaces)
    let peer = PeerDevice(
      id: n.isEmpty ? "\(host):\(port)" : n, name: n.isEmpty ? host : n,
      host: host.trimmingCharacters(in: .whitespaces), port: port, isManual: true)
    register(peer)
  }

  func updateManual(_ peer: PeerDevice) {
    guard let i = peers.firstIndex(where: { $0.id == peer.id }) else { return }
    peers[i] = peer
  }

  // MARK: - Requests

  private func endpoint(for id: String) -> NWEndpoint? {
    let peer = peers.first { $0.id == id } ?? discovered.first { $0.id == id }
    if let peer, peer.isManual {
      return hostPortEndpoint(peer)
    }
    if let ep = endpoints[id] { return ep }
    if let peer { return hostPortEndpoint(peer) }
    return nil
  }

  private func hostPortEndpoint(_ peer: PeerDevice) -> NWEndpoint? {
    guard !peer.host.isEmpty, peer.port > 0, let port = NWEndpoint.Port(rawValue: UInt16(peer.port))
    else { return nil }
    return .hostPort(host: NWEndpoint.Host(peer.host), port: port)
  }

  func send(
    _ message: PeerMessage, to peer: PeerDevice, timeout: TimeInterval? = nil,
    completion: @escaping (Result<PeerMessage, PeerError>) -> Void
  ) {
    guard let ep = endpoint(for: peer.id) else {
      completion(.failure(.invalidEndpoint))
      return
    }
    let t = timeout ?? settings.commandTimeout
    Log.debug("Sending \(message.kind.rawValue) to \(peer.name)", "Network")
    PeerRequest(endpoint: ep, message: message, timeout: max(1, t)) { [weak self] result, remote in
      self?.recordResult(id: peer.id, result: result, remote: remote)
      completion(result)
    }.start()
  }

  /// Health check (upstream `checkHealth`). Also learns the peer's resolved host/port.
  func ping(id: String, completion: ((Result<PeerMessage, PeerError>) -> Void)? = nil) {
    guard let ep = endpoint(for: id) else {
      reachability[id] = .offline
      completion?(.failure(.invalidEndpoint))
      return
    }
    if reachability[id] != .online { reachability[id] = .checking }
    PeerRequest(
      endpoint: ep, message: .make(.ping), timeout: max(1, settings.healthCheckTimeout)
    ) { [weak self] result, remote in
      self?.recordResult(id: id, result: result, remote: remote)
      completion?(result)
    }.start()
  }

  func checkAllPeers() {
    for p in peers { ping(id: p.id) }
  }

  private func recordResult(
    id: String, result: Result<PeerMessage, PeerError>, remote: NWEndpoint?
  ) {
    switch result {
    case .success(let msg):
      reachability[id] = .online
      var hostString: String?
      var portInt: Int?
      if case .hostPort(let host, let port)? = remote {
        var h = "\(host)"
        if let pct = h.firstIndex(of: "%"), !h.contains(":") {
          h = String(h[..<pct])
        }
        hostString = h
        portInt = Int(port.rawValue)
      }
      update(id: id) { p in
        if !p.isManual, let hostString, let portInt {
          p.host = hostString
          p.port = portInt
        }
        if let v = msg.appVersion, !v.isEmpty { p.appVersion = v }
        if let b = msg.appBuild, !b.isEmpty { p.appBuild = b }
        p.lastSeen = Date()
      }
      if let updatedPeer = peers.first(where: { $0.id == id }) {
        UpdateChecker.shared.maybeAutoUpdatePeer(updatedPeer)
      }
    case .failure(let e):
      if case .rejected = e { reachability[id] = .online } else { reachability[id] = .offline }
    }
  }

  private func update(id: String, _ mutate: (inout PeerDevice) -> Void) {
    if let i = peers.firstIndex(where: { $0.id == id }) { mutate(&peers[i]) }
    if let i = discovered.firstIndex(where: { $0.id == id }) { mutate(&discovered[i]) }
  }

  // MARK: - Persistence

  private func save() {
    if let data = try? JSONEncoder().encode(peers) {
      UserDefaults.standard.set(data, forKey: Constants.storageKey)
    }
  }

  private func load() {
    guard let data = UserDefaults.standard.data(forKey: Constants.storageKey) else { return }
    peers = (try? JSONDecoder().decode([PeerDevice].self, from: data)) ?? []
  }

  func exportData() -> Data? { try? JSONEncoder().encode(peers) }
  func importData(_ data: Data) {
    if let list = try? JSONDecoder().decode([PeerDevice].self, from: data) { peers = list }
  }
}

// MARK: - ServerConnection

/// Handles one incoming TCP connection: reads JSON lines, replies to each.
final class ServerConnection {
  private let connection: NWConnection
  private let queue: DispatchQueue
  private let handler: (PeerMessage, @escaping (PeerMessage) -> Void) -> Void
  private var buffer = LineBuffer()
  var onClose: (() -> Void)?

  init(
    connection: NWConnection, queue: DispatchQueue,
    handler: @escaping (PeerMessage, @escaping (PeerMessage) -> Void) -> Void
  ) {
    self.connection = connection
    self.queue = queue
    self.handler = handler
  }

  func start() {
    connection.stateUpdateHandler = { [weak self] state in
      switch state {
      case .failed, .cancelled: self?.onClose?()
      default: break
      }
    }
    connection.start(queue: queue)
    receive()
    // Safety: drop idle connections after 60s.
    queue.asyncAfter(deadline: .now() + 60) { [weak self] in self?.connection.cancel() }
  }

  private func receive() {
    connection.receive(minimumIncompleteLength: 1, maximumLength: 524_288) {
      [weak self] data, _, isComplete, error in
      guard let self else { return }
      if let data, !data.isEmpty {
        for msg in self.buffer.append(data) {
          self.handler(msg) { [weak self] response in self?.send(response) }
        }
      }
      if error != nil || isComplete {
        self.connection.cancel()
      } else {
        self.receive()
      }
    }
  }

  private func send(_ msg: PeerMessage) {
    guard let data = msg.encodedLine() else { return }
    connection.send(content: data, completion: .contentProcessed { _ in })
  }
}
