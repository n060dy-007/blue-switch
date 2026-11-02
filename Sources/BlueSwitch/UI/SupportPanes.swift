import AppKit
import SwiftUI

// MARK: - Activity Log

struct ActivityPane: View {
  @ObservedObject private var log = Log.shared
  @ObservedObject private var s = AppSettings.shared
  @ObservedObject private var demo = DemoMode.shared
  @State private var filter: LogLevel = .debug
  @State private var search = ""

  private var filtered: [LogEntry] {
    log.visibleEntries.reversed().filter { e in
      e.level >= filter
        && (search.isEmpty || e.displayMessage.localizedCaseInsensitiveContains(search)
          || e.category.localizedCaseInsensitiveContains(search))
    }
  }

  var body: some View {
    VStack(spacing: 0) {
      PaneHeader(pane: .activity)
      HStack(spacing: 10) {
        Picker("Show", selection: $filter) {
          ForEach(LogLevel.allCases) { Text($0.label + "+").tag($0) }
        }
        .frame(width: 150)
        TextField("Search", text: $search).textFieldStyle(.roundedBorder)
        Button {
          NSPasteboard.general.clearContents()
          NSPasteboard.general.setString(log.exportText, forType: .string)
        } label: {
          Label("Copy", systemImage: "doc.on.doc")
        }
        Button(action: save) { Label("Save…", systemImage: "square.and.arrow.down") }
        Button(role: .destructive) {
          log.clearVisible()
        } label: {
          Label("Clear", systemImage: "trash")
        }
      }
      .padding(.horizontal, 24)
      .padding(.vertical, 10)

      Card(padding: 0) {
        if filtered.isEmpty {
          VStack {
            Spacer()
            EmptyStateRow(symbol: "text.alignleft", text: "No log entries")
            Spacer()
          }
          .frame(maxWidth: .infinity)
        } else {
          ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
              ForEach(filtered) { e in
                row(e)
                Divider().opacity(0.4)
              }
            }
          }
        }
      }
      .padding(.horizontal, 24)
      .padding(.bottom, 20)

      HStack {
        Text(
          s.demoModeEnabled
            ? "Demo Activity Log (isolated — real session logs hidden)"
            : "Recording level: \(s.logLevel.label) · change in Advanced"
        )
        .font(.caption).foregroundStyle(.secondary)
        Spacer()
        Text("\(log.visibleEntries.count) entries").font(.caption).foregroundStyle(.secondary)
      }
      .padding(.horizontal, 28).padding(.bottom, 14)
    }
  }

  private func row(_ e: LogEntry) -> some View {
    HStack(alignment: .firstTextBaseline, spacing: 10) {
      Text(e.date, format: .dateTime.hour().minute().second())
        .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
        .frame(width: 70, alignment: .leading)
      Text(e.level.label.uppercased())
        .font(.system(size: 9, weight: .heavy))
        .padding(.horizontal, 5).padding(.vertical, 2)
        .background(Capsule().fill(color(e.level).opacity(0.18)))
        .foregroundStyle(color(e.level))
        .frame(width: 62, alignment: .leading)
      Text(e.category).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
        .frame(width: 70, alignment: .leading)
      Text(e.displayMessage).font(.callout).textSelection(.enabled)
      Spacer(minLength: 0)
    }
    .padding(.horizontal, 12).padding(.vertical, 6)
  }

  private func color(_ l: LogLevel) -> Color {
    switch l {
    case .debug: return .secondary
    case .info: return Theme.blue
    case .warning: return Theme.amber
    case .error: return Theme.red
    }
  }

  private func save() {
    let panel = NSSavePanel()
    panel.nameFieldStringValue = "BlueSwitch-Log.txt"
    guard panel.runModal() == .OK, let url = panel.url else { return }
    try? log.exportText.write(to: url, atomically: true, encoding: .utf8)
  }
}

// MARK: - About

struct AboutPane: View {
  @State private var glow = false

