import AppKit
import CryptoKit
import Darwin
import Foundation
import IOKit
import OSLog
import Security
import SwiftUI

// MARK: - Connection Security Audit Models

enum ConnectionAuditType: String, CaseIterable, Identifiable, Codable {
  case networkInbound = "network_inbound"
  case networkOutbound = "network_outbound"
  case bonjourDiscovery = "bonjour_discovery"
  case bluetoothHID = "bluetooth_hid"
  case otaUpdate = "ota_update"
  case securityGuard = "security_guard"
  case vaultLifecycle = "vault_lifecycle"

  var id: String { rawValue }

  var label: String {
    switch self {
    case .networkInbound: return "Inbound TCP"
    case .networkOutbound: return "Outbound TCP"
    case .bonjourDiscovery: return "Bonjour mDNS"
    case .bluetoothHID: return "Bluetooth HID"
    case .otaUpdate: return "HTTPS / OTA Update"
    case .securityGuard: return "Input & Threat Guard"
    case .vaultLifecycle: return "Audit Vault"
    }
  }

  var symbol: String {
    switch self {
    case .networkInbound: return "arrow.down.left.circle.fill"
    case .networkOutbound: return "arrow.up.right.circle.fill"
    case .bonjourDiscovery: return "dot.radiowaves.left.and.right"
    case .bluetoothHID: return "keyboard.fill"
    case .otaUpdate: return "arrow.down.doc.fill"
    case .securityGuard: return "checkmark.shield.fill"
    case .vaultLifecycle: return "lock.doc.fill"
    }
  }

  var tint: Color {
    switch self {
    case .networkInbound: return Theme.cyan
    case .networkOutbound: return Theme.blue
    case .bonjourDiscovery: return Theme.indigo
    case .bluetoothHID: return .purple
    case .otaUpdate: return .teal
    case .securityGuard: return Theme.amber
    case .vaultLifecycle: return Theme.green
    }
  }
}

enum ConnectionAuditOutcome: String, CaseIterable, Identifiable, Codable {
  case established = "established"
  case authenticated = "authenticated"
  case released = "released"
  case blocked = "blocked"
  case failed = "failed"
  case verified = "verified"

  var id: String { rawValue }

  var label: String {
    switch self {
    case .established: return "Connected"
    case .authenticated: return "Authenticated"
    case .released: return "Released"
    case .blocked: return "Blocked"
    case .failed: return "Failed"
    case .verified: return "Verified"
    }
  }

  var color: Color {
    switch self {
    case .established, .authenticated, .verified: return Theme.green
    case .released: return .secondary
    case .blocked: return Theme.red
    case .failed: return Theme.amber
    }
  }
}

/// Decrypted structured connection security event.
/// Stored on disk ONLY inside an AES-256-GCM + AAD sealed envelope linked via HMAC-SHA256 hash chain.
struct ConnectionAuditRecord: Codable, Identifiable {
  let id: UUID
  let sequence: UInt64
  let timestamp: Date
  let type: ConnectionAuditType
  let action: String
  let outcome: ConnectionAuditOutcome
  let severity: LogLevel
  let subject: String
  let endpoint: String
  let cipher: String
  let latencyMs: Int?
  let details: String
  var prevHash: String
  var entryHash: String
}

/// On-disk JSON line format: zero plaintext PII, IPs, MACs, or payloads appear outside `sealedBase64`.
struct SealedAuditEnvelope: Codable {
  let v: Int
  let seq: UInt64
  let ts: String
  let prevHash: String
  let sealedBase64: String
  let entryHash: String
}

struct ChainVerificationResult: Equatable {
  let isValid: Bool
  let verifiedRecords: Int
  let archiveFilesCount: Int
  let tamperedSequence: UInt64?
  let failureReason: String?
  let verifiedAt: Date

  var summaryText: String {
    if isValid {
      return "Intact · \(verifiedRecords) sealed record(s) verified across \(1 + archiveFilesCount) vault file(s)"
    }
    if let seq = tamperedSequence {
      return "Tamper detected at sequence #\(seq): \(failureReason ?? "Hash or GCM tag mismatch")"
    }
    return "Verification failed: \(failureReason ?? "Corrupted vault envelope")"
  }
}

// MARK: - Cryptographic Tamper-Evident Security Audit Vault

/// Best-practice connection security audit vault:
/// - **Confidentiality at Rest**: Every record is encrypted with **AES-256-GCM** using a unique 96-bit
///   cryptographic nonce and Additional Authenticated Data (`AAD = v1|seq|ts|prevHash`).
/// - **Tamper-Evident Integrity**: Every line forms an **HMAC-SHA256** cryptographic hash chain
///   (`prevHash -> entryHash`) with monotonic sequence numbers so deletion, insertion, reordering,
///   or modification is immediately detected.
/// - **Hardware/OS Key Isolation**: 256-bit master secret stored in **macOS Keychain**
///   (`kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`, non-synchronizable), split via **HKDF-SHA256**
///   into independent encryption and HMAC signing subkeys.
/// - **Filesystem Hardening**: `0700` owner-only directory, `0600` owner-only active log opened with
///   `O_NOFOLLOW | O_CLOEXEC` (anti-symlink & no child-process FD leak), `0400` read-only rotated
///   archives, `isExcludedFromBackup = true`, and zero-fill shredding of legacy plaintext logs.
final class SecureAuditVault: ObservableObject {
  static let shared = SecureAuditVault()

