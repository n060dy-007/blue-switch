import AppKit
import Combine
import SwiftUI

@main
enum BlueSwitchMain {
  static func main() {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    withExtendedLifetime(delegate) { app.run() }
  }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
  private var statusBar: StatusBarController?
  private var settingsWindow: NSWindow?
  private var cancellables = Set<AnyCancellable>()
  private let settings = AppSettings.shared

  func applicationDidFinishLaunching(_ notification: Notification) {
    Log.info("BlueSwitch \(AppInfo.version) starting", "App")
    applyActivationPolicy()
    applyAppearance()
    buildMainMenu()

    NotificationService.requestAuthorization()
    BluetoothService.shared.requestAccess()
    BluetoothService.shared.startMonitoring()
    BluetoothAutoClicker.shared.start()
    AudioService.shared.start()
    SecurityMonitor.shared.start()
    NetworkService.shared.start()
    SwitchCoordinator.shared.start()

    HotKeyManager.shared.handler = { action in
      switch action {
      case .switchDevices: SwitchCoordinator.shared.switchDevices()
      case .sendToPeer: SwitchCoordinator.shared.sendToPeer()
      case .takeFromPeer: SwitchCoordinator.shared.takeFromPeer()
      case .muteMic: AudioService.shared.toggleMicMute()
      case .muteSpeakers: AudioService.shared.toggleSpeakersMute()
      }
    }
    HotKeyManager.shared.reload()

    statusBar = StatusBarController(openSettings: { [weak self] pane in self?.openSettings(pane) })

    observeSettings()
    UpdateChecker.shared.checkOnLaunchIfNeeded()

    // Keep the stored toggle in sync with the real login-item state.
    if Bundle.main.bundleIdentifier != nil && settings.launchAtLogin != LoginItem.isEnabled {
      settings.launchAtLogin = LoginItem.isEnabled
    }

    if NetworkService.shared.peers.isEmpty && BluetoothService.shared.peripherals.isEmpty {
      // First run: open settings so the user can set things up.
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self.openSettings(.peripherals) }
    }
  }

  func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
    openSettings(nil)
    return true
  }

  // MARK: - Settings reactions

  private func observeSettings() {
    settings.$showDockIcon.dropFirst().receive(on: DispatchQueue.main)
      .sink { [weak self] _ in self?.applyActivationPolicy() }.store(in: &cancellables)
    settings.$appearance.dropFirst().receive(on: DispatchQueue.main)
      .sink { [weak self] _ in self?.applyAppearance() }.store(in: &cancellables)
    settings.$launchAtLogin.dropFirst().removeDuplicates()
      .sink { enabled in
        guard Bundle.main.bundleIdentifier != nil else { return }
        if enabled != LoginItem.isEnabled { LoginItem.set(enabled) }
      }.store(in: &cancellables)
    settings.$statusRefreshInterval.dropFirst().debounce(
      for: .milliseconds(500), scheduler: DispatchQueue.main
    )
    .sink { _ in BluetoothService.shared.startMonitoring() }.store(in: &cancellables)

    Publishers.Merge(
      settings.$autoAcceptBluetoothRequests.map { _ in () },
      settings.$autoAcceptPollInterval.map { _ in () }
    )
    .dropFirst(2)
    .debounce(for: .milliseconds(300), scheduler: DispatchQueue.main)
    .sink { BluetoothAutoClicker.shared.restartTimer() }
    .store(in: &cancellables)

    Publishers.Merge(
      settings.$inputMonitoringGuardEnabled.map { _ in () },
      settings.$inputGuardPollInterval.map { _ in () }
    )
    .dropFirst(2)
    .debounce(for: .milliseconds(300), scheduler: DispatchQueue.main)
    .sink { SecurityMonitor.shared.restartTimer() }
    .store(in: &cancellables)

    Publishers.MergeMany(
      settings.$hotkeysEnabled.map { _ in () }.eraseToAnyPublisher(),
      settings.$hotkeySwitch.map { _ in () }.eraseToAnyPublisher(),
      settings.$hotkeySendToPeer.map { _ in () }.eraseToAnyPublisher(),
      settings.$hotkeyTakeFromPeer.map { _ in () }.eraseToAnyPublisher(),
      settings.$hotkeyMuteMic.map { _ in () }.eraseToAnyPublisher(),
      settings.$hotkeyMuteSpeakers.map { _ in () }.eraseToAnyPublisher()
    )
    .dropFirst(6)
    .receive(on: DispatchQueue.main)
    .sink { HotKeyManager.shared.reload() }
    .store(in: &cancellables)
  }

  private func applyActivationPolicy() {
    let windowOpen = settingsWindow?.isVisible ?? false
    NSApp.setActivationPolicy(settings.showDockIcon || windowOpen ? .regular : .accessory)
  }

  private func applyAppearance() {
    NSApp.appearance = settings.appearance.nsAppearance
  }

  // MARK: - Settings window

  func openSettings(_ pane: SettingsPane?) {
    if let pane { SettingsNavigation.shared.selection = pane }
    if settingsWindow == nil {
      let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 920, height: 640),
        styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
        backing: .buffered, defer: false)
      window.title = "BlueSwitch Settings"
      window.titlebarAppearsTransparent = true
      window.toolbarStyle = .unified
      window.isReleasedWhenClosed = false
      window.minSize = NSSize(width: 820, height: 560)
      window.contentView = NSHostingView(rootView: SettingsRootView())
      window.center()
      window.setFrameAutosaveName("BlueSwitchSettings")
      NotificationCenter.default.addObserver(
        forName: NSWindow.willCloseNotification, object: window, queue: .main
      ) { [weak self] _ in
        DispatchQueue.main.async { self?.applyActivationPolicy() }
      }
      settingsWindow = window
    }
    NSApp.setActivationPolicy(.regular)
    NSApp.activate(ignoringOtherApps: true)
    settingsWindow?.makeKeyAndOrderFront(nil)
  }

  private func buildMainMenu() {
    let main = NSMenu()
    let appItem = NSMenuItem()
    main.addItem(appItem)
    let appMenu = NSMenu()
    appMenu.addItem(
      withTitle: "About BlueSwitch", action: #selector(showAbout), keyEquivalent: ""
    ).target = self
    appMenu.addItem(.separator())
    appMenu.addItem(withTitle: "Settings…", action: #selector(showSettings), keyEquivalent: ",")
      .target = self
    appMenu.addItem(.separator())
    appMenu.addItem(
      withTitle: "Hide BlueSwitch", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
    appMenu.addItem(
      withTitle: "Quit BlueSwitch", action: #selector(NSApplication.terminate(_:)),
      keyEquivalent: "q")
    appItem.submenu = appMenu

    let editItem = NSMenuItem()
    main.addItem(editItem)
    let edit = NSMenu(title: "Edit")
    edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
    edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
    edit.addItem(.separator())
    edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
    edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
    edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
    edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
    editItem.submenu = edit

    let windowItem = NSMenuItem()
    main.addItem(windowItem)
    let win = NSMenu(title: "Window")
    win.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
    win.addItem(
      withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
    windowItem.submenu = win

    NSApp.mainMenu = main
  }

  @objc private func showSettings() { openSettings(nil) }
  @objc private func showAbout() { openSettings(.about) }
}
