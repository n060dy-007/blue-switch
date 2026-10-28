import SwiftUI

// MARK: - General

struct GeneralPane: View {
  @ObservedObject private var s = AppSettings.shared
  @ObservedObject private var updates = UpdateChecker.shared
  @State private var loginStatus = LoginItem.statusText

  var body: some View {
    PaneContainer(pane: .general) {
      Section("Startup") {
        SettingToggle(
          title: "Launch at login",
          caption: "Start BlueSwitch automatically when you log in. Status: \(loginStatus)",
          isOn: $s.launchAtLogin)
        if loginStatus.contains("approval") {
          Button("Open Login Items Settings…") { LoginItem.openSystemSettings() }
        }
        SettingToggle(
          title: "Take peripherals when BlueSwitch launches",
          caption: "On launch, ask the target Mac to release peripherals and connect them here.",
          isOn: $s.reclaimOnLaunch)
      }

      Section("Menu Bar") {
        Picker(selection: $s.menuBarIcon) {
          ForEach(MenuBarIconStyle.allCases) { style in
            Label(style.label, systemImage: style.symbolName).tag(style)
          }
        } label: {
          SettingLabel(title: "Menu bar icon")
        }
        Picker(selection: $s.leftClickAction) {
          ForEach(LeftClickAction.allCases) { Text($0.label).tag($0) }
        } label: {
          SettingLabel(title: "Left-click action", caption: "Right-click always opens the menu.")
        }
        SettingToggle(
          title: "Ask before switching",
          caption: "Show a confirmation dialog before peripherals move.",
          isOn: $s.confirmBeforeSwitching)
      }

      Section("Appearance") {
        Picker(selection: $s.appearance) {
          ForEach(AppearanceMode.allCases) { Text($0.label).tag($0) }
        } label: {
          SettingLabel(title: "Theme")
        }
        .pickerStyle(.segmented)
        SettingToggle(
          title: "Show Dock icon",
          caption: "By default BlueSwitch lives only in the menu bar.",
          isOn: $s.showDockIcon)
      }

      Section("Updates & Peer Auto-Update") {
        SettingToggle(
          title: "Automatically update other Macs over the network",
          caption:
            "When this Mac is running a newer version of BlueSwitch than a registered peer Mac, automatically push and install the update over the local network.",
          isOn: $s.autoUpdatePeers)
        SettingToggle(
          title: "Allow incoming updates from peer Macs",
          caption: "Let authenticated peer Macs on your network update BlueSwitch on this Mac.",
          isOn: $s.allowRemoteUpdates)
        SettingToggle(
          title: "Automatically check GitHub for updates",
          caption: "Checks GitHub releases once a day and notifies you of new versions.",
          isOn: $s.autoCheckUpdates)
        HStack {
          SettingLabel(title: "Release feed", caption: "GitHub repository in owner/name form.")
          Spacer()
          TextField("owner/repo", text: $s.updateRepository)
            .textFieldStyle(.roundedBorder)
            .frame(width: 240)
        }
        HStack {
          Text(updates.status).font(.callout).foregroundStyle(.secondary)
          Spacer()
          if updates.hasNewerReleaseOnline && updates.latestAssetURL != nil {
            Button(updates.isInstalling ? "Installing…" : "Download & Install") {
              updates.downloadAndInstallLatestRelease(alsoUpdatePeers: s.autoUpdatePeers)
            }
            .buttonStyle(.borderedProminent)
            .disabled(updates.isInstalling)
          }
          if updates.latestURL != nil {
            Button("View Release") { updates.openLatest() }
          }
          Button("Install from File…") {
            updates.installFromFilePicker(alsoUpdatePeers: s.autoUpdatePeers)
          }
          .disabled(updates.isInstalling)
          Button("Push v\(AppInfo.version) to All Macs") {
            updates.pushUpdateToAllPeers()
          }
          .disabled(NetworkService.shared.peers.isEmpty)
          Button(updates.isChecking ? "Checking…" : "Check Now") {
            updates.check(userInitiated: true)
          }
          .disabled(updates.isChecking || updates.isInstalling)
        }
      }
    }
    .onChange(of: s.launchAtLogin) { _ in
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { loginStatus = LoginItem.statusText }
    }
  }
}