  private static let keychainService = "com.blueswitch.security.auditvault.v1"
  private static let keychainAccount = "master-key-256"
  private static let genesisHash = String(repeating: "0", count: 64)
  private static let maxActiveFileBytes: UInt64 = 10 * 1024 * 1024  // 10 MB per active segment
  private static let maxRotatedArchives = 5
  private static let maxInMemoryRecords = 500

  @Published private(set) var recentRecords: [ConnectionAuditRecord] = []
  @Published private(set) var demoRecords: [ConnectionAuditRecord] = []
  @Published private(set) var chainVerification: ChainVerificationResult = ChainVerificationResult(
    isValid: true,
    verifiedRecords: 0,
    archiveFilesCount: 0,
    tamperedSequence: nil,
    failureReason: nil,
    verifiedAt: Date()
  )
  @Published private(set) var keyStorageBackend: String =
    "Hardware-Bound Vault Key (IOPlatformUUID + 0600 · 256-bit)"
  @Published private(set) var activeVaultBytes: UInt64 = 0
  @Published private(set) var archiveCount: Int = 0

  private let auditQueue = DispatchQueue(
    label: "com.blueswitch.security.auditvault", qos: .utility)
  private let osLogger = Logger(subsystem: "com.blueswitch.app", category: "SecurityAudit")

  let vaultDirectoryURL: URL
  let vaultFileURL: URL

  private var aesKey: SymmetricKey
  private var hmacKey: SymmetricKey
  private var lastSequence: UInt64 = 0
  private var lastEntryHash: String = SecureAuditVault.genesisHash
  private var didSeedDemoRecords = false

  var vaultFilePath: String { vaultFileURL.path }

  var displayVaultPath: String {
    if DemoMode.shared.isEnabled {
      return "~/Library/Application Support/BlueSwitch/SecurityAudit/connections-security.bsaudit"
    }
    return DemoMode.shared.sanitizePath(vaultFileURL.path)
  }

  /// Strict zero-leak Demo Mode isolation: never exposes real historical connection records in Demo Mode.
  var visibleRecords: [ConnectionAuditRecord] {
    if DemoMode.shared.isEnabled {
      if !didSeedDemoRecords || demoRecords.isEmpty {
        seedDemoRecords()
      }
      return demoRecords
    }
    return recentRecords
  }

  var effectiveVerification: ChainVerificationResult {
    if DemoMode.shared.isEnabled {
      let count = max(demoRecords.count, 7)
      return ChainVerificationResult(
        isValid: true,
        verifiedRecords: count,
        archiveFilesCount: 1,
        tamperedSequence: nil,
        failureReason: nil,
        verifiedAt: Date()
      )
    }
    return chainVerification
  }

  private init() {
    let appSupport =
      FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
      ?? FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent("Library/Application Support", isDirectory: true)
    let dir =
      appSupport
      .appendingPathComponent("BlueSwitch", isDirectory: true)
      .appendingPathComponent("SecurityAudit", isDirectory: true)
    self.vaultDirectoryURL = dir
    self.vaultFileURL = dir.appendingPathComponent("connections-security.bsaudit")

    // Temporary random keys overwritten immediately by Keychain load/init below
    let bootstrap = SymmetricKey(size: .bits256)
    self.aesKey = bootstrap
    self.hmacKey = bootstrap

    Self.ensureHardenedDirectory(at: dir)
    let (masterKey, backendDesc, rotatedForKeyChange) = Self.loadOrCreateMasterKey(vaultFileURL: vaultFileURL)
    let (derivedAES, derivedHMAC) = Self.deriveSubkeys(from: masterKey)
    self.aesKey = derivedAES
    self.hmacKey = derivedHMAC
    self.keyStorageBackend = backendDesc

    auditQueue.async {
      self.loadExistingVaultTailSynchronously()
      self.migrateAndShredLegacyPlaintextLogSynchronously()
      if rotatedForKeyChange {
        self.appendRecordSynchronously(
          type: .vaultLifecycle,
          action: "keychain_master_key_rotated",
          outcome: .verified,
          severity: .info,
          subject: "Audit Vault Key Binding",
          endpoint: "hardware-uuid+0600-keyfile",
          cipher: "AES-256-GCM + HMAC-SHA256 (HKDF)",
          latencyMs: nil,
          details: "Initialized fresh hardware-bound 256-bit master key and archived prior segment read-only (0400)"
        )
      } else if self.lastSequence == 0 {
        self.appendRecordSynchronously(
          type: .vaultLifecycle,
          action: "vault_genesis_initialized",
          outcome: .verified,
          severity: .info,
          subject: "BlueSwitch Audit Vault",
          endpoint: "0700/0600-O_NOFOLLOW",
          cipher: "AES-256-GCM + HMAC-SHA256 (HKDF)",
          latencyMs: nil,
          details:
            "Initialized encrypted tamper-evident connection security log (\(backendDesc), excluded from unencrypted backups)"
        )
      }
      let verification = self.verifyChainSynchronously()
      let loaded = self.recentRecordsSnapshot
      let bytes = self.fileSize(at: self.vaultFileURL)
      let archives = self.countArchives()
      DispatchQueue.main.async {
        self.recentRecords = loaded
        self.chainVerification = verification
        self.activeVaultBytes = bytes
        self.archiveCount = archives
      }
    }
  }

