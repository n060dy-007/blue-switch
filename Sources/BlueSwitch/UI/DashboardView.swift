import SwiftUI

/// Popover dashboard shown from the menu bar.
struct DashboardView: View {
  let openSettings: (SettingsPane?) -> Void

  @ObservedObject private var bt = BluetoothService.shared
  @ObservedObject private var net = NetworkService.shared
  @ObservedObject private var coordinator = SwitchCoordinator.shared
  @ObservedObject private var settings = AppSettings.shared
  @ObservedObject private var clicker = BluetoothAutoClicker.shared
  @ObservedObject private var updates = UpdateChecker.shared
  @ObservedObject private var sec = SecurityMonitor.shared
  @ObservedObject private var audio = AudioService.shared
  @ObservedObject private var demo = DemoMode.shared
  @ObservedObject private var btDiag = BluetoothDiagnosticsService.shared

  var body: some View {
    VStack(spacing: 0) {
      header
      ScrollView {
        VStack(spacing: 12) {
          if settings.demoModeEnabled {
            demoBannerCard
          }
          if let latestIncident = demo.effectiveSecurityIncidents.first {
            Card {
              VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                  Image(systemName: "exclamationmark.shield.fill")
                    .font(.title3)
                    .foregroundStyle(Theme.red)
                  VStack(alignment: .leading, spacing: 1) {
                    Text("Security Alert: \(latestIncident.capturedTypesDescription) Monitor")
                      .font(.caption.weight(.bold))
                      .foregroundStyle(Theme.red)
                    Text("\(demo.sanitizeLog(latestIncident.processName)) (PID \(latestIncident.pid))")
                      .font(.caption2.weight(.semibold))
                  }
                  Spacer()
                  Button("Details") {
                    openSettings(.network)
                  }
                  .controlSize(.small)
                }
                Text("Remediation: \(demo.sanitizeLog(latestIncident.remediationSummary))")
                  .font(.caption2)
                  .foregroundStyle(.secondary)
              }
            }
          }
          if !settings.demoModeEnabled, updates.hasNewerReleaseOnline, let tag = updates.latestVersionTag {
            Card {
              HStack(spacing: 10) {
                Image(systemName: "arrow.down.circle.fill")
                  .font(.title3)
                  .foregroundStyle(Theme.blue)
                VStack(alignment: .leading, spacing: 2) {
                  Text("Update \(tag) available on GitHub").font(.caption.weight(.semibold))
                  Text(updates.status).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                Button(updates.isInstalling ? "Installing…" : "Update") {
                  updates.checkAndInstallLatestRelease(alsoUpdatePeers: settings.autoUpdatePeers)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(updates.isInstalling)
              }
            }
          }
          if !bt.isAuthorized && !settings.demoModeEnabled {
            Card { BluetoothPermissionBanner(compact: true) }
          }
          if settings.autoAcceptBluetoothRequests && !clicker.isAccessibilityTrusted
            && !settings.demoModeEnabled
          {
            Card { AccessibilityPermissionBanner(compact: true) }
          }
          switchCard
          audioCard
          peripheralsCard
        }
        .padding(14)
      }
      footer
    }
    .frame(width: 360, height: 560)
    .onAppear {
      clicker.refreshPermission()
      audio.refresh()
    }
  }

  private var demoBannerCard: some View {
    Card {
      VStack(alignment: .leading, spacing: 8) {
        HStack(spacing: 8) {
          Image(systemName: "video.fill")
            .foregroundStyle(Theme.amber)
          VStack(alignment: .leading, spacing: 1) {
            Text(demo.isAutoPlaying ? "Demo Auto-Play Running" : "Demo Mode Active")
              .font(.caption.weight(.bold))
            Text("Personal names, MACs, IPs & paths are hidden")
              .font(.caption2)
              .foregroundStyle(.secondary)
          }
          Spacer()
          Button("Exit") {
            demo.toggle()
          }
          .controlSize(.mini)
        }
        HStack(spacing: 8) {
          Button {
            demo.toggleAutoPlay()
          } label: {
            Label(
              demo.isAutoPlaying ? "Stop Auto" : "Auto-Play",
              systemImage: demo.isAutoPlaying ? "stop.fill" : "play.fill"
            )
            .font(.caption2.weight(.semibold))
          }
          .controlSize(.small)
          .buttonStyle(.borderedProminent)
          .tint(demo.isAutoPlaying ? Theme.red : Theme.amber)

          Button {
            openSettings(.demo)
          } label: {
            Label("Demo Options…", systemImage: "slider.horizontal.3")
              .font(.caption2)
          }
          .controlSize(.small)
          Spacer()
        }
      }
    }
  }