  var body: some View {
    VStack(spacing: 0) {
      PaneHeader(pane: .about)
      ScrollView {
        VStack(spacing: 18) {
          ZStack {
            Circle().fill(Theme.brandGradient).frame(width: 120, height: 120)
              .blur(radius: glow ? 28 : 18).opacity(0.6)
            RoundedRectangle(cornerRadius: 28, style: .continuous)
              .fill(Theme.brandGradient)
              .frame(width: 96, height: 96)
              .shadow(color: Theme.blue.opacity(0.5), radius: 14, y: 6)
            Image(systemName: "staroflife.fill")
              .font(.system(size: 44, weight: .bold))
              .foregroundStyle(.white)
          }
          .padding(.top, 20)
          .onAppear {
            withAnimation(.easeInOut(duration: 2).repeatForever(autoreverses: true)) { glow = true }
          }

          VStack(spacing: 4) {
            Text("BlueSwitch").font(.largeTitle.weight(.heavy))
            Text("Version \(AppInfo.version) (\(AppInfo.build))").foregroundStyle(.secondary)
          }

          Text("A software KVM for your Magic Keyboard, Magic Trackpad and Magic Mouse. Switch Bluetooth peripherals between Macs with one click or keystroke — no cables or hardware switch.")
            .multilineTextAlignment(.center)
            .foregroundStyle(.secondary)
            .frame(maxWidth: 460)

          Card {
            VStack(alignment: .leading, spacing: 10) {
              Label("Based on Blue Switch by Hoshimura Yuto", systemImage: "heart.fill")
                .foregroundStyle(Theme.red)
              Text("BlueSwitch builds on the open-source Blue Switch project, adding a full configuration UI, global shortcuts, a framed network protocol, and more.")
                .font(.callout).foregroundStyle(.secondary)
              HStack {
                Link("Upstream project", destination: URL(string: "https://github.com/HoshimuraYuto/blue-switch")!)
                Spacer()
                Link("License", destination: URL(string: "https://github.com/HoshimuraYuto/blue-switch/blob/main/LICENSE")!)
              }
              .font(.callout)
            }
          }
          .frame(maxWidth: 480)

          Text("BlueSwitch must be installed and running on every Mac you switch between.")
            .font(.caption).foregroundStyle(.tertiary)
        }
        .padding(24)
        .frame(maxWidth: .infinity)
      }
    }
  }
}

// MARK: - Demo Mode

struct DemoPane: View {
  @ObservedObject private var s = AppSettings.shared
  @ObservedObject private var demo = DemoMode.shared
  @ObservedObject private var diag = BluetoothDiagnosticsService.shared
  @ObservedObject private var sec = SecurityMonitor.shared
  @ObservedObject private var coordinator = SwitchCoordinator.shared