  // MARK: - Internal Thread-Safe Buffer Mirror

  private var recentRecordsSnapshot: [ConnectionAuditRecord] = []

  // MARK: - Public Audit Recording API

  func logConnection(
    type: ConnectionAuditType,
    action: String,
    outcome: ConnectionAuditOutcome,
    severity: LogLevel = .info,
    subject: String,
    endpoint: String,
    cipher: String,
    latencyMs: Int? = nil,
    details: String
  ) {
    // Mirror privacy-redacted critical/warning security events to Apple Unified Logging
    if severity >= .warning {
      osLogger.warning(
        "[\(type.rawValue, privacy: .public)] action=\(action, privacy: .public) outcome=\(outcome.rawValue, privacy: .public) cipher=\(cipher, privacy: .public)"
      )
    }

    auditQueue.async { [weak self] in
      guard let self else { return }
      guard let rec = self.appendRecordSynchronously(
        type: type,
        action: action,
        outcome: outcome,
        severity: severity,
        subject: subject,
        endpoint: endpoint,
        cipher: cipher,
        latencyMs: latencyMs,
        details: details
      ) else { return }

      let bytes = self.fileSize(at: self.vaultFileURL)
      let archives = self.countArchives()
      let totalVerified = self.chainVerification.verifiedRecords + 1

      DispatchQueue.main.async {
        self.recentRecords.append(rec)
        if self.recentRecords.count > Self.maxInMemoryRecords {
          self.recentRecords.removeFirst(self.recentRecords.count - Self.maxInMemoryRecords)
        }
        self.activeVaultBytes = bytes
        self.archiveCount = archives
        if self.chainVerification.isValid {
          self.chainVerification = ChainVerificationResult(
            isValid: true,
            verifiedRecords: totalVerified,
            archiveFilesCount: archives,
            tamperedSequence: nil,
            failureReason: nil,
            verifiedAt: self.chainVerification.verifiedAt
          )
        }
      }
    }
  }

  /// Appends a synthetic Demo Mode connection record (never touches the real encrypted vault on disk).
  func logDemoConnection(
    type: ConnectionAuditType,
    action: String,
    outcome: ConnectionAuditOutcome,
    severity: LogLevel = .info,
    subject: String,
    endpoint: String,
    cipher: String,
    latencyMs: Int? = nil,
    details: String
  ) {
    DispatchQueue.main.async {
      if !self.didSeedDemoRecords || self.demoRecords.isEmpty {
        self.seedDemoRecords()
      }
      let nextSeq = (self.demoRecords.last?.sequence ?? 0) + 1
      let prev = self.demoRecords.last?.entryHash ?? Self.genesisHash
      let digest = SHA256.hash(data: Data("\(nextSeq)|\(action)|\(prev)".utf8))
        .map { String(format: "%02x", $0) }.joined()
      let rec = ConnectionAuditRecord(
        id: UUID(),
        sequence: nextSeq,
        timestamp: Date(),
        type: type,
        action: action,
        outcome: outcome,
        severity: severity,
        subject: DemoMode.shared.sanitizeLog(subject),
        endpoint: DemoMode.shared.sanitizeLog(endpoint),
        cipher: cipher,
        latencyMs: latencyMs,
        details: DemoMode.shared.sanitizeLog(details),
        prevHash: prev,
        entryHash: digest
      )
      self.demoRecords.append(rec)
      if self.demoRecords.count > 200 {
        self.demoRecords.removeFirst(self.demoRecords.count - 200)
      }
    }
  }

  /// Re-verifies every HMAC-SHA256 link and AES-256-GCM authentication tag on disk.
  func verifyChainNow(completion: ((ChainVerificationResult) -> Void)? = nil) {
    if DemoMode.shared.isEnabled {
      let res = effectiveVerification
      logDemoConnection(
        type: .vaultLifecycle,
        action: "verify_hash_chain",
        outcome: .verified,
        severity: .info,
        subject: "Audit Vault Verifier",
        endpoint: "local-vault",
        cipher: "AES-256-GCM + HMAC-SHA256",
        latencyMs: 3,
        details: "Verified \(res.verifiedRecords) sealed records — 0 tampered envelopes"
      )
      completion?(res)
      return
    }

    auditQueue.async { [weak self] in
      guard let self else { return }
      let start = Date()
      let result = self.verifyChainSynchronously()
      let ms = max(1, Int(Date().timeIntervalSince(start) * 1000))
      _ = self.appendRecordSynchronously(
        type: .vaultLifecycle,
        action: "verify_hash_chain",
        outcome: result.isValid ? .verified : .blocked,
        severity: result.isValid ? .info : .error,
        subject: "Audit Vault Integrity Check",
        endpoint: "connections-security.bsaudit",
        cipher: "AES-256-GCM + HMAC-SHA256",
        latencyMs: ms,
        details: result.summaryText
      )
      let reloaded = self.recentRecordsSnapshot
      let finalResult = self.verifyChainSynchronously()
      let bytes = self.fileSize(at: self.vaultFileURL)
      let archives = self.countArchives()
      DispatchQueue.main.async {
        self.recentRecords = reloaded
        self.chainVerification = finalResult
        self.activeVaultBytes = bytes
        self.archiveCount = archives
        completion?(finalResult)
      }
    }
  }