  // MARK: Audio (Separate Mic & Speakers Mute)

  private var audioCard: some View {
    Card {
      VStack(alignment: .leading, spacing: 10) {
        HStack {
          Label("Audio Controls", systemImage: "waveform")
            .font(.headline)
          Spacer()
          Button {
            audio.refresh()
          } label: {
            Image(systemName: "arrow.clockwise")
          }
          .buttonStyle(.borderless)
          .help("Refresh audio state")
        }

        HStack(spacing: 8) {
          Button {
            audio.toggleMicMute()
          } label: {
            Label(
              audio.isMicMuted ? "Mic Muted" : "Mute Mic",
              systemImage: audio.isMicMuted ? "mic.slash.fill" : "mic.fill"
            )
          }
          .buttonStyle(PillButtonStyle(tint: audio.isMicMuted ? Theme.red : Theme.indigo))

          Button {
            audio.toggleSpeakersMute()
          } label: {
            Label(
              audio.isSpeakersMuted ? "Speakers Muted" : "Mute Speakers",
              systemImage: audio.isSpeakersMuted ? "speaker.slash.fill" : "speaker.wave.2.fill"
            )
          }
          .buttonStyle(PillButtonStyle(tint: audio.isSpeakersMuted ? Theme.red : Theme.blue))
        }

        VStack(spacing: 6) {
          HStack(spacing: 8) {
            Image(systemName: audio.isMicMuted ? "mic.slash.fill" : "mic.fill")
              .foregroundStyle(audio.isMicMuted ? Theme.red : .secondary)
              .frame(width: 18)
            Slider(
              value: Binding(
                get: { Double(audio.micVolume) },
                set: { audio.setMicVolume(Int($0)) }
              ),
              in: 0...100
            )
            .controlSize(.small)
            Text(audio.isMicMuted ? "Muted" : "\(audio.micVolume)%")
              .font(.caption2.monospacedDigit())
              .foregroundStyle(audio.isMicMuted ? Theme.red : .secondary)
              .frame(width: 42, alignment: .trailing)
          }
          HStack(spacing: 8) {
            Image(systemName: audio.isSpeakersMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
              .foregroundStyle(audio.isSpeakersMuted ? Theme.red : .secondary)
              .frame(width: 18)
            Slider(
              value: Binding(
                get: { Double(audio.speakersVolume) },
                set: { audio.setSpeakersVolume(Int($0)) }
              ),
              in: 0...100
            )
            .controlSize(.small)
            Text(audio.isSpeakersMuted ? "Muted" : "\(audio.speakersVolume)%")
              .font(.caption2.monospacedDigit())
              .foregroundStyle(audio.isSpeakersMuted ? Theme.red : .secondary)
              .frame(width: 42, alignment: .trailing)
          }
        }
      }
    }
  }

  // MARK: Header

  private var header: some View {
    ZStack(alignment: .bottomLeading) {
      Theme.brandGradient
      // Decorative glow
      Circle().fill(.white.opacity(0.15)).frame(width: 160).offset(x: 230, y: -60).blur(radius: 2)
      HStack(alignment: .center) {
        VStack(alignment: .leading, spacing: 2) {
          HStack(spacing: 6) {
            Text("BlueSwitch").font(.title2.weight(.heavy)).foregroundStyle(.white)
            if settings.demoModeEnabled {
              Text("DEMO")
                .font(.system(size: 9, weight: .black))
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(Capsule().fill(Color.black.opacity(0.35)))
                .foregroundStyle(.white)
            }
          }
          Text(demo.localMacDisplayName).font(.caption).foregroundStyle(.white.opacity(0.85))
        }
        Spacer()
        Button {
          demo.toggle()
        } label: {
          HStack(spacing: 4) {
            Image(systemName: settings.demoModeEnabled ? "video.fill" : "eye.slash")
            Text(settings.demoModeEnabled ? "DEMO ON" : "Demo")
          }
          .font(.caption2.weight(.bold))
          .padding(.horizontal, 8).padding(.vertical, 5)
          .background(
            Capsule().fill(
              settings.demoModeEnabled ? Theme.amber : .white.opacity(0.18))
          )
          .foregroundStyle(settings.demoModeEnabled ? .black : .white)
        }
        .buttonStyle(.plain)
        .help(
          settings.demoModeEnabled
            ? "Demo Mode ON (Personal info hidden) — click to disable"
            : "Enable Demo Mode for public screen recording")

        let state = demo.effectiveConnectionState
        Text(state.label)
          .font(.caption.weight(.bold))
          .padding(.horizontal, 10).padding(.vertical, 5)
          .background(Capsule().fill(.white.opacity(0.22)))
          .foregroundStyle(.white)
      }
      .padding(16)
    }
    .frame(height: 78)
    .clipped()
  }

  // MARK: Switch card

  private var switchCard: some View {
    let connState = demo.effectiveConnectionState
    let activePeer = demo.effectiveActivePeer
    return Card {
      VStack(spacing: 14) {
        HStack(spacing: 0) {
          macBadge(
            name: "This Mac", subtitle: demo.localMacDisplayName,
            active: connState == .allConnected)
          FlowArrows(direction: arrowDirection, animating: coordinator.phase.isWorking)
            .frame(width: 70)
          macBadge(
            name: activePeer.map { demo.peerDisplayName($0) } ?? "No peer",
            subtitle: peerSubtitle,
            active: connState == .allDisconnected && activePeer != nil)
        }

        peerPicker

        Button(action: coordinator.switchDevices) {
          HStack(spacing: 8) {
            if coordinator.phase.isWorking {
              ProgressView().controlSize(.small).tint(.white)
            } else {
              Image(systemName: "arrow.left.arrow.right")
            }
            Text(coordinator.phase.isWorking ? "Switching…" : "Switch Now")
          }
        }
        .buttonStyle(GradientButtonStyle())
        .disabled(coordinator.phase.isWorking || activePeer == nil)
        .keyboardShortcut(.defaultAction)

        HStack(spacing: 8) {
          Button {
            coordinator.sendToPeer()
          } label: {
            Label("Send to Peer", systemImage: "arrow.up.right")
          }
          .buttonStyle(PillButtonStyle(tint: Theme.indigo))
          Button {
            coordinator.takeFromPeer()
          } label: {
            Label("Take Here", systemImage: "arrow.down.left")
          }
          .buttonStyle(PillButtonStyle(tint: Theme.blue))
        }
        .disabled(coordinator.phase.isWorking || activePeer == nil)

        phaseMessage
      }
    }
  }

  private var arrowDirection: FlowArrows.Direction {
    switch demo.effectiveConnectionState {
    case .allConnected: return .right
    case .allDisconnected: return .left
    default: return .both
    }
  }

  private var peerSubtitle: String {
    guard let p = demo.effectiveActivePeer else { return "Add in Settings" }
    return demo.reachability(for: p).label
  }

  private func macBadge(name: String, subtitle: String, active: Bool) -> some View {
    VStack(spacing: 6) {
      ZStack {
        Circle()
          .fill(active ? AnyShapeStyle(Theme.brandGradient) : AnyShapeStyle(Color.primary.opacity(0.07)))
          .frame(width: 54, height: 54)
          .shadow(color: active ? Theme.blue.opacity(0.45) : .clear, radius: 10, y: 3)
        Image(systemName: "desktopcomputer")
          .font(.system(size: 22, weight: .semibold))
          .foregroundStyle(active ? .white : .secondary)
      }
      Text(name).font(.caption.weight(.semibold)).lineLimit(1)
      Text(subtitle).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
    }
    .frame(maxWidth: .infinity)
    .animation(.spring(response: 0.4, dampingFraction: 0.75), value: active)
  }

  @ViewBuilder private var peerPicker: some View {
    let peersList = demo.effectivePeers
    if peersList.count > 1 {
      Picker(
        "Target",
        selection: Binding(
          get: { demo.effectiveActivePeer?.id ?? "" },
          set: { id in
            if demo.isSimulatingSwitch {
              demo.activeDemoPeerID = id
            } else if let p = net.peers.first(where: { $0.id == id }) {
              net.setActive(p)
            }
          })
      ) {
        ForEach(peersList) { p in Text(demo.peerDisplayName(p)).tag(p.id) }
      }
      .pickerStyle(.menu)
      .controlSize(.small)
    } else if peersList.isEmpty {
      Button("Register another Mac…") { openSettings(.devices) }
        .buttonStyle(.link)
        .font(.caption)
    }
  }

  @ViewBuilder private var phaseMessage: some View {
    switch coordinator.phase {
    case .idle:
      EmptyView()
    case .working(let m):
      Text(demo.sanitizeLog(m)).font(.caption).foregroundStyle(.secondary).transition(.opacity)
    case .success(let m):
      Label(demo.sanitizeLog(m), systemImage: "checkmark.circle.fill").font(.caption)
        .foregroundStyle(Theme.green)
        .transition(.opacity)
    case .failure(let m):
      Label(demo.sanitizeLog(m), systemImage: "exclamationmark.triangle.fill").font(.caption)
        .foregroundStyle(Theme.red).multilineTextAlignment(.leading)
        .fixedSize(horizontal: false, vertical: true)
        .transition(.opacity)
    }
  }

  // MARK: Peripherals

  private var peripheralsCard: some View {
    let list = demo.effectivePeripherals
    return Card {
      VStack(alignment: .leading, spacing: 10) {
        HStack(spacing: 8) {
          Text("Peripherals").font(.headline)
          if settings.btAutoHealEnabled {
            Text("AUTO-HEAL")
              .font(.system(size: 8, weight: .bold))
              .padding(.horizontal, 5).padding(.vertical, 2)
              .background(Capsule().fill(Theme.green.opacity(0.15)))
              .foregroundStyle(Theme.green)
              .help("Automatically reconnects unexpectedly dropped peripherals")
          }
          Spacer()
          Button {
            btDiag.runFullDiagnosticSuite()
            openSettings(.peripherals)
          } label: {
            Label("Test & Security", systemImage: "stethoscope")
              .font(.caption)
          }
          .buttonStyle(.borderless)
          .help("Run Bluetooth Diagnostic & Security Suite")
          Button {
            bt.refresh()
          } label: {
            Image(systemName: "arrow.clockwise")
          }
          .buttonStyle(.borderless)
          .help("Refresh")
        }
        if list.isEmpty {
          EmptyStateRow(symbol: "keyboard", text: "No peripherals yet")
          Button("Add your Magic Keyboard & Trackpad…") { openSettings(.peripherals) }
            .buttonStyle(.link).font(.caption)
        } else {
          ForEach(list) { p in
            PeripheralMiniRow(peripheral: p, tick: bt.refreshTick)
          }
        }
      }
    }
  }

  // MARK: Footer

  private var footer: some View {
    HStack {
      Button {
        openSettings(nil)
      } label: {
        Label("Settings", systemImage: "gearshape")
      }
      Spacer()
      Button {
        openSettings(.demo)
      } label: {
        Label("Demo", systemImage: settings.demoModeEnabled ? "video.fill" : "video")
          .foregroundStyle(settings.demoModeEnabled ? Theme.amber : .primary)
      }
      Spacer()
      Button {
        openSettings(.activity)
      } label: {
        Label("Log", systemImage: "list.bullet.rectangle")
      }
      Spacer()
      Button {
        NSApp.terminate(nil)
      } label: {
        Label("Quit", systemImage: "power")
      }
    }
    .buttonStyle(.borderless)
    .font(.callout)
    .padding(.horizontal, 16)
    .padding(.vertical, 10)
    .background(.bar)
  }
}

// MARK: - Peripheral row

private struct PeripheralMiniRow: View {
  let peripheral: BluetoothPeripheral
  let tick: Int
  @ObservedObject private var bt = BluetoothService.shared
  @ObservedObject private var demo = DemoMode.shared
  @ObservedObject private var diag = BluetoothDiagnosticsService.shared

