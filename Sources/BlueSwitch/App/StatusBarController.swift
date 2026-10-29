import AppKit
import Combine
import SwiftUI

/// Menu bar item: left-click action is configurable, right-click always shows the menu.
final class StatusBarController: NSObject, NSMenuDelegate {
  private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
  private let popover = NSPopover()
  private let openSettings: (SettingsPane?) -> Void
  private var cancellables = Set<AnyCancellable>()
  private let settings = AppSettings.shared
  private let bt = BluetoothService.shared
  private let net = NetworkService.shared
  private let coordinator = SwitchCoordinator.shared

  init(openSettings: @escaping (SettingsPane?) -> Void) {
    self.openSettings = openSettings
    super.init()

    if let button = statusItem.button {
      button.target = self
      button.action = #selector(handleClick(_:))
      button.sendAction(on: [.leftMouseUp, .rightMouseUp])
      button.toolTip = "BlueSwitch"
    }

    popover.behavior = .transient
    popover.animates = true
    popover.contentSize = NSSize(width: 360, height: 520)
    popover.contentViewController = NSHostingController(
      rootView: DashboardView(openSettings: { [weak self] pane in
        self?.popover.performClose(nil)
        self?.openSettings(pane)
      }))

    Publishers.CombineLatest3(
      settings.$menuBarIcon, coordinator.$phase, bt.$refreshTick
    )
    .receive(on: DispatchQueue.main)
    .sink { [weak self] icon, phase, _ in self?.updateIcon(icon, phase) }
    .store(in: &cancellables)
  }

  private func updateIcon(_ style: MenuBarIconStyle, _ phase: SwitchCoordinator.Phase) {
    guard let button = statusItem.button else { return }
    let symbol: String
    switch phase {
    case .working: symbol = "arrow.triangle.2.circlepath"
    case .failure: symbol = "exclamationmark.triangle.fill"
    default: symbol = style.symbolName
    }
    let config = NSImage.SymbolConfiguration(pointSize: 15, weight: .semibold)
    let image = NSImage(systemSymbolName: symbol, accessibilityDescription: "BlueSwitch")?
      .withSymbolConfiguration(config)
    image?.isTemplate = true
    button.image = image
    // Dim the icon when peripherals are not on this Mac.
    button.appearsDisabled = bt.connectionState == .allDisconnected && !phase.isWorking
    button.toolTip = "BlueSwitch — \(bt.connectionState.label)"
  }

  // MARK: - Clicks

  @objc private func handleClick(_ sender: NSStatusBarButton) {
    guard let event = NSApp.currentEvent else { return }
    if event.type == .rightMouseUp || event.modifierFlags.contains(.control) {
      showMenu()
      return
    }
    switch settings.leftClickAction {
    case .switchDevices: coordinator.switchDevices()
    case .showDashboard: togglePopover()
    case .showMenu: showMenu()
    }
  }

  func togglePopover() {
    guard let button = statusItem.button else { return }
    if popover.isShown {
      popover.performClose(nil)
    } else {
      bt.refresh()
      net.checkAllPeers()
      NSApp.activate(ignoringOtherApps: true)
      popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
    }
  }

  private func showMenu() {
    let menu = buildMenu()
    statusItem.menu = menu
    statusItem.button?.performClick(nil)
    statusItem.menu = nil
  }

