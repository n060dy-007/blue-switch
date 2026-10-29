import CryptoKit
import Foundation
import Network

/// Wire message exchanged between BlueSwitch instances (AES-256-GCM encrypted JSON lines over TCP).
struct PeerMessage: Codable {
  enum Kind: String, Codable {
    case encrypted
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

  // Security / Encryption envelope fields
  var encryptedPayload: Data? = nil
  var cipherSuite: String? = nil
  var messageID: String? = nil
  var timestamp: Double? = nil
  var authTagHMAC: String? = nil

  /// Transient runtime flag (not serialized inside inner payload) indicating if this message was decrypted from an AES-256-GCM envelope.
  var isEncryptedOnWire: Bool? = nil

  static func make(_ kind: Kind) -> PeerMessage {
    let s = AppSettings.shared
    return PeerMessage(
      kind: kind,
      sender: s.effectiveDeviceName,
      key: nil,  // Never send pairing key in cleartext; key is used for HKDF AES-256-GCM & HMAC
      appVersion: AppInfo.version,
      appBuild: AppInfo.build,
      messageID: UUID().uuidString,
      timestamp: Date().timeIntervalSince1970
    )
  }

  /// Encodes the message as an AES-256-GCM encrypted envelope (or signed legacy frame if `encrypt` is false).
  func encodedLine(encrypt: Bool = AppSettings.shared.encryptNetworkTraffic) -> Data? {
    let wireMsg: PeerMessage
    if encrypt && kind != .encrypted {
      guard let sealed = try? PeerCrypto.seal(self) else { return nil }
      wireMsg = sealed
    } else {
      var signed = self
      if signed.messageID == nil { signed.messageID = UUID().uuidString }
      if signed.timestamp == nil { signed.timestamp = Date().timeIntervalSince1970 }
      signed.authTagHMAC = PeerCrypto.computeHMAC(for: signed)
      wireMsg = signed
    }
    guard var data = try? JSONEncoder().encode(wireMsg) else { return nil }
    data.append(0x0A)
    return data
  }
}

// MARK: - Cryptographic Transport Security (AES-256-GCM + HKDF-SHA256 + Replay Guard)

enum PeerCrypto {
  static let cipherName = "AES-256-GCM-HKDF-SHA256"
  private static let protocolSalt = Data("com.blueswitch.kvm.transport.v2".utf8)
  private static let maxClockSkewSeconds: TimeInterval = 180
  private static let replayLock = NSLock()
  private static var seenMessageIDs: [String: Date] = [:]

  /// Derives a 256-bit symmetric key from the user's `pairingKey` (if set) and service type using HKDF-SHA256.
  static func symmetricKey() -> SymmetricKey {
    let s = AppSettings.shared
    let secret = s.pairingKey.trimmingCharacters(in: .whitespacesAndNewlines)
    let ikmString = "blueswitch-v2|\(s.effectiveServiceType)|\(secret)"
    let ikm = SymmetricKey(data: Data(ikmString.utf8))
    return HKDF<SHA256>.deriveKey(
      inputKeyMaterial: ikm,
      salt: protocolSalt,
      info: Data("AES-256-GCM-Transport".utf8),
      outputByteCount: 32
    )
  }

  /// Seals a `PeerMessage` inside an authenticated AES-256-GCM envelope with AAD binding.
  static func seal(_ inner: PeerMessage) throws -> PeerMessage {
    var payload = inner
    let msgID = payload.messageID ?? UUID().uuidString
    let ts = payload.timestamp ?? Date().timeIntervalSince1970
    payload.messageID = msgID
    payload.timestamp = ts
    payload.authTagHMAC = computeHMAC(for: payload)

    let plaintext = try JSONEncoder().encode(payload)
    let aad = Data("\(msgID)|\(String(format: "%.3f", ts))|\(cipherName)".utf8)
    let nonce = AES.GCM.Nonce()
    let sealedBox = try AES.GCM.seal(plaintext, using: symmetricKey(), nonce: nonce, authenticating: aad)
    guard let combined = sealedBox.combined else {
      throw PeerError.encryptionFailed("Could not assemble AES-GCM sealed box")
    }

    return PeerMessage(
      kind: .encrypted,
      sender: inner.sender,
      appVersion: inner.appVersion,
      appBuild: inner.appBuild,
      encryptedPayload: combined,
      cipherSuite: cipherName,
      messageID: msgID,
      timestamp: ts
    )
  }

