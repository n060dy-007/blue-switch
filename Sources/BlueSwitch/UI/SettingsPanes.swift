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

      Section("Demo & Screen Recording Mode") {
        SettingToggle(
          title: "Demo Mode (Hide personal information for public recording)",
          caption:
            "Replaces computer names, peer Mac names, IP addresses, Bluetooth MAC addresses, personal device names, file paths, and log details with clean studio placeholders.",
          isOn: $s.demoModeEnabled)
        SettingToggle(
          title: "Simulate live switching & populate sample Macs/peripherals",
          caption:
            "Shows sample Macs (MacBook Pro 16\", Studio Mac mini) and peripherals (Magic Keyboard, Trackpad, Mouse) and animates switching on screen without disconnecting your live keyboard or mouse during a recording.",
          isOn: $s.demoSimulateSwitching
        )
        .disabled(!s.demoModeEnabled)
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
          caption: "Checks GitHub releases on launch and every 4 hours.",
          isOn: $s.autoCheckUpdates)
        SettingToggle(
          title: "Automatically install new GitHub releases",
          caption:
            "When a newer release is published on GitHub, automatically download, install, and restart BlueSwitch.",
          isOn: $s.autoInstallUpdates)
        HStack {
          SettingLabel(title: "Release feed", caption: "GitHub repository in owner/name form.")
          Spacer()
          if s.demoModeEnabled {
            TextField("owner/repo", text: .constant("demo-org/blue-switch"))
              .textFieldStyle(.roundedBorder)
              .frame(width: 240)
              .disabled(true)
          } else {
            TextField("owner/repo", text: $s.updateRepository)
              .textFieldStyle(.roundedBorder)
              .frame(width: 240)
          }
        }
        VStack(alignment: .leading, spacing: 8) {
          Text(DemoMode.shared.sanitizeLog(updates.status)).font(.callout).foregroundStyle(.secondary)
          HStack(spacing: 8) {
            if updates.hasNewerReleaseOnline {
              Button(updates.isInstalling ? "Installing…" : "Download & Install from GitHub") {
                updates.checkAndInstallLatestRelease(alsoUpdatePeers: s.autoUpdatePeers)
              }
              .buttonStyle(.borderedProminent)
              .disabled(updates.isInstalling || updates.isChecking)
            } else {
              Button(updates.isInstalling ? "Installing…" : "Install Latest GitHub Release") {
                updates.checkAndInstallLatestRelease(alsoUpdatePeers: s.autoUpdatePeers)
              }
              .disabled(updates.isInstalling || updates.isChecking)
            }
            Button(updates.isChecking ? "Checking…" : "Check Now") {
              updates.check(userInitiated: true)
            }
            .disabled(updates.isChecking || updates.isInstalling)
            if updates.latestURL != nil {
              Button("View on GitHub") { updates.openLatest() }
            }
            Button("Install from File…") {
              updates.installFromFilePicker(alsoUpdatePeers: s.autoUpdatePeers)
            }
            .disabled(updates.isInstalling)
            Button("Push v\(AppInfo.version) to All Macs") {
              updates.pushUpdateToAllPeers()
            }
            .disabled(NetworkService.shared.peers.isEmpty)
          }
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
  @ObservedObject private var audio = AudioService.shared

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

      Section("Audio Controls & Switch Automation (Microphone & Speakers)") {
        HStack(spacing: 12) {
          SettingLabel(
            title:
              "Microphone (\(DemoMode.shared.audioDeviceDisplayName(audio.inputDeviceName, isInput: true)))",
            caption: audio.isMicMuted ? "Currently MUTED" : "Input volume: \(audio.micVolume)%")
          Spacer()
          Slider(
            value: Binding(
              get: { Double(audio.micVolume) },
              set: { audio.setMicVolume(Int($0)) }
            ),
            in: 0...100
          )
          .frame(width: 120)
          Button(audio.isMicMuted ? "Unmute Mic" : "Mute Mic") {
            audio.toggleMicMute()
          }
          .buttonStyle(.borderedProminent)
          .tint(audio.isMicMuted ? Theme.red : Theme.indigo)
        }
        HStack(spacing: 12) {
          SettingLabel(
            title:
              "Speakers (\(DemoMode.shared.audioDeviceDisplayName(audio.outputDeviceName, isInput: false)))",
            caption: audio.isSpeakersMuted
              ? "Currently MUTED" : "Output volume: \(audio.speakersVolume)%")
          Spacer()
          Slider(
            value: Binding(
              get: { Double(audio.speakersVolume) },
              set: { audio.setSpeakersVolume(Int($0)) }
            ),
            in: 0...100
          )
          .frame(width: 120)
          Button(audio.isSpeakersMuted ? "Unmute Speakers" : "Mute Speakers") {
            audio.toggleSpeakersMute()
          }
          .buttonStyle(.borderedProminent)
          .tint(audio.isSpeakersMuted ? Theme.red : Theme.blue)
        }
        SettingToggle(
          title: "Automatically mute Microphone when peripherals leave this Mac",
          caption: "Mutes only the microphone on this Mac when you switch peripherals to another Mac.",
          isOn: $s.muteMicOnRelease)
        SettingToggle(
          title: "Automatically unmute Microphone when peripherals connect here",
          caption: "Restores your microphone volume when peripherals return to this Mac.",
          isOn: $s.unmuteMicOnConnect)
        SettingToggle(
          title: "Automatically mute Speakers when peripherals leave this Mac",
          caption: "Mutes only the speakers on this Mac when you switch peripherals to another Mac.",
          isOn: $s.muteSpeakersOnRelease)
        SettingToggle(
          title: "Automatically unmute Speakers when peripherals connect here",
          caption: "Unmutes your speakers when peripherals return to this Mac.",
          isOn: $s.unmuteSpeakersOnConnect)
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
    .onAppear {
      clicker.refreshPermission()
      audio.refresh()
    }
  }
}

