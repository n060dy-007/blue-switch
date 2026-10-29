import SwiftUI

// MARK: - Peripherals

struct PeripheralsPane: View {
  @ObservedObject private var bt = BluetoothService.shared
  @ObservedObject private var s = AppSettings.shared
  @ObservedObject private var clicker = BluetoothAutoClicker.shared
  @ObservedObject private var demo = DemoMode.shared
  @ObservedObject private var diag = BluetoothDiagnosticsService.shared
  @State private var confirmRemoveAll = false
  @State private var lastDeviceTestBanner: String? = nil

  var body: some View {
    let list = demo.effectivePeripherals
    return PaneContainer(pane: .peripherals) {
      if !bt.isAuthorized && !s.demoModeEnabled {
        Section {
          BluetoothPermissionBanner()
        }
      }
      if s.autoAcceptBluetoothRequests && !clicker.isAccessibilityTrusted && !s.demoModeEnabled {
        Section {
          AccessibilityPermissionBanner()
        }
      }
      if !bt.isPoweredOn && !s.demoModeEnabled {
        Section {
          Label("Bluetooth is turned off. Turn it on in Control Center.", systemImage: "exclamationmark.triangle.fill")
            .foregroundStyle(Theme.amber)
        }
      }

      Section {
        if list.isEmpty {
          EmptyStateRow(symbol: "keyboard", text: "No peripherals registered yet — add them from the list below.")
        } else {
          ForEach(list) { p in
            ManagedPeripheralRow(
              peripheral: p,
              tick: bt.refreshTick,
              onTestComplete: { msg in lastDeviceTestBanner = msg }
            )
          }
          .onMove { bt.move(from: $0, to: $1) }
        }
        if let banner = lastDeviceTestBanner {
          HStack(spacing: 8) {
            Image(systemName: "checkmark.seal.fill").foregroundStyle(Theme.green)
            Text(demo.sanitizeLog(banner)).font(.caption)
            Spacer()
            Button("Dismiss") { lastDeviceTestBanner = nil }
              .buttonStyle(.borderless).font(.caption2)
          }
          .padding(.vertical, 2)
        }
      } header: {
        HStack {
          Text("Switched Peripherals")
          Spacer()
          if !bt.peripherals.isEmpty && !s.demoModeEnabled {
            Button("Remove All", role: .destructive) { confirmRemoveAll = true }
              .buttonStyle(.borderless).font(.caption)
          }
        }
      } footer: {
        Text("These devices move together when you switch. Toggle a device off to leave it on whichever Mac it's on.")
          .font(.caption).foregroundStyle(.secondary)
      }

      Section {
        let availableList = demo.effectiveAvailablePeripherals
        if availableList.isEmpty {
          EmptyStateRow(symbol: "dot.radiowaves.left.and.right", text: "No other paired devices found")
        } else {
          ForEach(availableList) { p in
            HStack(spacing: 10) {
              Image(systemName: p.symbolName).frame(width: 24).foregroundStyle(.secondary)
              VStack(alignment: .leading, spacing: 1) {
                Text(demo.peripheralDisplayName(p))
                Text(demo.peripheralSubtitle(p)).font(.caption.monospaced()).foregroundStyle(.secondary)
              }
              Spacer()
              Button {
                withAnimation { bt.add(p) }
              } label: {
                Label("Add", systemImage: "plus.circle.fill")
              }
              .buttonStyle(.borderless)
              .foregroundStyle(Theme.blue)
              .disabled(s.demoModeEnabled)
            }
          }
        }
      } header: {
        HStack {
          Text("Paired With This Mac")
          Spacer()
          Button {
            bt.refresh()
          } label: {
            Label("Refresh", systemImage: "arrow.clockwise")
          }
          .buttonStyle(.borderless).font(.caption)
        }
      }

      // MARK: Bluetooth Testing & Diagnostics Suite
      Section {
        HStack(spacing: 10) {
          Button {
            diag.runFullDiagnosticSuite()
          } label: {
            Label(
              diag.isRunningDiagnostics
                ? "Running Bluetooth Diagnostics…"
                : "Run Full Diagnostic & Security Test",
              systemImage: "stethoscope"
            )
          }
          .buttonStyle(.borderedProminent)
          .disabled(diag.isRunningDiagnostics)

          if !list.isEmpty {
            Button {
              for p in list {
                diag.testPeripheral(p) { _, msg in
                  lastDeviceTestBanner = msg
                }
              }
            } label: {
              Label("Test All Peripherals", systemImage: "bolt.horizontal.circle")
            }
            .disabled(diag.isRunningDiagnostics)
          }

          Spacer()

          Text(diag.lastDiagnosticSummary)
            .font(.caption)
            .foregroundStyle(.secondary)
        }

        if !diag.diagnosticSteps.isEmpty {
          ForEach(diag.diagnosticSteps) { step in
            HStack(alignment: .top, spacing: 10) {
              Image(systemName: step.status.symbol)
                .foregroundStyle(step.status.color)
                .frame(width: 18)
              VStack(alignment: .leading, spacing: 2) {
                HStack {
                  Text(step.title).font(.callout.weight(.semibold))
                  Spacer()
                  if let ms = step.durationMs {
                    Text("\(ms) ms").font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                  }
                  StatusPill(
                    text: step.status.rawValue,
                    color: step.status.color,
                    pulsing: step.status == .running
                  )
                }
                Text(demo.sanitizeLog(step.detail))
                  .font(.caption)
                  .foregroundStyle(.secondary)
              }
            }
            .padding(.vertical, 2)
          }
        }
      } header: {
        Text("Bluetooth Testing & Diagnostics")
      } footer: {
        Text("Verifies Bluetooth radio power, privacy authorization, peripheral RSSI signal quality, link-key encryption, and switching readiness.")
          .font(.caption).foregroundStyle(.secondary)
      }

      // MARK: Bluetooth Reliability & Self-Healing
      Section("Bluetooth Reliability & Auto-Heal") {
        SettingToggle(
          title: "Auto-heal unexpectedly dropped peripherals",
          caption:
            "Automatically reconnects managed peripherals if they drop due to wireless interference while this Mac owns them.",
          isOn: $s.btAutoHealEnabled
        )
        SettingSlider(
          title: "Auto-heal watchdog interval",
          caption: "How often BlueSwitch checks for dropped local peripherals.",
          value: $s.btAutoHealInterval,
          range: 3...30,
          step: 1
        )
        .disabled(!s.btAutoHealEnabled)
        .onChange(of: s.btAutoHealInterval) { _ in
          diag.scheduleWatchdog()
        }
        SettingToggle(
          title: "Adaptive retry backoff & stale link-key recovery",
          caption:
            "Spaces out consecutive HCI page attempts by 1.3× and clears stale macOS link keys automatically when a peripheral was re-paired on another Mac.",
          isOn: $s.btAdaptiveBackoff
        )
        HStack(spacing: 10) {
          Button {
            bt.resetStuckPairingSessions()
          } label: {
            Label("Reset Stuck Pairing Sessions", systemImage: "arrow.triangle.2.circlepath")
          }
          Button {
            diag.resetReliabilityStats()
          } label: {
            Label("Clear Reliability Stats", systemImage: "chart.bar.xaxis")
          }
          Spacer()
          Text("Session auto-heals: \(s.demoModeEnabled ? 1 : diag.totalAutoHealsSession)")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
      }

      // MARK: Bluetooth Security Information & Threat Protection
      Section("Bluetooth Controller & Link Security Information") {
        HStack {
          Text("Controller Security Posture")
          Spacer()
          StatusPill(
            text: diag.controllerInfo.securityPostureLabel,
            color: diag.controllerInfo.securityPostureColor
          )
        }
        btInfoRow("Local Host Controller MAC", diag.controllerInfo.displayAddress)
        btInfoRow(
          "Radio & Discoverability",
          (s.demoModeEnabled || diag.controllerInfo.isPoweredOn ? "Powered On" : "Powered Off")
            + " · "
            + (!s.demoModeEnabled && diag.controllerInfo.isDiscoverable
              ? "Discoverable" : "Hidden (Non-Discoverable)")
            + " · CoD \(diag.controllerInfo.displayClassOfDeviceHex)"
        )
        btInfoRow(
          "Active HID Links",
          "\(s.demoModeEnabled ? list.filter { demo.isPeripheralConnected($0) }.count : diag.controllerInfo.connectedHIDCount) connected · "
            + "\((s.demoModeEnabled ? 0 : diag.controllerInfo.unencryptedActiveCount) == 0 ? "100% Link-Key / AES Encrypted" : "\(diag.controllerInfo.unencryptedActiveCount) Unencrypted")"
        )

        SettingToggle(
          title: "Audit & alert on unencrypted Bluetooth HID links",
          caption:
            "Logs a security warning if any connected keyboard, mouse, or trackpad operates without link-layer encryption.",
          isOn: $s.btRequireEncryptedLink
        )
        SettingToggle(
          title: "Block unsolicited unpaired incoming HID connections (Anti-Keystroke Injection)",
          caption:
            "Immediately disconnects and alerts on unknown unpaired Bluetooth HID devices attempting to inject keystrokes or mouse events (BlueDucky defense).",
          isOn: $s.btBlockUnsolicitedHID
        )

        if !list.isEmpty {
          ForEach(list) { p in
            let t = diag.telemetry(for: p)
            VStack(alignment: .leading, spacing: 4) {
              HStack {
                Label(demo.peripheralDisplayName(p), systemImage: p.symbolName)
                  .font(.callout.weight(.semibold))
                Spacer()
                HStack(spacing: 6) {
                  Image(systemName: t.isLinkEncrypted ? "lock.shield.fill" : "shield.lefthalf.filled")
                    .foregroundStyle(t.encryptionColor)
                  Text(t.encryptionBadgeText)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(t.encryptionColor)
                }
              }
              HStack(spacing: 12) {
                Text("Class: \(t.deviceClassDescription)")
                Text("·")
                Text("Vendor: \(t.vendorName)")
                Text("·")
                Text("Signal: \(t.rssiDisplay)")
                Text("·")
                Text("Origin: \(t.connectionDirectionLabel)")
              }
              .font(.caption2)
              .foregroundStyle(.secondary)
            }
            .padding(.vertical, 3)
          }
        }
      }

      Section("Pairing tips for Magic Keyboard & Trackpad (USB-C)") {
        tip("cable.connector", "First-time pairing: plug the device into this Mac with its USB-C cable for a few seconds, then unplug. It will appear above.")
        tip("desktopcomputer", "Pair each device with both Macs once, then add the same devices on both Macs (or use Macs → Sync).")
        tip("arrow.left.arrow.right", "When switching, BlueSwitch unpairs the device here so the other Mac can grab it over Bluetooth — no cable needed after setup.")
      }
    }
    .onAppear {
      bt.refresh()
      clicker.refreshPermission()
      diag.refreshTelemetry()
    }
    .onChange(of: s.demoModeEnabled) { _ in
      lastDeviceTestBanner = nil
      diag.refreshTelemetry()
    }
    .confirmationDialog("Remove all peripherals from BlueSwitch?", isPresented: $confirmRemoveAll) {
      Button("Remove All", role: .destructive) { bt.removeAll() }
    } message: {
      Text("They stay paired with macOS; BlueSwitch just stops switching them.")
    }
  }

  private func tip(_ symbol: String, _ text: String) -> some View {
    Label { Text(text).font(.callout) } icon: { Image(systemName: symbol).foregroundStyle(Theme.blue) }
  }

  private func btInfoRow(_ title: String, _ value: String) -> some View {
    HStack {
      Text(title)
      Spacer()
      Text(value)
        .font(.callout.monospaced())
        .foregroundStyle(.secondary)
        .textSelection(.enabled)
    }
  }
}

private struct ManagedPeripheralRow: View {
  let peripheral: BluetoothPeripheral
  let tick: Int
  var onTestComplete: ((String) -> Void)? = nil
  @ObservedObject private var bt = BluetoothService.shared
  @ObservedObject private var demo = DemoMode.shared
  @ObservedObject private var diag = BluetoothDiagnosticsService.shared
  @State private var editing = false
  @State private var alias = ""