  /// Verifies replay window, authenticates AAD, and decrypts an AES-256-GCM `PeerMessage`.
  static func open(_ outer: PeerMessage) throws -> PeerMessage {
    guard let combined = outer.encryptedPayload,
      let msgID = outer.messageID,
      let ts = outer.timestamp
    else {
      throw PeerError.encryptionFailed("Malformed encrypted envelope")
    }
    let suite = outer.cipherSuite ?? cipherName
    try verifyReplayAndFreshness(messageID: msgID, timestamp: ts)

    let aad = Data("\(msgID)|\(String(format: "%.3f", ts))|\(suite)".utf8)
    let sealedBox = try AES.GCM.SealedBox(combined: combined)
    let decryptedData: Data
    do {
      decryptedData = try AES.GCM.open(sealedBox, using: symmetricKey(), authenticating: aad)
    } catch {
      throw PeerError.rejected(
        "AES-256-GCM decryption/authentication failed (check that Pairing Key matches on both Macs)")
    }

    var inner = try JSONDecoder().decode(PeerMessage.self, from: decryptedData)
    if let tag = inner.authTagHMAC {
      let expected = computeHMAC(for: inner)
      guard tag == expected else {
        throw PeerError.rejected("Inner HMAC integrity check failed")
      }
    }
    inner.isEncryptedOnWire = true
    return inner
  }

  static func computeHMAC(for msg: PeerMessage) -> String {
    let material =
      "\(msg.kind.rawValue)|\(msg.sender)|\(msg.messageID ?? "")|\(String(format: "%.3f", msg.timestamp ?? 0))|\(msg.updateSHA256 ?? "")"
    let mac = HMAC<SHA256>.authenticationCode(for: Data(material.utf8), using: symmetricKey())
    return mac.map { String(format: "%02x", $0) }.joined()
  }

  private static func verifyReplayAndFreshness(messageID: String, timestamp: TimeInterval) throws {
    let now = Date().timeIntervalSince1970
    if abs(now - timestamp) > maxClockSkewSeconds {
      throw PeerError.rejected("Message timestamp outside allowed window (possible replay attack)")
    }
    replayLock.lock()
    defer { replayLock.unlock() }
    // Prune expired IDs
    let cutoff = Date(timeIntervalSinceNow: -maxClockSkewSeconds)
    seenMessageIDs = seenMessageIDs.filter { $0.value > cutoff }
    if seenMessageIDs[messageID] != nil {
      throw PeerError.rejected("Duplicate messageID detected (replay attack blocked)")
    }
    seenMessageIDs[messageID] = Date()
  }
}

enum PeerError: LocalizedError {
  case timeout, invalidResponse, rejected(String), connection(String), invalidEndpoint
  case encryptionFailed(String)

  var errorDescription: String? {
    switch self {
    case .timeout: return "No response from peer (timed out). Is BlueSwitch running there?"
    case .invalidResponse: return "Peer sent an invalid response"
    case .rejected(let m): return "Peer rejected request: \(m)"
    case .connection(let m): return "Connection failed: \(m)"
    case .invalidEndpoint: return "Peer address or port is invalid"
    case .encryptionFailed(let m): return "Encryption error: \(m)"
    }
  }
}

/// Splits a TCP byte stream into newline-delimited messages and transparently decrypts AES-256-GCM envelopes.
struct LineBuffer {
  private var buffer = Data()

  enum DecodedFrame {
    case message(PeerMessage)
    case securityError(sender: String, reason: String)
  }