// MARK: - Network

struct NetworkPane: View {
  @ObservedObject private var s = AppSettings.shared
  @ObservedObject private var net = NetworkService.shared
  @ObservedObject private var sec = SecurityMonitor.shared
  @ObservedObject private var demo = DemoMode.shared
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
      Section("Status & Security Audit") {
        statusRow("Advertised as", demo.publishedServiceDisplayName)
        statusRow("Listener", net.listenerStatus + demo.listeningPortDisplay)
        statusRow("Discovery", net.browserStatus)
        statusRow(
          "Transport encryption",
          s.encryptNetworkTraffic ? "AES-256-GCM + HKDF-SHA256 + Replay Guard" : "Disabled (Legacy)")
        statusRow(
          "Keystroke & Mouse Guard",
          s.inputMonitoringGuardEnabled
            ? "Active (\(sec.activeTapCount) system event tap(s) inspected)"
            : "Paused")
        HStack {
          Text("Persistent security log")
          Spacer()
          Text(demo.sanitizePath(sec.auditLogFilePath))
            .font(.caption).foregroundStyle(.secondary).lineLimit(1)
          Button("Reveal in Finder") {
            NSWorkspace.shared.selectFile(sec.auditLogFilePath, inFileViewerRootedAtPath: "")
          }
          .controlSize(.small)
          .disabled(s.demoModeEnabled)
        }
      }