  var body: some View {
    let connected = demo.isPeripheralConnected(peripheral)
    let busy = bt.busyIDs.contains(peripheral.id)
    let testing = diag.testingPeripheralIDs.contains(peripheral.id)
    let t = diag.telemetry(for: peripheral)

    VStack(alignment: .leading, spacing: 6) {
      HStack(spacing: 12) {
        Image(systemName: peripheral.symbolName)
          .font(.system(size: 16, weight: .semibold))
          .frame(width: 34, height: 34)
          .background(RoundedRectangle(cornerRadius: 9).fill(connected ? Theme.blue.opacity(0.15) : Color.primary.opacity(0.06)))
          .foregroundStyle(connected ? Theme.blue : .secondary)

        VStack(alignment: .leading, spacing: 2) {
          if editing && !demo.isEnabled {
            TextField(peripheral.name, text: $alias, onCommit: commit)
              .textFieldStyle(.roundedBorder).frame(maxWidth: 220)
          } else {
            HStack(spacing: 4) {
              Text(demo.peripheralDisplayName(peripheral)).font(.body.weight(.medium))
              if !demo.isEnabled {
                Button {
                  alias = peripheral.alias
                  editing = true
                } label: {
                  Image(systemName: "pencil").font(.caption)
                }
                .buttonStyle(.borderless).foregroundStyle(.secondary).help("Rename")
              }
            }
          }
          HStack(spacing: 6) {
            Text(demo.peripheralSubtitle(peripheral))
              .font(.caption.monospaced()).foregroundStyle(.secondary)
            Text("·").foregroundStyle(.tertiary)
            Label(t.encryptionBadgeText, systemImage: t.isLinkEncrypted ? "lock.fill" : "lock.slash")
              .font(.caption2.weight(.medium))
              .foregroundStyle(t.encryptionColor)
            if let rssi = t.rssi, connected {
              Text("·").foregroundStyle(.tertiary)
              Text("\(rssi) dBm")
                .font(.caption2.monospacedDigit())
                .foregroundStyle(t.signalQuality.color)
            }
            if let avgMs = t.stats.averageLatencyMs {
              Text("·").foregroundStyle(.tertiary)
              Text("\(t.stats.reliabilityPercent)% (\(avgMs) ms)")
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
            }
          }
        }

        Spacer()

        StatusPill(
          text: busy ? "Connecting" : (testing ? "Testing" : (connected ? "Connected" : "Disconnected")),
          color: (busy || testing) ? Theme.amber : (connected ? Theme.green : .secondary),
          pulsing: busy || testing)

        Toggle("", isOn: Binding(
          get: { peripheral.isEnabled },
          set: { v in var p = peripheral; p.isEnabled = v; bt.update(p) }))
          .toggleStyle(.switch).labelsHidden().controlSize(.small)
          .help("Include in switching")

        Button("Test") {
          diag.testPeripheral(peripheral) { _, summary in
            onTestComplete?(summary)
          }
        }
        .controlSize(.small)
        .disabled(busy || testing)
        .help("Test Bluetooth link quality, encryption, and connection latency")

        Button(connected ? "Release" : "Connect") {
          if demo.isSimulatingSwitch {
            demo.demoPeripheralsConnectedHere.toggle()
          } else {
            connected ? bt.release(peripheral) : bt.connect(peripheral)
          }
        }
        .disabled(busy || testing)
        .help(connected ? "Release from this Mac (upstream: Remove from PC)" : "Connect to this Mac")

        Button {
          withAnimation { bt.remove(peripheral) }
        } label: {
          Image(systemName: "minus.circle.fill").foregroundStyle(Theme.red)
        }
        .buttonStyle(.borderless)
        .disabled(demo.isEnabled)
        .help("Remove from BlueSwitch")
      }
    }
    .padding(.vertical, 3)
  }