  var body: some View {
    PaneContainer(pane: .demo) {
      Section {
        SettingToggle(
          title: "Enable Demo Mode (Privacy Redaction & Showcase)",
          caption:
            "Immediately masks your real Mac name, Bonjour hostnames, IPv4 addresses, Bluetooth MACs, pairing keys, and macOS username across the Dashboard, Menu Bar, Settings, and Activity Log.",
          isOn: $s.demoModeEnabled
        )
        SettingToggle(
          title: "Simulate live peripheral switching (Keep real keyboard & mouse connected)",
          caption:
            "Animates peripheral handoffs, status indicators, and audio mute rules live on camera without disconnecting your physical keyboard, trackpad, or mouse.",
          isOn: $s.demoSimulateSwitching
        )
        .disabled(!s.demoModeEnabled)
      } header: {
        HStack {
          Text("Demo Mode Status")
          Spacer()
          StatusPill(
            text: s.demoModeEnabled
              ? (demo.isAutoPlaying ? "Auto-Playing Showcase" : "Demo Mode Active")
              : "Off (Live Hardware)",
            color: s.demoModeEnabled ? Theme.amber : .secondary,
            pulsing: demo.isAutoPlaying
          )
        }
      }

      Section("Scenario Presets & Alias Names") {
        Picker("Showcase Scenario", selection: $s.demoScenario) {
          ForEach(DemoScenario.allCases) { sc in
            Text(sc.label).tag(sc)
          }
        }
        .disabled(!s.demoModeEnabled)

        HStack {
          SettingLabel(
            title: "This Mac demo name",
            caption: "Displayed instead of your real computer name when Demo Mode is on."
          )
          Spacer()
          TextField("Mac Studio", text: $s.demoLocalMacName)
            .textFieldStyle(.roundedBorder)
            .frame(width: 220)
        }
        .disabled(!s.demoModeEnabled)

        HStack {
          SettingLabel(
            title: "Target Mac demo name",
            caption: "Displayed as the primary target Mac in the switcher and menu bar."
          )
          Spacer()
          TextField("MacBook Pro 16\"", text: $s.demoPeerMacName)
            .textFieldStyle(.roundedBorder)
            .frame(width: 220)
        }
        .disabled(!s.demoModeEnabled)
      }

      Section("Hands-Free Auto-Play & Live Demo Actions") {
        HStack {
          VStack(alignment: .leading, spacing: 2) {
            Text("Hands-Free Auto-Play Demo Loop").font(.body.weight(.medium))
            Text(
              "Automatically alternates peripheral switches between Macs every few seconds — ideal for recording product walkthroughs."
            )
            .font(.caption).foregroundStyle(.secondary)
          }
          Spacer()
          Button {
            demo.toggleAutoPlay()
          } label: {
            Label(
              demo.isAutoPlaying ? "Stop Auto-Play" : "Start Auto-Play",
              systemImage: demo.isAutoPlaying ? "stop.fill" : "play.fill"
            )
          }
          .buttonStyle(.borderedProminent)
          .tint(demo.isAutoPlaying ? Theme.red : Theme.amber)
        }

        SettingSlider(
          title: "Auto-play switch interval",
          caption: "Seconds between simulated peripheral handoffs during Auto-Play.",
          value: $s.demoAutoPlayInterval,
          range: 3...20,
          step: 1
        )

        HStack(spacing: 10) {
          Button {
            if !s.demoModeEnabled { s.demoModeEnabled = true }
            coordinator.switchDevices()
          } label: {
            Label("Simulate Switch", systemImage: "arrow.left.arrow.right")
          }
          .disabled(coordinator.phase.isWorking)

          Button {
            if !s.demoModeEnabled { s.demoModeEnabled = true }
            diag.runFullDiagnosticSuite()
            SettingsNavigation.shared.selection = .peripherals
          } label: {
            Label("Run Diagnostic Demo", systemImage: "stethoscope")
          }

          Button {
            if !s.demoModeEnabled { s.demoModeEnabled = true }
            sec.triggerSimulatedIncident()
          } label: {
            Label("Simulate Security Alert", systemImage: "exclamationmark.shield")
          }

          Button {
            if !s.demoModeEnabled { s.demoModeEnabled = true }
            demo.populateSampleLogs()
          } label: {
            Label("Add Sample Logs", systemImage: "text.append")
          }

          Spacer()

          Button("Reset Demo") {
            demo.resetDemoState()
          }
        }
      }

      Section("Active Privacy Redaction Checklist") {
        redactionRow("Local Computer & Bonjour Name", "Shown as \"\(demo.localMacDisplayName)\"")
        redactionRow("Peer Mac Names & IPv4 Hosts", "Shown as \"\(s.demoPeerMacName)\" · 10.0.1.24:54820")
        redactionRow("Bluetooth Peripheral & HCI MACs", "Masked as XX:XX:XX:XX:8A:1F (owner prefix stripped)")
        redactionRow("Filesystem Paths & Audit Vault", "Isolated synthetic records · ~/Library/Application Support/BlueSwitch/SecurityAudit/…")
        redactionRow("Network Pairing Key & Repo Feed", "Locked as •••••••••••• · demo-org/blue-switch")
      }
    }
  }

  private func redactionRow(_ title: String, _ preview: String) -> some View {
    HStack {
      Label(title, systemImage: "checkmark.shield.fill")
        .foregroundStyle(s.demoModeEnabled ? Theme.green : .secondary)
      Spacer()
      Text(preview)
        .font(.caption.monospaced())
        .foregroundStyle(.secondary)
    }
  }
}

// MARK: - Security Logs (Encrypted & Hash-Chained Connection Audit Vault)

struct SecurityLogsPane: View {
  @ObservedObject private var vault = SecureAuditVault.shared
  @ObservedObject private var s = AppSettings.shared
  @ObservedObject private var demo = DemoMode.shared

  @State private var selectedType: ConnectionAuditType? = nil
  @State private var minSeverity: LogLevel = .debug
  @State private var search = ""

  private var filteredRecords: [ConnectionAuditRecord] {
    vault.visibleRecords.reversed().filter { r in
      let matchesType = (selectedType == nil || r.type == selectedType)
      let matchesLevel = (r.severity >= minSeverity)
      let matchesSearch: Bool
      if search.isEmpty {
        matchesSearch = true
      } else {
        matchesSearch =
          r.action.localizedCaseInsensitiveContains(search)
          || r.subject.localizedCaseInsensitiveContains(search)
          || r.endpoint.localizedCaseInsensitiveContains(search)
          || r.cipher.localizedCaseInsensitiveContains(search)
          || r.details.localizedCaseInsensitiveContains(search)
      }
      return matchesType && matchesLevel && matchesSearch
    }
  }

