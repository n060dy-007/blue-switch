import Foundation
import Network

/// Wire message exchanged between BlueSwitch instances (newline-delimited JSON over TCP).
struct PeerMessage: Codable {
  enum Kind: String, Codable {
    case ping, pong
    case releaseAll, connectAll
    case notify, syncPeripherals
    case installUpdate
    case ok, error
  }

  var kind: Kind
  var sender: String
  var key: String? = nil
  var title: String? = nil
  var body: String? = nil
  var peripherals: [BluetoothPeripheral]? = nil
  var connectedCount: Int? = nil
  var appVersion: String? = nil
  var appBuild: String? = nil
  var updateBundleZip: Data? = nil
  var updateSHA256: String? = nil

  static func make(_ kind: Kind) -> PeerMessage {
    let s = AppSettings.shared
    return PeerMessage(
      kind: kind,
      sender: s.effectiveDeviceName,
      key: s.pairingKey.isEmpty ? nil : s.pairingKey,
      appVersion: AppInfo.version,
      appBuild: AppInfo.build
    )
  }

  func encodedLine() -> Data? {
    guard var data = try? JSONEncoder().encode(self) else { return nil }
    data.append(0x0A)
    return data
  }
}

enum PeerError: LocalizedError {
  case timeout, invalidResponse, rejected(String), connection(String), invalidEndpoint

  var errorDescription: String? {
    switch self {
    case .timeout: return "No response from peer (timed out). Is BlueSwitch running there?"
    case .invalidResponse: return "Peer sent an invalid response"
    case .rejected(let m): return "Peer rejected request: \(m)"
    case .connection(let m): return "Connection failed: \(m)"
    case .invalidEndpoint: return "Peer address or port is invalid"
    }
  }
}

/// Splits a TCP byte stream into newline-delimited JSON messages.
struct LineBuffer {
  private var buffer = Data()

  mutating func append(_ data: Data) -> [PeerMessage] {
    buffer.append(data)
    var out: [PeerMessage] = []
    while let nl = buffer.firstIndex(of: 0x0A) {
      let line = buffer[buffer.startIndex..<nl]
      buffer.removeSubrange(buffer.startIndex...nl)
      if !line.isEmpty, let msg = try? JSONDecoder().decode(PeerMessage.self, from: Data(line)) {
        out.append(msg)
      }
    }
    return out
  }
}

/// One request → one response over a short-lived TCP connection.
final class PeerRequest {
  private let connection: NWConnection
  private let message: PeerMessage
  private let timeout: TimeInterval
  private var completion: ((Result<PeerMessage, PeerError>, NWEndpoint?) -> Void)?
  private var buffer = LineBuffer()
  private let queue = DispatchQueue(label: "com.blueswitch.request")
  private var selfRetain: PeerRequest?

  init(
    endpoint: NWEndpoint, message: PeerMessage, timeout: TimeInterval,
    completion: @escaping (Result<PeerMessage, PeerError>, NWEndpoint?) -> Void
  ) {
    self.connection = NWConnection(to: endpoint, using: .tcp)
    self.message = message
    self.timeout = timeout
    self.completion = completion
  }

  func start() {
    selfRetain = self
    connection.stateUpdateHandler = { [weak self] state in
      guard let self else { return }
      switch state {
      case .ready:
        self.sendAndReceive()
      case .failed(let e):
        self.finish(.failure(.connection(e.localizedDescription)))
      default:
        break
      }
    }
    connection.start(queue: queue)
    queue.asyncAfter(deadline: .now() + timeout) { [weak self] in
      self?.finish(.failure(.timeout))
    }
  }

  private func sendAndReceive() {
    guard let data = message.encodedLine() else {
      finish(.failure(.invalidResponse))
      return
    }
    connection.send(
      content: data,
      completion: .contentProcessed { [weak self] err in
        if let err { self?.finish(.failure(.connection(err.localizedDescription))) }
      })
    receive()
  }

  private func receive() {
    connection.receive(minimumIncompleteLength: 1, maximumLength: 524_288) {
      [weak self] data, _, isComplete, error in
      guard let self else { return }
      if let data, !data.isEmpty, let msg = self.buffer.append(data).first {
        if msg.kind == .error {
          self.finish(.failure(.rejected(msg.body ?? "unknown error")))
        } else {
          self.finish(.success(msg))
        }
        return
      }
      if let error {
        self.finish(.failure(.connection(error.localizedDescription)))
      } else if isComplete {
        self.finish(.failure(.invalidResponse))
      } else {
        self.receive()
      }
    }
  }

  private func finish(_ result: Result<PeerMessage, PeerError>) {
    guard let completion else { return }
    self.completion = nil
    let remote = connection.currentPath?.remoteEndpoint
    connection.cancel()
    DispatchQueue.main.async { completion(result, remote) }
    selfRetain = nil
  }
}

enum AppInfo {
  static var version: String {
    Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0.2"
  }
  static var build: String {
    Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "3"
  }

  /// Compares two version strings (`"1.0.2"` vs `"1.0.1"`) and optional build numbers.
  static func isNewer(
    version aVer: String, build aBuild: String? = nil,
    thanVersion bVer: String, thanBuild bBuild: String? = nil
  ) -> Bool {
    let cleanA = aVer.trimmingCharacters(in: CharacterSet(charactersIn: "vV "))
    let cleanB = bVer.trimmingCharacters(in: CharacterSet(charactersIn: "vV "))
    if cleanA == "dev" || cleanB == "dev" { return false }
    let partsA = cleanA.split(separator: ".").map { Int($0) ?? 0 }
    let partsB = cleanB.split(separator: ".").map { Int($0) ?? 0 }
    let count = max(partsA.count, partsB.count)
    for i in 0..<count {
      let va = i < partsA.count ? partsA[i] : 0
      let vb = i < partsB.count ? partsB[i] : 0
      if va != vb { return va > vb }
    }
    if let aB = aBuild.flatMap({ Int($0) }), let bB = bBuild.flatMap({ Int($0) }), aB != bB {
      return aB > bB
    }
    return false
  }

  /// Returns true if a peer running `peerVersion` supports the native `.installUpdate` command (`>= 1.0.2`).
  static func supportsNativeOTAUpdate(version peerVersion: String?) -> Bool {
    guard let v = peerVersion else { return false }
    return !isNewer(version: "1.0.2", thanVersion: v)
  }
}