  var body: some View {
    let connected = demo.isPeripheralConnected(peripheral)
    let busy = bt.busyIDs.contains(peripheral.id) || diag.testingPeripheralIDs.contains(peripheral.id)
    let t = diag.telemetry(for: peripheral)
    HStack(spacing: 10) {
      Image(systemName: peripheral.symbolName)
        .frame(width: 26, height: 26)
        .background(
          RoundedRectangle(cornerRadius: 7).fill(
            connected ? Theme.blue.opacity(0.15) : Color.primary.opacity(0.06))
        )
        .foregroundStyle(connected ? Theme.blue : .secondary)
      VStack(alignment: .leading, spacing: 1) {
        HStack(spacing: 5) {
          Text(demo.peripheralDisplayName(peripheral)).font(.callout.weight(.medium)).lineLimit(1)
          Image(systemName: t.isLinkEncrypted ? "lock.fill" : "shield.lefthalf.filled")
            .font(.system(size: 9))
            .foregroundStyle(t.encryptionColor)
            .help(t.encryptionBadgeText)
        }
        HStack(spacing: 5) {
          Text(peripheral.isEnabled ? (connected ? "Connected" : "Standby") : "Excluded from switching")
          if connected {
            Text("·")
            Text(t.encryptionBadgeText)
              .foregroundStyle(t.encryptionColor)
            if let rssi = t.rssi {
              Text("·")
              Text("\(rssi) dBm")
                .foregroundStyle(t.signalQuality.color)
            }
          }
          if let avgMs = t.stats.averageLatencyMs {
            Text("·")
            Text("\(t.stats.reliabilityPercent)% (\(avgMs) ms)")
          }
        }
        .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
      }
      Spacer()
      if busy {
        ProgressView().controlSize(.small)
      } else {
        Circle().fill(connected ? Theme.green : Color.secondary.opacity(0.4)).frame(width: 8)
      }
    }
    .opacity(peripheral.isEnabled ? 1 : 0.55)
  }
}

// MARK: - Animated arrows

struct FlowArrows: View {
  enum Direction { case left, right, both }
  let direction: Direction
  let animating: Bool
  @State private var phase: CGFloat = 0

  var body: some View {
    ZStack {
      Capsule().fill(Color.primary.opacity(0.06)).frame(height: 4)
      GeometryReader { geo in
        Circle()
          .fill(Theme.brandGradient)
          .frame(width: 10, height: 10)
          .offset(x: dotOffset(width: geo.size.width), y: geo.size.height / 2 - 5)
          .opacity(animating ? 1 : 0)
      }
      Image(systemName: symbol)
        .font(.system(size: 15, weight: .bold))
        .foregroundStyle(Theme.brandGradient)
        .padding(6)
        .background(Circle().fill(.background))
    }
    .frame(height: 28)
    .onAppear {
      withAnimation(.linear(duration: 1.1).repeatForever(autoreverses: false)) { phase = 1 }
    }
  }

  private var symbol: String {
    switch direction {
    case .left: return "chevron.left.2"
    case .right: return "chevron.right.2"
    case .both: return "arrow.left.arrow.right"
    }
  }

  private func dotOffset(width: CGFloat) -> CGFloat {
    let travel = width - 10
    switch direction {
    case .right, .both: return phase * travel
    case .left: return (1 - phase) * travel
    }
  }
}