// MARK: - Switching

struct SwitchingPane: View {
  @ObservedObject private var s = AppSettings.shared
  @ObservedObject private var clicker = BluetoothAutoClicker.shared

  var body: some View {
    PaneContainer(pane: .switching) {
      Section {
        Picker(selection: $s.disconnectMethod) {
          ForEach(DisconnectMethod.allCases) { Text($0.label).tag($0) }
        } label: {
          SettingLabel(
            title: "Release method",
            caption:
              "Magic Keyboard & Trackpad only accept a new Mac after being unpaired from the current one.")
        }
        Picker(selection: $s.partialStateBehavior) {
          ForEach(PartialStateBehavior.allCases) { Text($0.label).tag($0) }
        } label: {
          SettingLabel(
            title: "When only some peripherals are connected",
            caption: "What \"Switch Now\" should do if the state is mixed.")
        }
      } header: {
        Text("Behavior")
      }

      Section {
        SettingToggle(
          title: "Auto-click Bluetooth connection requests",
          caption:
            "Automatically clicks \"Connect\" / \"Allow\" on macOS Bluetooth connection prompts so peripherals connect hands-free.",
          isOn: $s.autoAcceptBluetoothRequests)

        Picker(selection: $s.autoAcceptScope) {
          ForEach(AutoAcceptScope.allCases) { Text($0.label).tag($0) }
        } label: {
          SettingLabel(
            title: "Auto-click scope",
            caption: "Which Bluetooth connection prompts should be accepted automatically.")
        }
        .disabled(!s.autoAcceptBluetoothRequests)

        SettingSlider(
          title: "Prompt scan interval",
          caption:
            "Background polling interval (switches to 0.15 s automatically while connecting).",
          value: $s.autoAcceptPollInterval, range: 0.1...1.5, step: 0.05)
          .disabled(!s.autoAcceptBluetoothRequests)

        HStack(spacing: 10) {
          SettingLabel(
            title: "Accessibility permission",
            caption:
              "Required by macOS to read and click the \"Connect\" button in BluetoothUIServer and Notification Center.")
          Spacer()
          StatusPill(
            text: clicker.isAccessibilityTrusted ? "Allowed" : "Permission Required",
            color: clicker.isAccessibilityTrusted ? Theme.green : Theme.amber)
        }

        HStack {
          if let last = clicker.lastAutoClickedSummary {
            Text("Auto-clicked \(clicker.autoClickCount)× · Last: \(last)")
              .font(.caption).foregroundStyle(.secondary)
          } else {
            Text(
              clicker.isAccessibilityTrusted
                ? "Ready — watching for Bluetooth connection prompts."
                : "Allow BlueSwitch in System Settings → Privacy & Security → Accessibility."
            )
            .font(.caption).foregroundStyle(.secondary)
          }
          Spacer()
          if !clicker.isAccessibilityTrusted {
            Button("Request Permission") { clicker.requestPermission() }
            Button("Open Accessibility Settings…") { clicker.openAccessibilitySettings() }
          } else {
            Button("Scan & Click Now") { clicker.scanAndClickNow(forceScope: true) }
          }
          Button {
            clicker.refreshPermission()
          } label: {
            Image(systemName: "arrow.clockwise")
          }
          .buttonStyle(.borderless)
          .help("Re-check Accessibility permission")
        }
      } header: {
        Text("Bluetooth Connection Requests")
      }

      Section("Releasing (this Mac → other Mac)") {
        SettingSlider(
          title: "Disconnect poll interval",
          caption: "How often to check that peripherals have let go.",
          value: $s.disconnectPollInterval, range: 0.1...3.0, step: 0.1)
        SettingStepper(
          title: "Max disconnect checks",
          caption: "Give up after this many checks. Total wait ≈ interval × checks.",
          value: $s.disconnectMaxAttempts, range: 1...40, step: 1, format: { "\($0)" })
        HStack {
          Spacer()
          Text(
            "Maximum wait: \(String(format: "%.1f", s.disconnectPollInterval * Double(s.disconnectMaxAttempts))) s"
          )
          .font(.caption).foregroundStyle(.secondary)
        }
      }

      Section("Connecting (other Mac → this Mac)") {
        SettingSlider(
          title: "Settle delay",
          caption:
            "Pause before starting pairing so peripherals finish disconnecting from the other Mac.",
          value: $s.settleDelay, range: 0...5, step: 0.1)
        SettingSlider(
          title: "Pairing timeout per attempt",
          caption: "How long to wait for pairing & prompt confirmation on each attempt.",
          value: $s.pairAttemptTimeout, range: 2.5...12.0, step: 0.5)
        SettingStepper(
          title: "Connection retries",
          caption: "Extra passes if a peripheral doesn't connect on the first try.",
          value: $s.connectRetryCount, range: 0...10, step: 1, format: { "\($0)" })
        SettingSlider(
          title: "Delay between retries", value: $s.connectRetryDelay, range: 0.2...5, step: 0.1)
        SettingToggle(
          title: "Skip peripherals that appear out of range",
          caption:
            "Uses the RSSI check from upstream Blue Switch. Can wrongly skip devices that are asleep — leave off if switching fails.",
          isOn: $s.requireInRange)
      }

      Section("Automation") {
        SettingToggle(
          title: "Auto-sync peripheral list to target Mac",
          caption: "Whenever you add, remove or rename a peripheral, push the list to the target Mac.",
          isOn: $s.autoSyncPeripherals)
        SettingToggle(
          title: "Send peripherals to target Mac when this Mac sleeps",
          caption: "Handy when you close the lid and keep working on the other Mac.",
          isOn: $s.releaseOnSleep)
        SettingToggle(
          title: "Take peripherals back when this Mac wakes",
          isOn: $s.reclaimOnWake)
      }
    }
    .onAppear { clicker.refreshPermission() }
  }
}