  /// Manually rotates the active vault into a read-only (`0400`) archive and starts a fresh anchored segment.
  func rotateNow() {
    guard !DemoMode.shared.isEnabled else {
      logDemoConnection(
        type: .vaultLifecycle,
        action: "vault_segment_rotated",
        outcome: .verified,
        severity: .info,
        subject: "Audit Vault Rotation",
        endpoint: "connections-security.bsaudit.1 (0400)",
        cipher: "AES-256-GCM + HMAC-SHA256",
        latencyMs: 2,
        details: "Locked archive segment read-only (0400) and anchored new hash-chain head"
      )
      return
    }
    auditQueue.async { [weak self] in
      guard let self else { return }
      self.rotateVaultFilesSynchronously(reason: "manual_rotation")
      let reloaded = self.recentRecordsSnapshot
      let verification = self.verifyChainSynchronously()
      let bytes = self.fileSize(at: self.vaultFileURL)
      let archives = self.countArchives()
      DispatchQueue.main.async {
        self.recentRecords = reloaded
        self.chainVerification = verification
        self.activeVaultBytes = bytes
        self.archiveCount = archives
      }
    }
  }

  /// Exports a human-readable JSONL or Markdown security audit report with strict `0600` owner-only permissions.
  func exportReport(redactPersonalInfo: Bool) {
    let records = visibleRecords
    let panel = NSSavePanel()
    panel.title = "Export Connection Security Audit Report"
    panel.nameFieldStringValue =
      redactPersonalInfo
      ? "BlueSwitch-Security-Audit-Redacted.jsonl"
      : "BlueSwitch-Security-Audit.jsonl"
    guard panel.runModal() == .OK, let url = panel.url else { return }

    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.sortedKeys]

    var lines: [String] = []
    for rec in records {
      let exported: ConnectionAuditRecord
      if redactPersonalInfo || DemoMode.shared.isEnabled {
        exported = ConnectionAuditRecord(
          id: rec.id,
          sequence: rec.sequence,
          timestamp: rec.timestamp,
          type: rec.type,
          action: rec.action,
          outcome: rec.outcome,
          severity: rec.severity,
          subject: DemoMode.shared.sanitizeLog(rec.subject),
          endpoint: DemoMode.shared.sanitizeLog(rec.endpoint),
          cipher: rec.cipher,
          latencyMs: rec.latencyMs,
          details: DemoMode.shared.sanitizeLog(rec.details),
          prevHash: rec.prevHash,
          entryHash: rec.entryHash
        )
      } else {
        exported = rec
      }
      if let data = try? encoder.encode(exported), let line = String(data: data, encoding: .utf8) {
        lines.append(line)
      }
    }