  var body: some View {
    VStack(spacing: 0) {
      PaneHeader(pane: .securityLogs)

      vaultPostureCard
        .padding(.horizontal, 24)
        .padding(.top, 10)

      filterToolbar
        .padding(.horizontal, 24)
        .padding(.vertical, 10)

      Card(padding: 0) {
        if filteredRecords.isEmpty {
          VStack {
            Spacer()
            EmptyStateRow(
              symbol: "lock.doc",
              text: "No matching connection security records"
            )
            Spacer()
          }
          .frame(maxWidth: .infinity)
        } else {
          ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
              ForEach(filteredRecords) { rec in
                auditRow(rec)
                Divider().opacity(0.4)
              }
            }
          }
        }
      }
      .padding(.horizontal, 24)
      .padding(.bottom, 12)

      footerBar
        .padding(.horizontal, 28)
        .padding(.bottom, 14)
    }
  }

  private var vaultPostureCard: some View {
    let check = vault.effectiveVerification
    return Card {
      VStack(alignment: .leading, spacing: 10) {
        HStack(spacing: 10) {
          Label(
            check.isValid
              ? "Cryptographic Hash Chain Intact"
              : "Vault Tamper / Integrity Alert",
            systemImage: check.isValid ? "checkmark.seal.fill" : "exclamationmark.octagon.fill"
          )
          .font(.headline)
          .foregroundStyle(check.isValid ? Theme.green : Theme.red)

          Spacer()

          StatusPill(
            text: s.demoModeEnabled
              ? "Demo Isolated Vault"
              : (check.isValid ? "AES-256-GCM + HMAC Verified" : "Integrity Mismatch"),
            color: s.demoModeEnabled ? Theme.amber : (check.isValid ? Theme.green : Theme.red)
          )
        }

        Text(check.summaryText)
          .font(.caption)
          .foregroundStyle(.secondary)

        HStack(spacing: 8) {
          postureBadge("AES-256-GCM + AAD", symbol: "lock.fill", color: Theme.green)
          postureBadge("HMAC-SHA256 Chain", symbol: "link", color: Theme.blue)
          postureBadge(
            s.demoModeEnabled
              ? "macOS Keychain (ThisDeviceOnly)"
              : vault.keyStorageBackend,
            symbol: "key.fill",
            color: Theme.indigo
          )
          postureBadge("0700 / 0600 · O_NOFOLLOW · No-Backup", symbol: "externaldrive.badge.checkmark", color: .teal)
        }

        HStack(spacing: 8) {
          Text(vault.displayVaultPath)
            .font(.caption2.monospaced())
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .truncationMode(.middle)

          Spacer()

          Button {
            vault.verifyChainNow()
          } label: {
            Label("Verify Chain", systemImage: "checkmark.shield")
          }
          .controlSize(.small)

          Button {
            vault.rotateNow()
          } label: {
            Label("Rotate Segment", systemImage: "arrow.triangle.2.circlepath")
          }
          .controlSize(.small)

          Button {
            vault.exportReport(redactPersonalInfo: true)
          } label: {
            Label("Export Redacted…", systemImage: "eye.slash")
          }
          .controlSize(.small)

          Button {
            vault.exportReport(redactPersonalInfo: false)
          } label: {
            Label("Export Full…", systemImage: "square.and.arrow.down")
          }
          .controlSize(.small)
          .disabled(s.demoModeEnabled)

          Button("Reveal") {
            NSWorkspace.shared.selectFile(vault.vaultFilePath, inFileViewerRootedAtPath: "")
          }
          .controlSize(.small)
          .disabled(s.demoModeEnabled)
        }
      }
    }
  }

  private func postureBadge(_ text: String, symbol: String, color: Color) -> some View {
    HStack(spacing: 4) {
      Image(systemName: symbol).font(.system(size: 9, weight: .bold))
      Text(text).font(.system(size: 10, weight: .semibold)).lineLimit(1)
    }
    .padding(.horizontal, 7).padding(.vertical, 3)
    .background(Capsule().fill(color.opacity(0.14)))
    .foregroundStyle(color)
  }

  private var filterToolbar: some View {
    HStack(spacing: 10) {
      Picker("Channel", selection: $selectedType) {
        Text("All Connections").tag(ConnectionAuditType?.none)
        Divider()
        ForEach(ConnectionAuditType.allCases) { t in
          Text(t.label).tag(ConnectionAuditType?.some(t))
        }
      }
      .frame(width: 195)

      Picker("Level", selection: $minSeverity) {
        ForEach(LogLevel.allCases) { lvl in
          Text(lvl.label + "+").tag(lvl)
        }
      }
      .frame(width: 125)

      TextField("Filter by peer, IP, MAC, cipher, or action…", text: $search)
        .textFieldStyle(.roundedBorder)
    }
  }

  private func auditRow(_ r: ConnectionAuditRecord) -> some View {
    let displaySubject = s.demoModeEnabled ? demo.sanitizeLog(r.subject) : r.subject
    let displayEndpoint = s.demoModeEnabled ? demo.sanitizeLog(r.endpoint) : r.endpoint
    let displayDetails = s.demoModeEnabled ? demo.sanitizeLog(r.details) : r.details

    return VStack(alignment: .leading, spacing: 4) {
      HStack(alignment: .firstTextBaseline, spacing: 8) {
        Text("#\(r.sequence)")
          .font(.caption2.monospaced().weight(.bold))
          .foregroundStyle(.secondary)
          .frame(width: 42, alignment: .leading)

        Text(r.timestamp, format: .dateTime.hour().minute().second())
          .font(.caption.monospacedDigit())
          .foregroundStyle(.secondary)
          .frame(width: 68, alignment: .leading)

        HStack(spacing: 4) {
          Image(systemName: r.type.symbol).font(.system(size: 9))
          Text(r.type.label).font(.system(size: 9, weight: .heavy))
        }
        .padding(.horizontal, 6).padding(.vertical, 2)
        .background(Capsule().fill(r.type.tint.opacity(0.16)))
        .foregroundStyle(r.type.tint)

        Text(r.outcome.label.uppercased())
          .font(.system(size: 8.5, weight: .black))
          .padding(.horizontal, 5).padding(.vertical, 2)
          .background(Capsule().fill(r.outcome.color.opacity(0.16)))
          .foregroundStyle(r.outcome.color)

        Text(displaySubject)
          .font(.callout.weight(.semibold))
          .lineLimit(1)

        Text("·")
          .foregroundStyle(.tertiary)

        Text(displayEndpoint)
          .font(.caption.monospaced())
          .foregroundStyle(.secondary)
          .lineLimit(1)

        Spacer(minLength: 4)

        if let ms = r.latencyMs {
          Text("\(ms) ms")
            .font(.caption2.monospacedDigit())
            .foregroundStyle(.secondary)
        }

        Text(r.cipher)
          .font(.system(size: 9.5, weight: .medium, design: .monospaced))
          .padding(.horizontal, 6).padding(.vertical, 2)
          .background(RoundedRectangle(cornerRadius: 4).fill(Color.primary.opacity(0.06)))
          .foregroundStyle(.secondary)
      }

      HStack(spacing: 8) {
        Text(r.action)
          .font(.caption2.monospaced())
          .foregroundStyle(.tertiary)
        Text("—")
          .font(.caption2)
          .foregroundStyle(.tertiary)
        Text(displayDetails)
          .font(.caption)
          .foregroundStyle(.secondary)
          .textSelection(.enabled)
        Spacer(minLength: 4)
        Text("chain:\(String(r.entryHash.prefix(12)))…")
          .font(.system(size: 9, design: .monospaced))
          .foregroundStyle(.tertiary)
      }
      .padding(.leading, 42)
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 7)
  }

  private var footerBar: some View {
    let sizeKB = String(format: "%.1f KB", Double(s.demoModeEnabled ? 18_432 : vault.activeVaultBytes) / 1024.0)
    let archives = s.demoModeEnabled ? 1 : vault.archiveCount
    return HStack {
      Text(
        s.demoModeEnabled
          ? "Demo Mode: Showing isolated synthetic connection records (real encrypted vault hidden)"
          : "Active vault: \(sizeKB) · \(archives) read-only archive(s) (max 10 MB × 5, auto-rotated)"
      )
      .font(.caption)
      .foregroundStyle(.secondary)
      Spacer()
      Text("\(filteredRecords.count) / \(vault.visibleRecords.count) record(s)")
        .font(.caption)
        .foregroundStyle(.secondary)
    }
  }
}