// MARK: - Network

struct NetworkPane: View {
  @ObservedObject private var s = AppSettings.shared
  @ObservedObject private var net = NetworkService.shared
  @State private var draftName = AppSettings.shared.deviceName
  @State private var draftPort = AppSettings.shared.listenPort
  @State private var draftType = AppSettings.shared.serviceType
  @State private var discoveryDraft = AppSettings.shared.discoveryEnabled
  @State private var revealKey = false

  private var dirty: Bool {
    draftName != s.deviceName || draftPort != s.listenPort || draftType != s.serviceType
      || discoveryDraft != s.discoveryEnabled
  }

  var body: some View {
    PaneContainer(pane: .network) {
      Section("Status") {
        statusRow("Advertised as", net.publishedName ?? "—")
        statusRow("Listener", net.listenerStatus + (net.listeningPort.map { " · port \($0)" } ?? ""))
        statusRow("Discovery", net.browserStatus)
      }

      Section {
        HStack {
          SettingLabel(
            title: "Device name", caption: "Name other Macs see. Leave blank to use the computer name.")
          Spacer()
          TextField(Host.current().localizedName ?? "Mac", text: $draftName)
            .textFieldStyle(.roundedBorder).frame(width: 220)
        }
        HStack {
          SettingLabel(
            title: "Listening port",
            caption: "0 = automatic. Set a fixed port if you add this Mac manually on the other side.")
          Spacer()
          TextField("0", value: $draftPort, format: .number.grouping(.never))
            .textFieldStyle(.roundedBorder).frame(width: 90)
        }
        Toggle(isOn: $discoveryDraft) {
          SettingLabel(
            title: "Bonjour discovery",
            caption: "Automatically find other Macs on the local network.")
        }
        .toggleStyle(.switch)
        HStack {
          SettingLabel(
            title: "Bonjour service type",
            caption: "Must match on every Mac. Change only if you know you need to.")
          Spacer()
          TextField("_blueswitch._tcp", text: $draftType)
            .textFieldStyle(.roundedBorder).frame(width: 180)
            .font(.system(.body, design: .monospaced))
        }
        HStack {
          Spacer()
          Button("Revert") {
            draftName = s.deviceName
            draftPort = s.listenPort
            draftType = s.serviceType
            discoveryDraft = s.discoveryEnabled
          }
          .disabled(!dirty)
          Button("Apply & Restart Network") {
            s.deviceName = draftName
            s.listenPort = max(0, min(65535, draftPort))
            s.serviceType = draftType
            s.discoveryEnabled = discoveryDraft
            net.restart()
          }
          .keyboardShortcut(.defaultAction)
          .disabled(!dirty)
        }
      } header: {
        Text("Identity & Discovery")
      }

      Section("Timeouts") {
        SettingSlider(
          title: "Health check timeout",
          caption: "How long to wait for the other Mac to answer before switching.",
          value: $s.healthCheckTimeout, range: 1...30, step: 1)
        SettingSlider(
          title: "Command timeout",
          caption: "How long to wait for release / connect commands to be acknowledged.",
          value: $s.commandTimeout, range: 2...60, step: 1)
      }

      Section("Security") {
        HStack {
          SettingLabel(
            title: "Pairing key",
            caption:
              "Optional shared secret. When set, only Macs with the same key can control this one. Set the same key on both Macs.")
          Spacer()
          Group {
            if revealKey {
              TextField("None", text: $s.pairingKey)
            } else {
              SecureField("None", text: $s.pairingKey)
            }
          }
          .textFieldStyle(.roundedBorder).frame(width: 180)
          Button {
            revealKey.toggle()
          } label: {
            Image(systemName: revealKey ? "eye.slash" : "eye")
          }
          .buttonStyle(.borderless)
        }
      }
    }
  }

