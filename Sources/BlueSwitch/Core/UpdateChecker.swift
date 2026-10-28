import AppKit
import CryptoKit
import Foundation
import UniformTypeIdentifiers

/// Manages application updates (from GitHub releases or local files) and peer-to-peer
/// over-the-air (LAN) auto-updates across registered Macs.
final class UpdateChecker: ObservableObject {
  static let shared = UpdateChecker()

  @Published private(set) var status = "Up to date (v\(AppInfo.version))"
  @Published private(set) var latestURL: URL?
  @Published private(set) var latestAssetURL: URL?
  @Published private(set) var latestVersionTag: String?
  @Published private(set) var isChecking = false
  @Published private(set) var isInstalling = false
  @Published private(set) var updatingPeerIDs: Set<String> = []
  @Published private(set) var peerUpdateStatus: [String: String] = [:]

  private let lastSeenKey = "updateLastSeenTag"
  private let lastCheckKey = "updateLastCheck"
  private let queue = DispatchQueue(label: "com.blueswitch.updater", qos: .userInitiated)
  private var lastAutoUpdateAttempt: [String: Date] = [:]

  private init() {}

  var hasNewerReleaseOnline: Bool {
    guard let tag = latestVersionTag else { return false }
    return AppInfo.isNewer(version: tag, thanVersion: AppInfo.version)
  }

  /// True if `peer` reported a version/build older than this Mac's running version.
  func isPeerOutdated(_ peer: PeerDevice) -> Bool {
    guard let peerVer = peer.appVersion, !peerVer.isEmpty else { return false }
    return AppInfo.isNewer(
      version: AppInfo.version, build: AppInfo.build,
      thanVersion: peerVer, thanBuild: peer.appBuild)
  }

  // MARK: - GitHub Release Check

  /// Checks at most once per day when automatic checks are enabled.
  func checkOnLaunchIfNeeded() {
    guard AppSettings.shared.autoCheckUpdates else { return }
    let last = UserDefaults.standard.object(forKey: lastCheckKey) as? Date ?? .distantPast
    if Date().timeIntervalSince(last) > 86_400 { check(userInitiated: false) }
  }