  mutating func append(_ data: Data) -> [DecodedFrame] {
    buffer.append(data)
    var out: [DecodedFrame] = []
    while let nl = buffer.firstIndex(of: 0x0A) {
      let line = buffer[buffer.startIndex..<nl]
      buffer.removeSubrange(buffer.startIndex...nl)
      guard !line.isEmpty else { continue }
      guard let rawMsg = try? JSONDecoder().decode(PeerMessage.self, from: Data(line)) else {
        out.append(.securityError(sender: "unknown", reason: "Malformed JSON frame"))
        continue
      }
      if rawMsg.kind == .encrypted {
        do {
          let opened = try PeerCrypto.open(rawMsg)
          out.append(.message(opened))
        } catch {
          out.append(
            .securityError(sender: rawMsg.sender, reason: error.localizedDescription))
        }
      } else {
        var unenc = rawMsg
        unenc.isEncryptedOnWire = false
        out.append(.message(unenc))
      }
    }
    return out
  }
}

/// One request → one response over a short-lived TCP connection with automatic AES-256-GCM encryption and audit logging.
final class PeerRequest {
  private let connection: NWConnection
  private let message: PeerMessage
  private let timeout: TimeInterval
  private let useEncryption: Bool
  private let allowLegacyFallback: Bool
  private var completion: ((Result<PeerMessage, PeerError>, NWEndpoint?) -> Void)?
  private var buffer = LineBuffer()
  private let queue = DispatchQueue(label: "com.blueswitch.request")
  private var selfRetain: PeerRequest?
  private let endpoint: NWEndpoint

  init(
    endpoint: NWEndpoint, message: PeerMessage, timeout: TimeInterval,
    useEncryption: Bool = AppSettings.shared.encryptNetworkTraffic,
    allowLegacyFallback: Bool = true,
    completion: @escaping (Result<PeerMessage, PeerError>, NWEndpoint?) -> Void
  ) {
    self.endpoint = endpoint
    self.connection = NWConnection(to: endpoint, using: .tcp)
    self.message = message
    self.timeout = timeout
    self.useEncryption = useEncryption
    self.allowLegacyFallback = allowLegacyFallback
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
    guard let data = message.encodedLine(encrypt: useEncryption) else {
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
      if let data, !data.isEmpty, let frame = self.buffer.append(data).first {
        switch frame {
        case .message(let msg):
          if msg.kind == .error {
            self.finish(.failure(.rejected(msg.body ?? "unknown error")))
          } else {
            self.finish(.success(msg))
          }
        case .securityError(_, let reason):
          self.finish(.failure(.rejected(reason)))
        }
        return
      }
      if let error {
        self.finish(.failure(.connection(error.localizedDescription)))
      } else if isComplete {
        // If the remote peer is an older v1.0.1/v1.0.2 instance that could not parse `.encrypted`,
        // fallback for `.ping` or `.installUpdate` so we can upgrade the peer to the encrypted version.
        if self.useEncryption && self.allowLegacyFallback
          && (self.message.kind == .ping || self.message.kind == .installUpdate)
        {
          SecurityMonitor.shared.recordAudit(
            category: "Security",
            message:
              "Peer at \(self.endpoint) closed connection on AES-256-GCM frame (legacy v1.0.2 peer); retrying \(self.message.kind.rawValue) with legacy frame for upgrade compatibility",
            level: .warning
          )
          let savedCompletion = self.completion
          self.completion = nil
          self.connection.cancel()
          self.selfRetain = nil
          if let savedCompletion {
            PeerRequest(
              endpoint: self.endpoint,
              message: self.message,
              timeout: self.timeout,
              useEncryption: false,
              allowLegacyFallback: false,
              completion: savedCompletion
            ).start()
          }
          return
        }
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
    Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0.7"
  }
  static var build: String {
    Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "8"
  }

  /// Compares two version strings (`"1.0.3"` vs `"1.0.2"`) and optional build numbers.
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