  private func statusRow(_ title: String, _ value: String) -> some View {
    HStack {
      Text(title)
      Spacer()
      Text(value).foregroundStyle(.secondary).textSelection(.enabled)
    }
  }
}

// MARK: - Notifications

struct NotificationsPane: View {
  @ObservedObject private var s = AppSettings.shared
  @State private var authStatus = "…"

  var body: some View {
    PaneContainer(pane: .notifications) {
      Section {
        SettingToggle(
          title: "Enable notifications", caption: "System permission: \(authStatus)",
          isOn: $s.notificationsEnabled)
        SettingToggle(title: "Play sound", isOn: $s.notificationSound)
          .disabled(!s.notificationsEnabled)
        HStack {
          Button("Send Test Notification") {
            NotificationService.post(title: "BlueSwitch", body: "Notifications are working 🎉")
          }
          Button("Request Permission") {
            NotificationService.requestAuthorization()
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { refresh() }
          }
        }
        .disabled(!s.notificationsEnabled)
      } header: {
        Text("General")
      }

      Section("Notify me when…") {
        SettingToggle(title: "A switch completes", isOn: $s.notifyOnSwitch)
        SettingToggle(title: "Something goes wrong", isOn: $s.notifyOnError)
        SettingToggle(
          title: "Another Mac takes or sends peripherals",
          caption: "Requests initiated from the other Mac.", isOn: $s.notifyOnRemoteRequest)
        SettingToggle(title: "A new Mac is discovered", isOn: $s.notifyOnPeerFound)
      }
      .disabled(!s.notificationsEnabled)

      Section("\"Notify\" message sent to other Macs") {
        HStack {
          Text("Title")
          Spacer()
          TextField("Title", text: $s.customNotifyTitle)
            .textFieldStyle(.roundedBorder).frame(width: 300)
        }
        HStack {
          SettingLabel(title: "Message", caption: "{device} is replaced with this Mac's name.")
          Spacer()
          TextField("Message", text: $s.customNotifyBody)
            .textFieldStyle(.roundedBorder).frame(width: 300)
        }
        SettingToggle(
          title: "Confirm locally when a notification is sent", isOn: $s.confirmSentNotification)
      }
    }
    .onAppear(perform: refresh)
  }