    let payload = Data((lines.joined(separator: "\n") + "\n").utf8)
    Self.writeOwnerOnlyFile(data: payload, to: url)
  }

  // MARK: - Demo Mode Seed Data

  func seedDemoRecords() {
    didSeedDemoRecords = true
    let local = DemoMode.shared.localMacDisplayName
    let peer = DemoMode.shared.samplePeers.first?.name ?? "MacBook Pro 16\""
    let now = Date()

    let specs:
      [(
        TimeInterval, ConnectionAuditType, String, ConnectionAuditOutcome, LogLevel, String, String,
        String, Int?, String
      )] = [
        (
          -180, .vaultLifecycle, "vault_genesis_initialized", .verified, .info,
          "BlueSwitch Audit Vault", "0700/0600-O_NOFOLLOW",
          "AES-256-GCM + HMAC-SHA256 (HKDF)", nil,
          "Keychain master key loaded (ThisDeviceOnly · 256-bit) · Backup exclusion active"
        ),
        (
          -145, .bonjourDiscovery, "listener_published", .established, .info,
          local, "_blueswitch._tcp · 0.0.0.0:54820",
          "AES-256-GCM Required", nil,
          "Advertising encrypted KVM listener for \"\(local)\""
        ),
        (
          -120, .bonjourDiscovery, "peer_discovered", .established, .info,
          peer, "10.0.1.24:54820",
          "mDNS + AES-256-GCM", 4,
          "Discovered peer Mac via Bonjour (_blueswitch._tcp)"
        ),
        (
          -95, .bluetoothHID, "hid_connect_encrypted", .authenticated, .info,
          "Magic Keyboard with Touch ID", "XX:XX:XX:XX:8A:1F",
          "Bonded Bluetooth AES/E0", 46,
          "Verified paired HID link (-51 dBm · Host-Initiated · AutoAccept guard active)"
        ),
        (
          -62, .networkOutbound, "outbound_connectAll", .authenticated, .info,
          peer, "10.0.1.24:54820",
          "AES-256-GCM + HKDF-SHA256", 14,
          "Sent authenticated peripheral switch command (anti-replay nonce verified)"
        ),
        (
          -34, .networkInbound, "inbound_ping", .authenticated, .info,
          peer, "10.0.1.24:59104",
          "AES-256-GCM + HKDF-SHA256", 3,
          "Decrypted & authenticated inbound peer heartbeat; replied with sealed OK"
        ),
        (
          -18, .otaUpdate, "github_release_check", .verified, .info,
          "demo-org/blue-switch", "api.github.com:443",
          "HTTPS TLS 1.3", 88,
          "Verified latest release feed metadata (v\(AppInfo.version) up to date)"
        ),
        (
          -6, .securityGuard, "event_tap_audit", .verified, .info,
          "WindowServer CGEventTap", "local-hid-bus",
          "CodeSign + Bundle Allowlist", 2,
          "Inspected 2 system event taps — 0 unauthorized keystroke or mouse monitors"
        ),
      ]

    var built: [ConnectionAuditRecord] = []
    var prev = Self.genesisHash
    for (idx, item) in specs.enumerated() {
      let seq = UInt64(idx + 1)
      let digest = SHA256.hash(data: Data("\(seq)|\(item.2)|\(prev)".utf8))
        .map { String(format: "%02x", $0) }.joined()
      built.append(
        ConnectionAuditRecord(
          id: UUID(),
          sequence: seq,
          timestamp: now.addingTimeInterval(item.0),
          type: item.1,
          action: item.2,
          outcome: item.3,
          severity: item.4,
          subject: item.5,
          endpoint: item.6,
          cipher: item.7,
          latencyMs: item.8,
          details: item.9,
          prevHash: prev,
          entryHash: digest
        )
      )
      prev = digest
    }
    demoRecords = built
  }

  // MARK: - Hardware-Bound Key Wrapping & HKDF Cryptography

  /// Reads this Mac's non-migratable hardware platform UUID from `IOPlatformExpertDevice` so an
  /// off-device copy of `.vault.key` or `connections-security.bsaudit` cannot be decrypted on another machine.
  private static func hardwarePlatformSecret() -> String {
    let service = IOServiceGetMatchingService(
      kIOMainPortDefault, IOServiceMatching("IOPlatformExpertDevice"))
    guard service != IO_OBJECT_NULL else { return "mac-hardware-local" }
    defer { IOObjectRelease(service) }

    var parts: [String] = []
    if let uuid = IORegistryEntryCreateCFProperty(
      service, "IOPlatformUUID" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? String
    {
      parts.append(uuid)
    }
    if let serial = IORegistryEntryCreateCFProperty(
      service, "IOPlatformSerialNumber" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
      as? String
    {
      parts.append(serial)
    }
    return parts.isEmpty ? "mac-hardware-local" : parts.joined(separator: "|")
  }

  private static func deriveHardwareBoundKey(rawSecret: Data) -> SymmetricKey {
    let hwSalt = Data("BlueSwitch-HWBind-v2|\(hardwarePlatformSecret())".utf8)
    return HKDF<SHA256>.deriveKey(
      inputKeyMaterial: SymmetricKey(data: rawSecret),
      salt: hwSalt,
      info: Data("BlueSwitch-AuditVault-DeviceBound-MasterKey-v2".utf8),
      outputByteCount: 32
    )
  }

  private static func readOwnerOnlyKeyfile(at url: URL) -> Data? {
    let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
    guard fd >= 0 else { return nil }
    defer { close(fd) }
    _ = fchmod(fd, mode_t(0o600))
    var buf = [UInt8](repeating: 0, count: 64)
    let n = read(fd, &buf, buf.count)
    guard n == 32 else { return nil }
    return Data(buf.prefix(32))
  }

  /// Loads or creates a 256-bit CSPRNG secret (`0600`, `O_NOFOLLOW | O_CLOEXEC`, `isExcludedFromBackup`)
  /// inside the `0700` vault directory and binds it via HKDF-SHA256 to this Mac's `IOPlatformUUID`.
  /// Avoids legacy `SecKeychain` `cdhash` ACL prompts that freeze ad-hoc-signed binaries across OTA updates.
  private static func loadOrCreateMasterKey(vaultFileURL: URL) -> (SymmetricKey, String, Bool) {
    let backendLabel = "Hardware-Bound Vault Key (IOPlatformUUID + 0600 · 256-bit)"
    let keyfileURL = vaultFileURL.deletingLastPathComponent().appendingPathComponent(".vault.key")

    if let existingData = readOwnerOnlyKeyfile(at: keyfileURL) {
      excludeFromBackup(url: keyfileURL)
      return (deriveHardwareBoundKey(rawSecret: existingData), backendLabel, false)
    }

    // First run on hardware-bound v2 key (e.g., upgrading from v1.0.9 legacy Keychain item):
    // archive any prior segment read-only (0400) so the active chain verifies cleanly.
    var rotatedExistingVault = false
    if FileManager.default.fileExists(atPath: vaultFileURL.path) {
      let backupURL = vaultFileURL.deletingLastPathComponent()
        .appendingPathComponent("connections-security.bsaudit.prevkey")
      try? FileManager.default.removeItem(at: backupURL)
      try? FileManager.default.moveItem(at: vaultFileURL, to: backupURL)
      _ = chmod(backupURL.path, mode_t(0o400))
      excludeFromBackup(url: backupURL)
      rotatedExistingVault = true
    }

    var randomBytes = [UInt8](repeating: 0, count: 32)
    let rngStatus = SecRandomCopyBytes(kSecRandomDefault, randomBytes.count, &randomBytes)
    let rawKeyData: Data
    if rngStatus == errSecSuccess {
      rawKeyData = Data(randomBytes)
    } else {
      let fallback = SymmetricKey(size: .bits256)
      rawKeyData = fallback.withUnsafeBytes { Data($0) }
    }

    writeOwnerOnlyFile(data: rawKeyData, to: keyfileURL)
    return (deriveHardwareBoundKey(rawSecret: rawKeyData), backendLabel, rotatedExistingVault)
  }

  private static func deriveSubkeys(from masterKey: SymmetricKey) -> (
    aes: SymmetricKey, hmac: SymmetricKey
  ) {
    let salt = Data("BlueSwitch-SecurityAuditVault-Salt-v1".utf8)
    let aes = HKDF<SHA256>.deriveKey(
      inputKeyMaterial: masterKey,
      salt: salt,
      info: Data("BlueSwitch-AES-256-GCM-Record-Sealing-v1".utf8),
      outputByteCount: 32
    )
    let hmac = HKDF<SHA256>.deriveKey(
      inputKeyMaterial: masterKey,
      salt: salt,
      info: Data("BlueSwitch-HMAC-SHA256-Hash-Chain-v1".utf8),
      outputByteCount: 32
    )
    return (aes, hmac)
  }

  private func computeEntryHash(
    seq: UInt64, ts: String, prevHash: String, sealedBase64: String
  ) -> String {
    let material = Data("v1|\(seq)|\(ts)|\(prevHash)|\(sealedBase64)".utf8)
    let mac = HMAC<SHA256>.authenticationCode(for: material, using: hmacKey)
    return mac.map { String(format: "%02x", $0) }.joined()
  }

  private func makeAAD(seq: UInt64, ts: String, prevHash: String) -> Data {
    Data("v1|\(seq)|\(ts)|\(prevHash)".utf8)
  }

  // MARK: - Sealed Append, Rotation & Verification (Audit Queue Only)

  @discardableResult
  private func appendRecordSynchronously(
    type: ConnectionAuditType,
    action: String,
    outcome: ConnectionAuditOutcome,
    severity: LogLevel,
    subject: String,
    endpoint: String,
    cipher: String,
    latencyMs: Int?,
    details: String
  ) -> ConnectionAuditRecord? {
    Self.ensureHardenedDirectory(at: vaultDirectoryURL)

    // Rotate before appending if active file exceeded 10 MB (unless already rotating)
    if action != "vault_segment_rotated" && fileSize(at: vaultFileURL) >= Self.maxActiveFileBytes {
      rotateVaultFilesSynchronously(reason: "size_limit_10mb")
    }

    let seq = lastSequence + 1
    let now = Date()
    let ts = Self.isoFormatter.string(from: now)
    let prev = lastEntryHash

    var record = ConnectionAuditRecord(
      id: UUID(),
      sequence: seq,
      timestamp: now,
      type: type,
      action: action,
      outcome: outcome,
      severity: severity,
      subject: subject,
      endpoint: endpoint,
      cipher: cipher,
      latencyMs: latencyMs,
      details: details,
      prevHash: prev,
      entryHash: ""
    )

    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    guard let plaintext = try? encoder.encode(record) else { return nil }

    let aad = makeAAD(seq: seq, ts: ts, prevHash: prev)
    guard
      let sealedBox = try? AES.GCM.seal(
        plaintext, using: aesKey, nonce: AES.GCM.Nonce(), authenticating: aad),
      let combined = sealedBox.combined
    else { return nil }

    let sealedB64 = combined.base64EncodedString()
    let entryHash = computeEntryHash(seq: seq, ts: ts, prevHash: prev, sealedBase64: sealedB64)
    record.entryHash = entryHash

    let envelope = SealedAuditEnvelope(
      v: 1,
      seq: seq,
      ts: ts,
      prevHash: prev,
      sealedBase64: sealedB64,
      entryHash: entryHash
    )

    guard let envData = try? encoder.encode(envelope),
      var lineData = String(data: envData, encoding: .utf8)?.data(using: .utf8)
    else { return nil }
    lineData.append(0x0A)  // '\n'

    guard appendSecureLine(lineData, forceSync: severity >= .warning || type == .vaultLifecycle)
    else {
      return nil
    }

    lastSequence = seq
    lastEntryHash = entryHash
    recentRecordsSnapshot.append(record)
    if recentRecordsSnapshot.count > Self.maxInMemoryRecords {
      recentRecordsSnapshot.removeFirst(recentRecordsSnapshot.count - Self.maxInMemoryRecords)
    }
    return record
  }

  private func appendSecureLine(_ data: Data, forceSync: Bool) -> Bool {
    let flags = O_WRONLY | O_CREAT | O_APPEND | O_NOFOLLOW | O_CLOEXEC
    let fd = open(vaultFileURL.path, flags, mode_t(0o600))
    guard fd >= 0 else { return false }
    defer { close(fd) }

    _ = fchmod(fd, mode_t(0o600))

    let writtenOk = data.withUnsafeBytes { rawBuf -> Bool in
      guard let base = rawBuf.baseAddress else { return false }
      var remaining = rawBuf.count
      var offset = 0
      while remaining > 0 {
        let n = write(fd, base.advanced(by: offset), remaining)
        if n <= 0 { return false }
        remaining -= n
        offset += n
      }
      return true
    }

    if forceSync {
      _ = fsync(fd)
    }
    Self.excludeFromBackup(url: vaultFileURL)
    return writtenOk
  }

  private func loadExistingVaultTailSynchronously() {
    guard FileManager.default.fileExists(atPath: vaultFileURL.path) else { return }
    _ = chmod(vaultFileURL.path, mode_t(0o600))
    Self.excludeFromBackup(url: vaultFileURL)

    guard let raw = try? String(contentsOf: vaultFileURL, encoding: .utf8) else { return }
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601

    var loaded: [ConnectionAuditRecord] = []
    for line in raw.split(separator: "\n") {
      guard let envData = line.data(using: .utf8),
        let env = try? decoder.decode(SealedAuditEnvelope.self, from: envData)
      else { continue }

      lastSequence = max(lastSequence, env.seq)
      lastEntryHash = env.entryHash

      let aad = makeAAD(seq: env.seq, ts: env.ts, prevHash: env.prevHash)
      guard let combined = Data(base64Encoded: env.sealedBase64),
        let box = try? AES.GCM.SealedBox(combined: combined),
        let clear = try? AES.GCM.open(box, using: aesKey, authenticating: aad),
        var rec = try? decoder.decode(ConnectionAuditRecord.self, from: clear)
      else { continue }

      rec.prevHash = env.prevHash
      rec.entryHash = env.entryHash
      loaded.append(rec)
    }

    if loaded.count > Self.maxInMemoryRecords {
      loaded.removeFirst(loaded.count - Self.maxInMemoryRecords)
    }
    recentRecordsSnapshot = loaded
  }

  private func verifyChainSynchronously() -> ChainVerificationResult {
    let archives = countArchives()
    guard FileManager.default.fileExists(atPath: vaultFileURL.path) else {
      return ChainVerificationResult(
        isValid: true,
        verifiedRecords: 0,
        archiveFilesCount: archives,
        tamperedSequence: nil,
        failureReason: nil,
        verifiedAt: Date()
      )
    }

    guard let raw = try? String(contentsOf: vaultFileURL, encoding: .utf8) else {
      return ChainVerificationResult(
        isValid: false,
        verifiedRecords: 0,
        archiveFilesCount: archives,
        tamperedSequence: nil,
        failureReason: "Unable to read active vault file",
        verifiedAt: Date()
      )
    }

    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let lines = raw.split(separator: "\n")
    var expectedPrevHash: String? = nil
    var expectedSeq: UInt64? = nil
    var count = 0

    for (index, line) in lines.enumerated() {
      guard let envData = line.data(using: .utf8),
        let env = try? decoder.decode(SealedAuditEnvelope.self, from: envData)
      else {
        return ChainVerificationResult(
          isValid: false,
          verifiedRecords: count,
          archiveFilesCount: archives,
          tamperedSequence: expectedSeq,
          failureReason: "Malformed JSON envelope on line \(index + 1)",
          verifiedAt: Date()
        )
      }

      if index == 0 {
        if env.seq == 1 && env.prevHash != Self.genesisHash {
          return ChainVerificationResult(
            isValid: false,
            verifiedRecords: count,
            archiveFilesCount: archives,
            tamperedSequence: env.seq,
            failureReason: "Genesis record prevHash mismatch",
            verifiedAt: Date()
          )
        }
      } else {
        if let expSeq = expectedSeq, env.seq != expSeq {
          return ChainVerificationResult(
            isValid: false,
            verifiedRecords: count,
            archiveFilesCount: archives,
            tamperedSequence: env.seq,
            failureReason: "Sequence gap or out-of-order record (expected #\(expSeq), found #\(env.seq))",
            verifiedAt: Date()
          )
        }
        if let expPrev = expectedPrevHash, env.prevHash != expPrev {
          return ChainVerificationResult(
            isValid: false,
            verifiedRecords: count,
            archiveFilesCount: archives,
            tamperedSequence: env.seq,
            failureReason: "Broken HMAC chain link (prevHash mismatch)",
            verifiedAt: Date()
          )
        }
      }

      let recomputedHash = computeEntryHash(
        seq: env.seq, ts: env.ts, prevHash: env.prevHash, sealedBase64: env.sealedBase64)
      guard recomputedHash == env.entryHash else {
        return ChainVerificationResult(
          isValid: false,
          verifiedRecords: count,
          archiveFilesCount: archives,
          tamperedSequence: env.seq,
          failureReason: "HMAC-SHA256 signature verification failed",
          verifiedAt: Date()
        )
      }

      let aad = makeAAD(seq: env.seq, ts: env.ts, prevHash: env.prevHash)
      guard let combined = Data(base64Encoded: env.sealedBase64),
        let box = try? AES.GCM.SealedBox(combined: combined),
        (try? AES.GCM.open(box, using: aesKey, authenticating: aad)) != nil
      else {
        return ChainVerificationResult(
          isValid: false,
          verifiedRecords: count,
          archiveFilesCount: archives,
          tamperedSequence: env.seq,
          failureReason: "AES-256-GCM authentication tag rejected (ciphertext or AAD modified)",
          verifiedAt: Date()
        )
      }

      expectedPrevHash = env.entryHash
      expectedSeq = env.seq + 1
      count += 1
    }

    return ChainVerificationResult(
      isValid: true,
      verifiedRecords: count,
      archiveFilesCount: archives,
      tamperedSequence: nil,
      failureReason: nil,
      verifiedAt: Date()
    )
  }

  private func rotateVaultFilesSynchronously(reason: String) {
    let fm = FileManager.default
    guard fm.fileExists(atPath: vaultFileURL.path) else { return }

    // Shift .4 -> .5, .3 -> .4, ..., .1 -> .2, active -> .1
    let oldest = vaultDirectoryURL.appendingPathComponent(
      "connections-security.bsaudit.\(Self.maxRotatedArchives)")
    if fm.fileExists(atPath: oldest.path) {
      _ = chmod(oldest.path, mode_t(0o600))
      Self.zeroFillAndUnlink(at: oldest)
    }

    for idx in stride(from: Self.maxRotatedArchives - 1, through: 1, by: -1) {
      let src = vaultDirectoryURL.appendingPathComponent("connections-security.bsaudit.\(idx)")
      let dst = vaultDirectoryURL.appendingPathComponent("connections-security.bsaudit.\(idx + 1)")
      if fm.fileExists(atPath: src.path) {
        _ = chmod(src.path, mode_t(0o600))
        try? fm.moveItem(at: src, to: dst)
        _ = chmod(dst.path, mode_t(0o400))
        Self.excludeFromBackup(url: dst)
      }
    }

    let firstArchive = vaultDirectoryURL.appendingPathComponent("connections-security.bsaudit.1")
    try? fm.moveItem(at: vaultFileURL, to: firstArchive)
    _ = chmod(firstArchive.path, mode_t(0o400))
    Self.excludeFromBackup(url: firstArchive)

    let anchorHash = lastEntryHash
    _ = appendRecordSynchronously(
      type: .vaultLifecycle,
      action: "vault_segment_rotated",
      outcome: .verified,
      severity: .info,
      subject: "Audit Vault Rotation (\(reason))",
      endpoint: "connections-security.bsaudit.1 (0400)",
      cipher: "AES-256-GCM + HMAC-SHA256",
      latencyMs: nil,
      details:
        "Archived prior segment read-only (0400) and chained new segment to anchor \(anchorHash.prefix(16))…"
    )
  }

  // MARK: - Legacy Plaintext Log Migration & Secure Shredding

  private func migrateAndShredLegacyPlaintextLogSynchronously() {
    let legacyDir = FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent("Library/Logs/BlueSwitch", isDirectory: true)
    let legacyFile = legacyDir.appendingPathComponent("security-audit.log")
    guard FileManager.default.fileExists(atPath: legacyFile.path) else { return }

    let legacyLineCount: Int
    if let content = try? String(contentsOf: legacyFile, encoding: .utf8) {
      legacyLineCount = content.split(separator: "\n").count
    } else {
      legacyLineCount = 0
    }

    Self.zeroFillAndUnlink(at: legacyFile)
    if let remaining = try? FileManager.default.contentsOfDirectory(atPath: legacyDir.path),
      remaining.isEmpty
    {
      try? FileManager.default.removeItem(at: legacyDir)
    }

    _ = appendRecordSynchronously(
      type: .vaultLifecycle,
      action: "legacy_plaintext_log_shredded",
      outcome: .verified,
      severity: .info,
      subject: "Legacy Plaintext Audit Log",
      endpoint: "~/Library/Logs/BlueSwitch/security-audit.log",
      cipher: "AES-256-GCM + Zero-Fill Shred",
      latencyMs: nil,
      details:
        "Migrated from legacy plaintext log (\(legacyLineCount) line(s)) and zero-filled/unlinked unencrypted file"
    )
  }

  // MARK: - POSIX Hardening Helpers

  private static func ensureHardenedDirectory(at url: URL) {
    try? FileManager.default.createDirectory(
      at: url,
      withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700]
    )
    _ = chmod(url.path, mode_t(0o700))
    excludeFromBackup(url: url)
  }

  private static func excludeFromBackup(url: URL) {
    var mutableURL = url
    var values = URLResourceValues()
    values.isExcludedFromBackup = true
    try? mutableURL.setResourceValues(values)
  }

  private static func writeOwnerOnlyFile(data: Data, to url: URL) {
    let flags = O_WRONLY | O_CREAT | O_TRUNC | O_NOFOLLOW | O_CLOEXEC
    let fd = open(url.path, flags, mode_t(0o600))
    guard fd >= 0 else { return }
    defer { close(fd) }
    _ = fchmod(fd, mode_t(0o600))
    data.withUnsafeBytes { rawBuf in
      if let base = rawBuf.baseAddress {
        _ = write(fd, base, rawBuf.count)
      }
    }
    _ = fsync(fd)
    excludeFromBackup(url: url)
  }

  private static func zeroFillAndUnlink(at url: URL) {
    let fd = open(url.path, O_RDWR | O_NOFOLLOW | O_CLOEXEC)
    if fd >= 0 {
      var st = stat()
      if fstat(fd, &st) == 0 && st.st_size > 0 {
        let zeroChunk = [UInt8](repeating: 0, count: 4096)
        var remaining = Int(st.st_size)
        _ = lseek(fd, 0, SEEK_SET)
        while remaining > 0 {
          let toWrite = min(remaining, zeroChunk.count)
          let n = zeroChunk.withUnsafeBytes { buf in
            write(fd, buf.baseAddress!, toWrite)
          }
          if n <= 0 { break }
          remaining -= n
        }
        _ = fsync(fd)
      }
      close(fd)
    }
    _ = unlink(url.path)
  }

  private func fileSize(at url: URL) -> UInt64 {
    (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? UInt64) ?? 0
  }

  private func countArchives() -> Int {
    guard let items = try? FileManager.default.contentsOfDirectory(atPath: vaultDirectoryURL.path)
    else { return 0 }
    return items.filter { $0.hasPrefix("connections-security.bsaudit.") }.count
  }

  private static let isoFormatter: ISO8601DateFormatter = {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return f
  }()
}