      Section {
        HStack {
          SettingLabel(
            title: "Device name", caption: "Name other Macs see. Leave blank to use the computer name.")
          Spacer()
          if s.demoModeEnabled {
            TextField("Mac Studio", text: .constant("Mac Studio"))
              .textFieldStyle(.roundedBorder).frame(width: 220)
              .disabled(true)
          } else {
            TextField(Host.current().localizedName ?? "Mac", text: $draftName)
              .textFieldStyle(.roundedBorder).frame(width: 220)
          }
        }
        HStack {
          SettingLabel(
            title: "Listening port",
            caption: "0 = automatic. Set a fixed port if you add this Mac manually on the other side.")
          Spacer()
          if s.demoModeEnabled {
            TextField("0", text: .constant("48155"))
              .textFieldStyle(.roundedBorder).frame(width: 90)
              .disabled(true)
          } else {
            TextField("0", value: $draftPort, format: .number.grouping(.never))
              .textFieldStyle(.roundedBorder).frame(width: 90)
          }
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
          .disabled(!dirty || s.demoModeEnabled)
          Button("Apply & Restart Network") {
            s.deviceName = draftName
            s.listenPort = max(0, min(65535, draftPort))
            s.serviceType = draftType
            s.discoveryEnabled = discoveryDraft
            net.restart()
          }
          .keyboardShortcut(.defaultAction)
          .disabled(!dirty || s.demoModeEnabled)
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

      Section("Transport Encryption & Connection Security") {
        SettingToggle(
          title: "Encrypt all peer-to-peer connections (AES-256-GCM)",
          caption:
            "Seals every network message with AES-256-GCM authenticated encryption, HKDF-SHA256 key derivation, and anti-replay nonces/timestamps.",
          isOn: $s.encryptNetworkTraffic)
        SettingToggle(
          title: "Reject unencrypted remote commands",
          caption:
            "Blocks and logs any incoming switch, peripheral sync, or update command that is not encrypted with AES-256-GCM.",
          isOn: $s.requireEncryptedConnections)
        HStack {
          SettingLabel(
            title: "Pairing key (HKDF-SHA256 secret)",
            caption:
              "Shared secret mixed into the AES-256-GCM encryption key. Only Macs with the matching key can decrypt or authenticate commands.")
          Spacer()
          Group {
            if s.demoModeEnabled {
              SecureField("••••••••••••", text: .constant("demo-secret-key"))
                .disabled(true)
            } else if revealKey {
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
          .disabled(s.demoModeEnabled)
        }
      }

      Section("Keystroke & Mouse Movement Surveillance Guard") {
        SettingToggle(
          title: "Monitor for keystroke & mouse movement loggers",
          caption:
            "Continuously inspects macOS WindowServer event taps (CGGetEventTapList) for any unauthorized process monitoring keystrokes or mouse movements.",
          isOn: $s.inputMonitoringGuardEnabled)
        SettingSlider(
          title: "Surveillance scan interval",
          caption: "How frequently BlueSwitch audits active system event taps.",
          value: $s.inputGuardPollInterval, range: 0.5...10, step: 0.5
        )
        .disabled(!s.inputMonitoringGuardEnabled)
        SettingToggle(
          title: "Auto-remediate: Freeze & terminate offending process",
          caption:
            "Immediately sends SIGSTOP + SIGKILL to any unauthorized process caught tapping keystrokes or mouse movement.",
          isOn: $s.autoRemediateKillProcess
        )
        .disabled(!s.inputMonitoringGuardEnabled)
        SettingToggle(
          title: "Auto-remediate: Disconnect / evacuate Bluetooth peripherals",
          caption:
            "Immediately releases your Magic Keyboard, Trackpad, and Mouse (or switches them to your safe peer Mac) when input surveillance is detected.",
          isOn: $s.autoRemediateDisconnectPeripherals
        )
        .disabled(!s.inputMonitoringGuardEnabled)
        SettingToggle(
          title: "Auto-remediate: Immediately mute Microphone",
          caption:
            "Automatically mutes the microphone when an unauthorized keystroke or mouse surveillance tap is detected.",
          isOn: $s.autoRemediateMuteMic
        )
        .disabled(!s.inputMonitoringGuardEnabled)
        SettingToggle(
          title: "Show critical modal alert dialog on threat detection",
          caption: "Brings up an immediate security alert window with process details and remediation status.",
          isOn: $s.securityModalAlerts
        )
        .disabled(!s.inputMonitoringGuardEnabled)
        HStack {
          SettingLabel(
            title: "Trusted input-monitoring processes",
            caption: "Comma-separated bundle IDs or process names allowed to use event taps.")
          Spacer()
          TextField("e.g. com.apple.universalaccessd", text: $s.allowedInputMonitorProcesses)
            .textFieldStyle(.roundedBorder).frame(width: 240)
        }
        HStack(spacing: 10) {
          Button("Scan Event Taps Now") {
            sec.scanNow()
          }
          Button("Simulate Keystroke/Mouse Logger Alert") {
            sec.triggerSimulatedIncident()
          }
          if !sec.incidents.isEmpty {
            Spacer()
            Button("Clear Incident History", role: .destructive) {
              sec.clearIncidents()
            }
          }
        }
        if !sec.incidents.isEmpty {
          ForEach(sec.incidents.prefix(8)) { inc in
            VStack(alignment: .leading, spacing: 3) {
              HStack {
                Label(
                  "\(inc.processName) (PID \(inc.pid)) — \(inc.capturedTypesDescription)",
                  systemImage: "exclamationmark.shield.fill"
                )
                .font(.callout.weight(.semibold))
                .foregroundStyle(Theme.red)
                Spacer()
                Text(inc.timestamp, style: .time)
                  .font(.caption2).foregroundStyle(.secondary)
              }
              Text(demo.sanitizePath(inc.executablePath))
                .font(.caption2.monospaced())
                .foregroundStyle(.secondary)
              Text("Remediation: \(inc.remediationSummary)")
                .font(.caption)
                .foregroundStyle(inc.isResolved ? Theme.green : Theme.red)
            }
            .padding(.vertical, 4)
          }
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
        SettingToggle(
          title: "Keystroke / mouse surveillance or security alert occurs",
          caption: "Critical alert when an unauthorized event tap or unencrypted request is detected.",
          isOn: $s.notifyOnSecurityAlert)
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
        row(
          "Toggle Microphone Mute", "Mute or unmute the microphone independently",
          $s.hotkeyMuteMic)
        row(
          "Toggle Speakers Mute", "Mute or unmute the speakers independently",
          $s.hotkeyMuteSpeakers)
        row(
          "Toggle Demo Mode", "Hide or show personal info for screen recording",
          $s.hotkeyDemoMode)
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