  func check(userInitiated: Bool) {
    let repo = AppSettings.shared.updateRepository.trimmingCharacters(in: .whitespaces)
    guard repo.split(separator: "/").count == 2,
      let url = URL(string: "https://api.github.com/repos/\(repo)/releases/latest")
    else {
      status = "Invalid repository (use owner/name)"
      return
    }
    isChecking = true
    status = "Checking GitHub releases…"
    var req = URLRequest(url: url)
    req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
    req.timeoutInterval = 15
    URLSession.shared.dataTask(with: req) { [weak self] data, _, error in
      DispatchQueue.main.async {
        guard let self else { return }
        self.isChecking = false
        UserDefaults.standard.set(Date(), forKey: self.lastCheckKey)
        if let error {
          self.status = "Check failed: \(error.localizedDescription)"
          return
        }
        guard let data,
          let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let tag = json["tag_name"] as? String
        else {
          self.status = "No releases found (local v\(AppInfo.version))"
          return
        }
        let name = (json["name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? tag
        self.latestVersionTag = tag
        self.latestURL = (json["html_url"] as? String).flatMap(URL.init(string:))
        self.latestAssetURL = Self.extractDownloadAssetURL(from: json)

        let isNewer = AppInfo.isNewer(version: tag, thanVersion: AppInfo.version)
        if isNewer {
          self.status = "Update available: \(name) (installed: v\(AppInfo.version))"
        } else {
          self.status = "Up to date (v\(AppInfo.version) · latest release: \(name))"
        }

        let lastSeen = UserDefaults.standard.string(forKey: self.lastSeenKey)
        if isNewer && (lastSeen != tag || userInitiated) {
          NotificationService.post(
            title: "BlueSwitch update available", body: "\(repo) released \(name)")
          UserDefaults.standard.set(tag, forKey: self.lastSeenKey)
        }
        Log.info("Update check: \(name) (newer: \(isNewer))", "Update")
      }
    }.resume()
  }

  private static func extractDownloadAssetURL(from releaseJSON: [String: Any]) -> URL? {
    guard let assets = releaseJSON["assets"] as? [[String: Any]] else { return nil }
    // Prefer .zip or .dmg assets
    for ext in [".zip", ".dmg"] {
      if let match = assets.first(where: {
        (($0["name"] as? String) ?? "").lowercased().hasSuffix(ext)
      }),
        let urlStr = match["browser_download_url"] as? String,
        let url = URL(string: urlStr)
      {
        return url
      }
    }
    return nil
  }

  func openLatest() {
    if let latestURL { NSWorkspace.shared.open(latestURL) }
  }

  // MARK: - Download & Install Release / File

  /// Downloads the latest GitHub release asset (.dmg or .zip), pushes to peers if enabled, and installs locally.
  func downloadAndInstallLatestRelease(alsoUpdatePeers: Bool = true) {
    guard let assetURL = latestAssetURL else {
      openLatest()
      return
    }
    isInstalling = true
    status = "Downloading \(assetURL.lastPathComponent)…"
    URLSession.shared.downloadTask(with: assetURL) { [weak self] tempURL, _, error in
      guard let self else { return }
      if let error {
        DispatchQueue.main.async {
          self.isInstalling = false
          self.status = "Download failed: \(error.localizedDescription)"
        }
        return
      }
      guard let tempURL else {
        DispatchQueue.main.async {
          self.isInstalling = false
          self.status = "Download failed: no file received"
        }
        return
      }
      let savedTemp = FileManager.default.temporaryDirectory
        .appendingPathComponent("blueswitch-dl-\(UUID().uuidString)-\(assetURL.lastPathComponent)")
      try? FileManager.default.moveItem(at: tempURL, to: savedTemp)
      self.installFromLocalPackage(at: savedTemp, alsoUpdatePeers: alsoUpdatePeers)
    }.resume()
  }

  /// Prompts the user to pick a `.app`, `.dmg`, or `.zip` update file and installs it.
  func installFromFilePicker(alsoUpdatePeers: Bool = true) {
    let panel = NSOpenPanel()
    panel.title = "Select BlueSwitch Update (.app, .dmg, or .zip)"
    panel.allowedContentTypes = [.applicationBundle, .diskImage, .zip]
    panel.allowsMultipleSelection = false
    guard panel.runModal() == .OK, let url = panel.url else { return }
    installFromLocalPackage(at: url, alsoUpdatePeers: alsoUpdatePeers)
  }

  private func installFromLocalPackage(at packageURL: URL, alsoUpdatePeers: Bool) {
    DispatchQueue.main.async {
      self.isInstalling = true
      self.status = "Preparing update from \(packageURL.lastPathComponent)…"
    }
    queue.async { [weak self] in
      guard let self else { return }
      do {
        let extractedApp = try self.extractAppBundle(from: packageURL)
        if alsoUpdatePeers && !NetworkService.shared.peers.isEmpty {
          let zipData = try self.zipAppBundle(at: extractedApp)
          let sha = Self.sha256Hex(of: zipData)
          let group = DispatchGroup()
          for peer in NetworkService.shared.peers {
            group.enter()
            self.sendUpdatePayload(zipData: zipData, sha256: sha, to: peer) { _ in
              group.leave()
            }
          }
          _ = group.wait(timeout: .now() + 20)
        }
        DispatchQueue.main.async {
          self.status = "Installing update and restarting…"
        }
        try self.performSelfReplaceAndRelaunch(with: extractedApp)
      } catch {
        DispatchQueue.main.async {
          self.isInstalling = false
          self.status = "Install failed: \(error.localizedDescription)"
          Log.error("Update install failed: \(error.localizedDescription)", "Update")
        }
      }
    }
  }

  // MARK: - Peer-to-Peer Over-the-Air (LAN) Auto-Update

  /// Automatically pushes this Mac's version to `peer` if `autoUpdatePeers` is enabled
  /// and `peer` is running an older version (`>= 1.0.2`).
  func maybeAutoUpdatePeer(_ peer: PeerDevice) {
    guard AppSettings.shared.autoUpdatePeers else { return }
    guard isPeerOutdated(peer) else { return }
    guard AppInfo.supportsNativeOTAUpdate(version: peer.appVersion) else {
      // Peer is on 1.0.0 / 1.0.1 (before OTA handler existed) — mark status so UI offers one-click SSH/DMG upgrade.
      if peerUpdateStatus[peer.id] == nil {
        peerUpdateStatus[peer.id] = "Peer is on v\(peer.appVersion ?? "1.0.1") — click Update to upgrade"
      }
      return
    }
    guard !updatingPeerIDs.contains(peer.id) else { return }
    let lastAttempt = lastAutoUpdateAttempt[peer.id] ?? .distantPast
    guard Date().timeIntervalSince(lastAttempt) > 180 else { return }

    lastAutoUpdateAttempt[peer.id] = Date()
    Log.info(
      "Auto-updating \(peer.name) from v\(peer.appVersion ?? "?") to v\(AppInfo.version)", "Update")
    pushUpdate(to: peer)
  }

  /// Pushes this Mac's running `BlueSwitch.app` bundle to every registered peer Mac.
  func pushUpdateToAllPeers() {
    for peer in NetworkService.shared.peers {
      pushUpdate(to: peer)
    }
  }

  /// Packages this Mac's `BlueSwitch.app` and pushes it over TCP to `peer`.
  func pushUpdate(to peer: PeerDevice) {
    guard !updatingPeerIDs.contains(peer.id) else { return }
    updatingPeerIDs.insert(peer.id)
    peerUpdateStatus[peer.id] = "Packaging v\(AppInfo.version)…"

    queue.async { [weak self] in
      guard let self else { return }
      do {
        let appURL = try self.locateLocalAppBundle()
        let zipData = try self.zipAppBundle(at: appURL)
        let sha = Self.sha256Hex(of: zipData)
        let sizeMB = String(format: "%.1f MB", Double(zipData.count) / 1_048_576.0)

        DispatchQueue.main.async {
          self.peerUpdateStatus[peer.id] = "Sending update (\(sizeMB)) to \(peer.name)…"
        }

        self.sendUpdatePayload(zipData: zipData, sha256: sha, to: peer) { [weak self] result in
          guard let self else { return }
          self.updatingPeerIDs.remove(peer.id)
          switch result {
          case .success:
            self.peerUpdateStatus[peer.id] = "Updated to v\(AppInfo.version) — restarting…"
            Log.info("Pushed BlueSwitch v\(AppInfo.version) to \(peer.name)", "Update")
            NotificationService.post(
              title: "Mac Updated",
              body: "\(peer.name) is updating to BlueSwitch v\(AppInfo.version) and restarting.")
            // Re-ping after the peer finishes restarting so its version badge refreshes.
            for delay in [3.5, 6.5] {
              DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                NetworkService.shared.ping(id: peer.id) { res in
                  if case .success = res {
                    self.peerUpdateStatus[peer.id] = "Up to date (v\(AppInfo.version))"
                  }
                }
              }
            }
          case .failure(let err):
            if !AppInfo.supportsNativeOTAUpdate(version: peer.appVersion) {
              self.peerUpdateStatus[peer.id] =
                "v\(peer.appVersion ?? "1.0.1") needs one-time SSH or DMG install"
            } else {
              self.peerUpdateStatus[peer.id] = "Update failed: \(err.localizedDescription)"
            }
            Log.error("Update push to \(peer.name) failed: \(err.localizedDescription)", "Update")
          }
        }
      } catch {
        DispatchQueue.main.async {
          self.updatingPeerIDs.remove(peer.id)
          self.peerUpdateStatus[peer.id] = "Packaging failed: \(error.localizedDescription)"
          Log.error("Could not package app for peer update: \(error.localizedDescription)", "Update")
        }
      }
    }
  }

  private func sendUpdatePayload(
    zipData: Data, sha256: String, to peer: PeerDevice,
    completion: @escaping (Result<PeerMessage, PeerError>) -> Void
  ) {
    var msg = PeerMessage.make(.installUpdate)
    msg.updateBundleZip = zipData
    msg.updateSHA256 = sha256
    NetworkService.shared.send(msg, to: peer, timeout: 60, completion: completion)
  }

  /// Opens Terminal with a one-command SSH installer for upgrading a peer Mac (useful if the peer
  /// is still on v1.0.0/v1.0.1 before native OTA updates existed).
  func bootstrapPeerViaSSH(_ peer: PeerDevice) {
    let host = peer.host.isEmpty ? "\(peer.name).local" : peer.host
    guard let appURL = try? locateLocalAppBundle() else {
      status = "Could not locate local BlueSwitch.app bundle"
      return
    }
    let scriptPath = appURL.deletingLastPathComponent().deletingLastPathComponent()
      .appendingPathComponent("scripts/update_peers.sh").path
    let cmd: String
    if FileManager.default.fileExists(atPath: scriptPath) {
      cmd = "\"\(scriptPath)\" \"\(host)\""
    } else {
      cmd =
        "ditto -c -k --sequesterRsrc --keepParent \"\(appURL.path)\" /tmp/BlueSwitch-update.zip && scp /tmp/BlueSwitch-update.zip \"\(host):/tmp/BlueSwitch-update.zip\" && ssh \"\(host)\" 'pkill -x BlueSwitch || true; rm -rf /Applications/BlueSwitch.app; ditto -x -k /tmp/BlueSwitch-update.zip /Applications/; xattr -dr com.apple.quarantine /Applications/BlueSwitch.app 2>/dev/null || true; open -a /Applications/BlueSwitch.app'"
    }
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(cmd, forType: .string)
    peerUpdateStatus[peer.id] = "Copied SSH update command to clipboard & opening Terminal"
    Log.info("Prepared SSH bootstrap command for \(peer.name) (\(host))", "Update")

    // Launch Terminal with the command via temporary .command script
    let tmpCmd = FileManager.default.temporaryDirectory.appendingPathComponent(
      "Update-\(peer.name.replacingOccurrences(of: " ", with: "-")).command")
    let content = """
      #!/bin/zsh
      echo "▸ Updating BlueSwitch on \(peer.name) (\(host))…"
      \(cmd)
      echo ""
      echo "✓ Done! You can close this window."
      """
    try? content.write(to: tmpCmd, atomically: true, encoding: .utf8)
    try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tmpCmd.path)
    NSWorkspace.shared.open(tmpCmd)
  }