  private func refresh() { NotificationService.authorizationStatus { authStatus = $0 } }
}

// MARK: - Shortcuts

struct ShortcutsPane: View {
  @ObservedObject private var s = AppSettings.shared

  var body: some View {
    PaneContainer(pane: .shortcuts) {
      Section {
        SettingToggle(
          title: "Enable global shortcuts",
          caption: "Work from any app — no Accessibility permission required.",
          isOn: $s.hotkeysEnabled)
      }
      Section("Shortcuts") {
        row("Switch peripherals", "Toggle between this Mac and the target Mac", $s.hotkeySwitch)
        row("Send to target Mac", "Release here, connect there", $s.hotkeySendToPeer)
        row("Take from target Mac", "Release there, connect here", $s.hotkeyTakeFromPeer)
      }
      .disabled(!s.hotkeysEnabled)
      Section {
        Label(
          "Tip: assign the same shortcut on both Macs. Press it on whichever Mac you're looking at — the keyboard comes along.",
          systemImage: "lightbulb.fill"
        )
        .font(.callout).foregroundStyle(.secondary)
        Label(
          "Click a field, then press a key combination with ⌘, ⌥, ⌃ or ⇧ (or an F-key). Esc cancels, Delete clears.",
          systemImage: "keyboard"
        )
        .font(.callout).foregroundStyle(.secondary)
      }
    }
  }

  private func row(_ title: String, _ caption: String, _ binding: Binding<KeyCombo>) -> some View {
    HStack {
      SettingLabel(title: title, caption: caption)
      Spacer()
      ShortcutRecorder(combo: binding)
    }
  }
}

// MARK: - Advanced

struct AdvancedPane: View {
  @ObservedObject private var s = AppSettings.shared
  @State private var confirmReset = false

  var body: some View {
    PaneContainer(pane: .advanced) {
      Section("Diagnostics") {
        Picker(selection: $s.logLevel) {
          ForEach(LogLevel.allCases) { Text($0.label).tag($0) }
        } label: {
          SettingLabel(title: "Log level", caption: "Debug shows every connection attempt.")
        }
        SettingStepper(
          title: "Log history", caption: "Number of log entries kept in memory.",
          value: $s.maxLogEntries, range: 50...5000, step: 50, format: { "\($0)" })
        SettingSlider(
          title: "Status refresh interval",
          caption: "How often peripheral connection status is re-read.",
          value: $s.statusRefreshInterval, range: 1...30, step: 1)
      }

      Section("Backup") {
        HStack {
          SettingLabel(
            title: "Settings file",
            caption: "Includes every setting, peripherals and Macs. Great for setting up the second Mac.")
          Spacer()
          Button("Export…") { SettingsTransfer.export() }
          Button("Import…") { SettingsTransfer.import() }
        }
      }

      Section("Maintenance") {
        HStack {
          SettingLabel(title: "Restart network services")
          Spacer()
          Button("Restart") { NetworkService.shared.restart() }
        }
        HStack {
          SettingLabel(title: "Refresh Bluetooth devices")
          Spacer()
          Button("Refresh") { BluetoothService.shared.refresh() }
        }
        HStack {
          SettingLabel(
            title: "Reset all settings",
            caption: "Restores defaults. Peripherals and Macs are kept.")
          Spacer()
          Button("Reset…", role: .destructive) { confirmReset = true }
        }
      }
    }
    .confirmationDialog("Reset all settings to defaults?", isPresented: $confirmReset) {
      Button("Reset", role: .destructive) {
        s.resetToDefaults()
        NetworkService.shared.restart()
      }
    }
  }
}