  private func commit() {
    var p = peripheral
    p.alias = alias.trimmingCharacters(in: .whitespaces)
    bt.update(p)
    editing = false
  }
}

// MARK: - Macs

struct DevicesPane: View {
  @ObservedObject private var net = NetworkService.shared
  @ObservedObject private var bt = BluetoothService.shared
  @ObservedObject private var s = AppSettings.shared
  @ObservedObject private var updates = UpdateChecker.shared
  @ObservedObject private var demo = DemoMode.shared
  @State private var manualName = ""
  @State private var manualHost = ""
  @State private var manualPort = ""

  var body: some View {
    let peersList = demo.effectivePeers
    return PaneContainer(pane: .devices) {
      Section {
        if peersList.isEmpty {
          EmptyStateRow(symbol: "desktopcomputer", text: "No Macs registered. Pick one from the discovered list below.")
        } else {
          ForEach(peersList) { peer in peerRow(peer) }
        }
      } header: {
        HStack(spacing: 12) {
          Text("Registered Macs")
          Spacer()
          if !peersList.isEmpty {
            Button {
              updates.pushUpdateToAllPeers()
            } label: {
              Label("Update All Macs (v\(AppInfo.version))", systemImage: "arrow.up.doc.fill")
            }
            .buttonStyle(.borderless).font(.caption)
          }
          Button {
            net.checkAllPeers()
          } label: {
            Label("Check All", systemImage: "antenna.radiowaves.left.and.right")
          }
          .buttonStyle(.borderless).font(.caption)
        }
      } footer: {
        Text("The selected target is the Mac peripherals switch to. When \"Automatically update other Macs\" is enabled in General settings, peers on v1.0.2+ update automatically whenever this Mac is newer.")
          .font(.caption).foregroundStyle(.secondary)
      }

      Section {
        let discoveredList = demo.effectiveDiscoveredPeers
        if !s.discoveryEnabled && !s.demoModeEnabled {
          EmptyStateRow(symbol: "eye.slash", text: "Bonjour discovery is turned off (Network settings).")
        } else if discoveredList.isEmpty {
          HStack(spacing: 10) {
            ProgressView().controlSize(.small)
            Text("Looking for other Macs running BlueSwitch…").foregroundStyle(.secondary)
          }
        } else {
          ForEach(discoveredList) { peer in
            HStack(spacing: 10) {
              Image(systemName: "desktopcomputer").foregroundStyle(.secondary).frame(width: 24)
              VStack(alignment: .leading, spacing: 1) {
                Text(demo.peerDisplayName(peer))
                Text(demo.peerAddressDisplay(peer))
                  .font(.caption.monospaced()).foregroundStyle(.secondary)
              }
              Spacer()
              let reach = demo.reachability(for: peer)
              StatusPill(text: reach.label, color: reach.color)
              Button("Register") { withAnimation { net.register(peer) } }
                .buttonStyle(.borderedProminent)
                .disabled(s.demoModeEnabled)
            }
          }
        }
      } header: {
        Text("Discovered on This Network")
      }

      Section {
        HStack {
          TextField("Name (optional)", text: s.demoModeEnabled ? .constant("") : $manualName)
            .disabled(s.demoModeEnabled)
          TextField("Host or IP", text: s.demoModeEnabled ? .constant("") : $manualHost)
            .disabled(s.demoModeEnabled)
          TextField("Port", text: s.demoModeEnabled ? .constant("") : $manualPort).frame(width: 80)
            .disabled(s.demoModeEnabled)
          Button("Add") {
            if let port = Int(manualPort), !manualHost.isEmpty {
              net.addManual(name: manualName, host: manualHost, port: port)
              manualName = ""; manualHost = ""; manualPort = ""
            }
          }
          .disabled(s.demoModeEnabled || manualHost.isEmpty || Int(manualPort) == nil)
        }
        .textFieldStyle(.roundedBorder)
      } header: {
        Text("Add Manually")
      } footer: {
        Text("Use when Bonjour is blocked (e.g. some corporate or guest Wi-Fi). Set a fixed listening port on the other Mac in Network settings.")
          .font(.caption).foregroundStyle(.secondary)
      }
    }
  }