  // MARK: - Incoming Update Installation (Receiver Side)

  func handleIncomingUpdate(_ msg: PeerMessage, reply: @escaping (PeerMessage) -> Void) {
    guard AppSettings.shared.allowRemoteUpdates else {
      var err = PeerMessage.make(.error)
      err.body = "Remote updates are disabled on \(AppSettings.shared.effectiveDeviceName)"
      reply(err)
      return
    }
    guard let zipData = msg.updateBundleZip, !zipData.isEmpty else {
      var err = PeerMessage.make(.error)
      err.body = "Missing update bundle payload"
      reply(err)
      return
    }
    if let expectedSHA = msg.updateSHA256, !expectedSHA.isEmpty {
      let actualSHA = Self.sha256Hex(of: zipData)
      guard actualSHA.caseInsensitiveCompare(expectedSHA) == .orderedSame else {
        var err = PeerMessage.make(.error)
        err.body = "Update SHA-256 checksum mismatch"
        reply(err)
        return
      }
    }

    let incomingVer = msg.appVersion ?? "new"
    Log.info(
      "Receiving BlueSwitch v\(incomingVer) update (\(zipData.count) bytes) from \(msg.sender)",
      "Update")

    queue.async { [weak self] in
      guard let self else { return }
      do {
        let stagingDir = FileManager.default.temporaryDirectory
          .appendingPathComponent("blueswitch-ota-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: stagingDir, withIntermediateDirectories: true)
        let zipURL = stagingDir.appendingPathComponent("BlueSwitch.zip")
        try zipData.write(to: zipURL, options: .atomic)

        let extractedApp = try self.extractAppBundle(from: zipURL)

        DispatchQueue.main.async {
          var ok = PeerMessage.make(.ok)
          ok.body = "Installing v\(incomingVer) and restarting"
          reply(ok)
          NotificationService.post(
            title: "Updating BlueSwitch",
            body: "Installing v\(incomingVer) received from \(msg.sender) and restarting…")
        }

        try self.performSelfReplaceAndRelaunch(with: extractedApp)
      } catch {
        Log.error("Failed to install incoming update: \(error.localizedDescription)", "Update")
        DispatchQueue.main.async {
          var err = PeerMessage.make(.error)
          err.body = error.localizedDescription
          reply(err)
        }
      }
    }
  }

  // MARK: - Bundle Packaging & Self-Replacement Helpers

  enum UpdateError: LocalizedError {
    case appBundleNotFound
    case packagingFailed(String)
    case invalidBundle(String)

    var errorDescription: String? {
      switch self {
      case .appBundleNotFound:
        return "Could not find BlueSwitch.app bundle (build or install in /Applications first)"
      case .packagingFailed(let msg):
        return msg
      case .invalidBundle(let msg):
        return msg
      }
    }
  }

  private func locateLocalAppBundle() throws -> URL {
    let mainURL = Bundle.main.bundleURL
    if mainURL.pathExtension == "app"
      && FileManager.default.fileExists(
        atPath: mainURL.appendingPathComponent("Contents/MacOS/BlueSwitch").path)
    {
      return mainURL
    }
    let appsURL = URL(fileURLWithPath: "/Applications/BlueSwitch.app")
    if FileManager.default.fileExists(
      atPath: appsURL.appendingPathComponent("Contents/MacOS/BlueSwitch").path)
    {
      return appsURL
    }
    let cwdDist = URL(
      fileURLWithPath: FileManager.default.currentDirectoryPath
    ).appendingPathComponent("dist/BlueSwitch.app")
    if FileManager.default.fileExists(
      atPath: cwdDist.appendingPathComponent("Contents/MacOS/BlueSwitch").path)
    {
      return cwdDist
    }
    throw UpdateError.appBundleNotFound
  }

  private func zipAppBundle(at appURL: URL) throws -> Data {
    let zipURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("blueswitch-pkg-\(UUID().uuidString).zip")
    defer { try? FileManager.default.removeItem(at: zipURL) }

    let proc = Process()
    proc.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
    proc.arguments = ["-c", "-k", "--sequesterRsrc", "--keepParent", appURL.path, zipURL.path]
    try proc.run()
    proc.waitUntilExit()
    guard proc.terminationStatus == 0 else {
      throw UpdateError.packagingFailed("ditto failed with exit code \(proc.terminationStatus)")
    }
    return try Data(contentsOf: zipURL)
  }

  private func extractAppBundle(from sourceURL: URL) throws -> URL {
    let ext = sourceURL.pathExtension.lowercased()
    let workDir = FileManager.default.temporaryDirectory
      .appendingPathComponent("blueswitch-extract-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)

    if ext == "app" {
      let dest = workDir.appendingPathComponent("BlueSwitch.app")
      try FileManager.default.copyItem(at: sourceURL, to: dest)
      try validateAppBundle(at: dest)
      return dest
    } else if ext == "zip" {
      let proc = Process()
      proc.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
      proc.arguments = ["-x", "-k", sourceURL.path, workDir.path]
      try proc.run()
      proc.waitUntilExit()
      guard proc.terminationStatus == 0 else {
        throw UpdateError.packagingFailed("Could not unzip update archive")
      }
      let app = try findAppBundle(in: workDir)
      try validateAppBundle(at: app)
      return app
    } else if ext == "dmg" {
      let mountPoint = workDir.appendingPathComponent("mnt", isDirectory: true)
      try FileManager.default.createDirectory(at: mountPoint, withIntermediateDirectories: true)
      let attach = Process()
      attach.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
      attach.arguments = [
        "attach", sourceURL.path, "-mountpoint", mountPoint.path, "-nobrowse", "-readonly", "-quiet",
      ]
      try attach.run()
      attach.waitUntilExit()
      guard attach.terminationStatus == 0 else {
        throw UpdateError.packagingFailed("Could not mount DMG")
      }
      defer {
        let detach = Process()
        detach.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        detach.arguments = ["detach", mountPoint.path, "-force", "-quiet"]
        try? detach.run()
        detach.waitUntilExit()
      }
      let mountedApp = try findAppBundle(in: mountPoint)
      let copiedApp = workDir.appendingPathComponent("BlueSwitch.app")
      try FileManager.default.copyItem(at: mountedApp, to: copiedApp)
      try validateAppBundle(at: copiedApp)
      return copiedApp
    } else {
      throw UpdateError.invalidBundle("Unsupported file type: .\(ext)")
    }
  }

  private func findAppBundle(in directory: URL) throws -> URL {
    let direct = directory.appendingPathComponent("BlueSwitch.app")
    if FileManager.default.fileExists(atPath: direct.path) { return direct }
    if let enumerator = FileManager.default.enumerator(
      at: directory, includingPropertiesForKeys: nil)
    {
      for case let url as URL in enumerator where url.pathExtension == "app" {
        return url
      }
    }
    throw UpdateError.invalidBundle("No .app bundle found inside update archive")
  }

  private func validateAppBundle(at appURL: URL) throws {
    let exec = appURL.appendingPathComponent("Contents/MacOS/BlueSwitch")
    let plist = appURL.appendingPathComponent("Contents/Info.plist")
    guard FileManager.default.fileExists(atPath: exec.path),
      FileManager.default.fileExists(atPath: plist.path)
    else {
      throw UpdateError.invalidBundle("Bundle is missing executable or Info.plist")
    }
    // Strip quarantine so Gatekeeper doesn't block relaunch.
    let xattr = Process()
    xattr.executableURL = URL(fileURLWithPath: "/usr/bin/xattr")
    xattr.arguments = ["-dr", "com.apple.quarantine", appURL.path]
    try? xattr.run()
    xattr.waitUntilExit()
  }

  /// Replaces the installed `BlueSwitch.app` and relaunches via a detached helper script.
  private func performSelfReplaceAndRelaunch(with stagedAppURL: URL) throws {
    let currentBundle = Bundle.main.bundleURL
    let targetPath: String
    if currentBundle.pathExtension == "app" {
      targetPath = currentBundle.path
    } else {
      targetPath = "/Applications/BlueSwitch.app"
    }

    let pid = ProcessInfo.processInfo.processIdentifier
    let script = """
      sleep 0.8
      for i in 1 2 3 4 5; do
        if ! kill -0 \(pid) 2>/dev/null; then break; fi
        sleep 0.3
      done
      rm -rf "\(targetPath)"
      cp -R "\(stagedAppURL.path)" "\(targetPath)"
      if [ "\(targetPath)" != "/Applications/BlueSwitch.app" ] && [ -d "/Applications/BlueSwitch.app" ]; then
        rm -rf "/Applications/BlueSwitch.app"
        cp -R "\(stagedAppURL.path)" "/Applications/BlueSwitch.app"
      fi
      xattr -dr com.apple.quarantine "\(targetPath)" 2>/dev/null || true
      touch "\(targetPath)"
      /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "\(targetPath)" 2>/dev/null || true
      open -n "\(targetPath)"
      rm -rf "\(stagedAppURL.deletingLastPathComponent().path)" 2>/dev/null || true
      """

    let proc = Process()
    proc.executableURL = URL(fileURLWithPath: "/bin/zsh")
    proc.arguments = ["-c", script]
    proc.standardOutput = FileHandle.nullDevice
    proc.standardError = FileHandle.nullDevice
    try proc.run()

    DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
      NSApp.terminate(nil)
    }
  }

  private static func sha256Hex(of data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }
}