  private func buildMenu() -> NSMenu {
    let menu = NSMenu()
    let demo = DemoMode.shared

    let headerTitle =
      settings.demoModeEnabled
      ? "\(demo.localMacDisplayName) · DEMO MODE"
      : settings.effectiveDeviceName
    let header = NSMenuItem(title: headerTitle, action: nil, keyEquivalent: "")
    header.isEnabled = false
    menu.addItem(header)
    menu.addItem(.separator())

    menu.addItem(item("Switch Now", #selector(doSwitch), symbol: "arrow.left.arrow.right"))
    menu.addItem(item("Send to Peer", #selector(doSend), symbol: "arrow.up.right.circle"))
    menu.addItem(item("Take from Peer", #selector(doTake), symbol: "arrow.down.left.circle"))
    menu.addItem(.separator())

    let macsHeader = NSMenuItem(title: "Target Mac", action: nil, keyEquivalent: "")
    macsHeader.isEnabled = false
    menu.addItem(macsHeader)
    let peersList = demo.effectivePeers
    if peersList.isEmpty {
      let none = NSMenuItem(title: "No Macs registered", action: nil, keyEquivalent: "")
      none.isEnabled = false
      menu.addItem(none)
    }
    for peer in peersList {
      let mi = NSMenuItem(
        title: demo.peerDisplayName(peer), action: #selector(selectPeer(_:)), keyEquivalent: "")
      mi.target = self
      mi.representedObject = peer.id
      mi.state = demo.effectiveActivePeer?.id == peer.id ? .on : .off
      let online = demo.reachability(for: peer) == .online
      mi.image = NSImage(
        systemSymbolName: online ? "desktopcomputer" : "desktopcomputer.trianglebadge.exclamationmark",
        accessibilityDescription: nil)
      menu.addItem(mi)
    }
    menu.addItem(.separator())

    let periHeader = NSMenuItem(title: "Peripherals", action: nil, keyEquivalent: "")
    periHeader.isEnabled = false
    menu.addItem(periHeader)
    let periList = demo.effectivePeripherals
    if periList.isEmpty {
      let none = NSMenuItem(title: "No peripherals registered", action: nil, keyEquivalent: "")
      none.isEnabled = false
      menu.addItem(none)
    }
    for p in periList {
      let connected = demo.isPeripheralConnected(p)
      let mi = NSMenuItem(
        title: "\(demo.peripheralDisplayName(p)) — \(connected ? "Connected" : "Not connected")",
        action: #selector(togglePeripheral(_:)), keyEquivalent: "")
      mi.target = self
      mi.representedObject = p.id
      mi.state = connected ? .on : .off
      mi.image = NSImage(systemSymbolName: p.symbolName, accessibilityDescription: nil)
      if !p.isEnabled { mi.title += " (excluded)" }
      menu.addItem(mi)
    }
    menu.addItem(.separator())

    let audio = AudioService.shared
    let audioHeader = NSMenuItem(title: "Audio Controls", action: nil, keyEquivalent: "")
    audioHeader.isEnabled = false
    menu.addItem(audioHeader)

    let micItem = item(
      audio.isMicMuted ? "Unmute Microphone (Muted)" : "Mute Microphone (\(audio.micVolume)%)",
      #selector(toggleMicMuteAction),
      symbol: audio.isMicMuted ? "mic.slash.fill" : "mic.fill")
    micItem.state = audio.isMicMuted ? .on : .off
    menu.addItem(micItem)

    let spkItem = item(
      audio.isSpeakersMuted
        ? "Unmute Speakers (Muted)" : "Mute Speakers (\(audio.speakersVolume)%)",
      #selector(toggleSpeakersMuteAction),
      symbol: audio.isSpeakersMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
    spkItem.state = audio.isSpeakersMuted ? .on : .off
    menu.addItem(spkItem)
    menu.addItem(.separator())

    let demoItem = item(
      settings.demoModeEnabled
        ? "Disable Demo Mode (Personal Info Hidden)"
        : "Enable Demo Mode (For Screen Recording)",
      #selector(toggleDemoModeAction),
      symbol: settings.demoModeEnabled ? "video.fill" : "video.badge.checkmark")
    demoItem.state = settings.demoModeEnabled ? .on : .off
    menu.addItem(demoItem)

    let autoPlayItem = item(
      DemoMode.shared.isAutoPlaying ? "Stop Demo Auto-Play Loop" : "Start Demo Auto-Play Loop",
      #selector(toggleDemoAutoPlayAction),
      symbol: DemoMode.shared.isAutoPlaying ? "stop.circle.fill" : "play.circle")
    menu.addItem(autoPlayItem)

    menu.addItem(
      item("Demo Mode Options…", #selector(openDemoSettingsAction), symbol: "slider.horizontal.3"))
    menu.addItem(.separator())

    menu.addItem(item("Open Dashboard", #selector(openDashboard), symbol: "rectangle.grid.2x2"))
    let s = item("Settings…", #selector(openSettingsAction), symbol: "gearshape")
    s.keyEquivalent = ","
    menu.addItem(s)
    if UpdateChecker.shared.hasNewerReleaseOnline, let tag = UpdateChecker.shared.latestVersionTag {
      menu.addItem(
        item(
          "Install Update (\(tag)) from GitHub", #selector(installGitHubUpdate),
          symbol: "arrow.down.circle.fill"))
    } else {
      menu.addItem(
        item(
          "Check for GitHub Updates…", #selector(checkGitHubUpdates),
          symbol: "arrow.triangle.2.circlepath.circle"))
    }
    menu.addItem(.separator())
    let q = NSMenuItem(
      title: "Quit BlueSwitch", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
    menu.addItem(q)
    return menu
  }

  private func item(_ title: String, _ action: Selector, symbol: String) -> NSMenuItem {
    let mi = NSMenuItem(title: title, action: action, keyEquivalent: "")
    mi.target = self
    mi.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
    return mi
  }

  @objc private func doSwitch() { coordinator.switchDevices() }
  @objc private func doSend() { coordinator.sendToPeer() }
  @objc private func doTake() { coordinator.takeFromPeer() }
  @objc private func toggleMicMuteAction() { AudioService.shared.toggleMicMute() }
  @objc private func toggleSpeakersMuteAction() { AudioService.shared.toggleSpeakersMute() }
  @objc private func toggleDemoModeAction() { DemoMode.shared.toggle() }
  @objc private func toggleDemoAutoPlayAction() { DemoMode.shared.toggleAutoPlay() }
  @objc private func openDemoSettingsAction() { openSettings(.demo) }
  @objc private func openDashboard() {
    DispatchQueue.main.async { self.togglePopover() }
  }
  @objc private func openSettingsAction() { openSettings(nil) }
  @objc private func checkGitHubUpdates() {
    UpdateChecker.shared.check(userInitiated: true)
    openSettings(.general)
  }
  @objc private func installGitHubUpdate() {
    UpdateChecker.shared.checkAndInstallLatestRelease(
      alsoUpdatePeers: AppSettings.shared.autoUpdatePeers)
  }

  @objc private func selectPeer(_ sender: NSMenuItem) {
    guard let id = sender.representedObject as? String,
      let peer = net.peers.first(where: { $0.id == id })
    else { return }
    net.setActive(peer)
  }

  @objc private func togglePeripheral(_ sender: NSMenuItem) {
    guard let id = sender.representedObject as? String,
      let p = bt.peripherals.first(where: { $0.id == id })
    else { return }
    if bt.isConnected(p) { bt.release(p) } else { bt.connect(p) }
  }
}
