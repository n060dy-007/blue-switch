import SwiftUI

// MARK: - Peripherals

struct PeripheralsPane: View {
  @ObservedObject private var bt = BluetoothService.shared
  @ObservedObject private var s = AppSettings.shared
  @ObservedObject private var clicker = BluetoothAutoClicker.shared
  @ObservedObject private var demo = DemoMode.shared
  @State private var confirmRemoveAll = false

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
            ManagedPeripheralRow(peripheral: p, tick: bt.refreshTick)
          }
          .onMove { bt.move(from: $0, to: $1) }
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
        if bt.availablePeripherals.isEmpty {
          EmptyStateRow(symbol: "dot.radiowaves.left.and.right", text: "No other paired devices found")
        } else {
          ForEach(bt.availablePeripherals) { p in
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

      Section("Pairing tips for Magic Keyboard & Trackpad (USB-C)") {
        tip("cable.connector", "First-time pairing: plug the device into this Mac with its USB-C cable for a few seconds, then unplug. It will appear above.")
        tip("desktopcomputer", "Pair each device with both Macs once, then add the same devices on both Macs (or use Macs → Sync).")
        tip("arrow.left.arrow.right", "When switching, BlueSwitch unpairs the device here so the other Mac can grab it over Bluetooth — no cable needed after setup.")
      }
    }
    .onAppear {
      bt.refresh()
      clicker.refreshPermission()
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
}

private struct ManagedPeripheralRow: View {
  let peripheral: BluetoothPeripheral
  let tick: Int
  @ObservedObject private var bt = BluetoothService.shared
  @ObservedObject private var demo = DemoMode.shared
  @State private var editing = false
  @State private var alias = ""

  var body: some View {
    let connected = demo.isPeripheralConnected(peripheral)
    let busy = bt.busyIDs.contains(peripheral.id)
    HStack(spacing: 12) {
      Image(systemName: peripheral.symbolName)
        .font(.system(size: 16, weight: .semibold))
        .frame(width: 34, height: 34)
        .background(RoundedRectangle(cornerRadius: 9).fill(connected ? Theme.blue.opacity(0.15) : Color.primary.opacity(0.06)))
        .foregroundStyle(connected ? Theme.blue : .secondary)

      VStack(alignment: .leading, spacing: 2) {
        if editing {
          TextField(peripheral.name, text: $alias, onCommit: commit)
            .textFieldStyle(.roundedBorder).frame(maxWidth: 220)
        } else {
          HStack(spacing: 4) {
            Text(demo.peripheralDisplayName(peripheral)).font(.body.weight(.medium))
            Button {
              alias = peripheral.alias
              editing = true
            } label: {
              Image(systemName: "pencil").font(.caption)
            }
            .buttonStyle(.borderless).foregroundStyle(.secondary).help("Rename")
          }
        }
        Text(demo.peripheralSubtitle(peripheral))
          .font(.caption.monospaced()).foregroundStyle(.secondary)
      }

      Spacer()

      StatusPill(
        text: busy ? "Connecting" : (connected ? "Connected" : "Disconnected"),
        color: busy ? Theme.amber : (connected ? Theme.green : .secondary),
        pulsing: busy)

      Toggle("", isOn: Binding(
        get: { peripheral.isEnabled },
        set: { v in var p = peripheral; p.isEnabled = v; bt.update(p) }))
        .toggleStyle(.switch).labelsHidden().controlSize(.small)
        .help("Include in switching")

      Button(connected ? "Release" : "Connect") {
        connected ? bt.release(peripheral) : bt.connect(peripheral)
      }
      .disabled(busy)
      .help(connected ? "Release from this Mac (upstream: Remove from PC)" : "Connect to this Mac")

      Button {
        withAnimation { bt.remove(peripheral) }
      } label: {
        Image(systemName: "minus.circle.fill").foregroundStyle(Theme.red)
      }
      .buttonStyle(.borderless)
      .help("Remove from BlueSwitch")
    }
    .padding(.vertical, 2)
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
        if !s.discoveryEnabled {
          EmptyStateRow(symbol: "eye.slash", text: "Bonjour discovery is turned off (Network settings).")
        } else if net.discovered.isEmpty {
          HStack(spacing: 10) {
            ProgressView().controlSize(.small)
            Text("Looking for other Macs running BlueSwitch…").foregroundStyle(.secondary)
          }
        } else {
          ForEach(net.discovered) { peer in
            HStack(spacing: 10) {
              Image(systemName: "desktopcomputer").foregroundStyle(.secondary).frame(width: 24)
              VStack(alignment: .leading, spacing: 1) {
                Text(demo.peerDisplayName(peer))
                Text(demo.peerAddressDisplay(peer))
                  .font(.caption.monospaced()).foregroundStyle(.secondary)
              }
              Spacer()
              StatusPill(
                text: (net.reachability[peer.id] ?? .unknown).label,
                color: (net.reachability[peer.id] ?? .unknown).color)
              Button("Register") { withAnimation { net.register(peer) } }
                .buttonStyle(.borderedProminent)
            }
          }
        }
      } header: {
        Text("Discovered on This Network")
      }

      Section {
        HStack {
          TextField("Name (optional)", text: $manualName)
          TextField("Host or IP", text: $manualHost)
          TextField("Port", text: $manualPort).frame(width: 80)
          Button("Add") {
            if let port = Int(manualPort), !manualHost.isEmpty {
              net.addManual(name: manualName, host: manualHost, port: port)
              manualName = ""; manualHost = ""; manualPort = ""
            }
          }
          .disabled(manualHost.isEmpty || Int(manualPort) == nil)
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
    let outdated = updates.isPeerOutdated(peer)
    let isUpdating = updates.updatingPeerIDs.contains(peer.id)
    let supportsOTA = AppInfo.supportsNativeOTAUpdate(version: peer.appVersion)
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
            Text(demo.peerDisplayName(peer)).font(.body.weight(.medium))
            if isTarget {
              Text("TARGET").font(.system(size: 9, weight: .heavy))
                .padding(.horizontal, 5).padding(.vertical, 1)
                .background(Capsule().fill(Theme.blue.opacity(0.18))).foregroundStyle(Theme.blue)
            }
            if let ver = peer.appVersion, !ver.isEmpty {
              Text(outdated ? "v\(ver) → v\(AppInfo.version)" : "v\(ver)")
                .font(.system(size: 9, weight: .bold))
                .padding(.horizontal, 6).padding(.vertical, 1)
                .background(
                  Capsule().fill(outdated ? Theme.amber.opacity(0.2) : Color.primary.opacity(0.08))
                )
                .foregroundStyle(outdated ? Theme.amber : .secondary)
            }
            if peer.isManual {
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
            "\(peer.name) is on v\(peer.appVersion ?? "1.0.1") (before OTA updates existed). Click to upgrade it to v\(AppInfo.version) over SSH."
          )
        } else {
          Button {
            updates.pushUpdate(to: peer)
          } label: {
            Image(systemName: "arrow.up.doc.fill")
              .foregroundStyle(outdated ? Theme.amber : .primary)
          }
          .buttonStyle(.borderless)
          .help("Push BlueSwitch v\(AppInfo.version) update to \(peer.name)")
        }

        Button {
          net.ping(id: peer.id)
        } label: {
          Image(systemName: "antenna.radiowaves.left.and.right")
        }
        .buttonStyle(.borderless).help("Check connection")

        Button {
          SwitchCoordinator.shared.sendTestNotification(to: peer)
        } label: {
          Image(systemName: "bell")
        }
        .buttonStyle(.borderless).help("Notify — send a notification to this Mac")

        Button {
          SwitchCoordinator.shared.syncPeripherals(to: peer)
        } label: {
          Image(systemName: "arrow.triangle.2.circlepath")
        }
        .buttonStyle(.borderless).help("Sync this Mac's peripheral list to \(peer.name)")
        .disabled(bt.peripherals.isEmpty)

        Button {
          withAnimation { net.remove(peer) }
        } label: {
          Image(systemName: "trash").foregroundStyle(Theme.red)
        }
        .buttonStyle(.borderless).help("Remove")
      }
      if let statusText = updates.peerUpdateStatus[peer.id] {
        HStack(spacing: 8) {
          Text(statusText).font(.caption).foregroundStyle(.secondary)
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