  private func peerRow(_ peer: PeerDevice) -> some View {
    let reach = demo.reachability(for: peer)
    let isTarget = demo.effectiveActivePeer?.id == peer.id
    let outdated = s.demoModeEnabled ? false : updates.isPeerOutdated(peer)
    let isUpdating = s.demoModeEnabled ? false : updates.updatingPeerIDs.contains(peer.id)
    let supportsOTA = s.demoModeEnabled ? true : AppInfo.supportsNativeOTAUpdate(version: peer.appVersion)
    let displayPeerName = demo.peerDisplayName(peer)
    let displayVer = s.demoModeEnabled ? AppInfo.version : peer.appVersion
    return VStack(alignment: .leading, spacing: 4) {
      HStack(spacing: 12) {
        Button {
          if demo.isSimulatingSwitch {
            demo.activeDemoPeerID = peer.id
          } else {
            net.setActive(peer)
          }
        } label: {
          Image(systemName: isTarget ? "largecircle.fill.circle" : "circle")
            .foregroundStyle(isTarget ? Theme.blue : .secondary)
            .font(.system(size: 16))
        }
        .buttonStyle(.borderless)
        .help("Use as switch target")

        Image(systemName: "desktopcomputer")
          .font(.system(size: 16, weight: .semibold))
          .frame(width: 34, height: 34)
          .background(RoundedRectangle(cornerRadius: 9).fill(isTarget ? AnyShapeStyle(Theme.brandGradient) : AnyShapeStyle(Color.primary.opacity(0.06))))
          .foregroundStyle(isTarget ? .white : .secondary)

        VStack(alignment: .leading, spacing: 2) {
          HStack(spacing: 6) {
            Text(displayPeerName).font(.body.weight(.medium))
            if isTarget {
              Text("TARGET").font(.system(size: 9, weight: .heavy))
                .padding(.horizontal, 5).padding(.vertical, 1)
                .background(Capsule().fill(Theme.blue.opacity(0.18))).foregroundStyle(Theme.blue)
            }
            if let ver = displayVer, !ver.isEmpty {
              Text(outdated ? "v\(ver) → v\(AppInfo.version)" : "v\(ver)")
                .font(.system(size: 9, weight: .bold))
                .padding(.horizontal, 6).padding(.vertical, 1)
                .background(
                  Capsule().fill(outdated ? Theme.amber.opacity(0.2) : Color.primary.opacity(0.08))
                )
                .foregroundStyle(outdated ? Theme.amber : .secondary)
            }
            if peer.isManual && !s.demoModeEnabled {
              Text("MANUAL").font(.system(size: 9, weight: .heavy))
                .padding(.horizontal, 5).padding(.vertical, 1)
                .background(Capsule().fill(Color.primary.opacity(0.1)))
            }
          }
          Text(demo.peerAddressDisplay(peer))
            .font(.caption.monospaced()).foregroundStyle(.secondary)
        }

        Spacer()

        StatusPill(text: reach.label, color: reach.color, pulsing: reach == .checking)

        if isUpdating {
          ProgressView().controlSize(.small)
        } else if outdated && !supportsOTA {
          Button("Update via SSH…") {
            updates.bootstrapPeerViaSSH(peer)
          }
          .controlSize(.small)
          .help(
            "\(displayPeerName) is on v\(displayVer ?? "1.0.1") (before OTA updates existed). Click to upgrade it to v\(AppInfo.version) over SSH."
          )
        } else {
          Button {
            if !s.demoModeEnabled {
              updates.pushUpdate(to: peer)
            }
          } label: {
            Image(systemName: "arrow.up.doc.fill")
              .foregroundStyle(outdated ? Theme.amber : .primary)
          }
          .buttonStyle(.borderless)
          .help("Push BlueSwitch v\(AppInfo.version) update to \(displayPeerName)")
        }

        Button {
          if !s.demoModeEnabled {
            net.ping(id: peer.id)
          }
        } label: {
          Image(systemName: "antenna.radiowaves.left.and.right")
        }
        .buttonStyle(.borderless).help("Check connection")

        Button {
          if !s.demoModeEnabled {
            SwitchCoordinator.shared.sendTestNotification(to: peer)
          }
        } label: {
          Image(systemName: "bell")
        }
        .buttonStyle(.borderless).help("Notify — send a notification to \(displayPeerName)")

        Button {
          if !s.demoModeEnabled {
            SwitchCoordinator.shared.syncPeripherals(to: peer)
          }
        } label: {
          Image(systemName: "arrow.triangle.2.circlepath")
        }
        .buttonStyle(.borderless).help("Sync this Mac's peripheral list to \(displayPeerName)")
        .disabled(!s.demoModeEnabled && bt.peripherals.isEmpty)

        Button {
          withAnimation { net.remove(peer) }
        } label: {
          Image(systemName: "trash").foregroundStyle(Theme.red)
        }
        .buttonStyle(.borderless)
        .disabled(s.demoModeEnabled)
        .help("Remove")
      }
      if !s.demoModeEnabled, let statusText = updates.peerUpdateStatus[peer.id] {
        HStack(spacing: 8) {
          Text(demo.sanitizeLog(statusText)).font(.caption).foregroundStyle(.secondary)
          if !supportsOTA && peer.appVersion != nil {
            Button("Run SSH Upgrade…") { updates.bootstrapPeerViaSSH(peer) }
              .buttonStyle(.link).font(.caption)
          }
        }
        .padding(.leading, 46)
      }
    }
    .padding(.vertical, 2)
  }
}
