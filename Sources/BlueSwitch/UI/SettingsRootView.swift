import SwiftUI

enum SettingsPane: String, CaseIterable, Identifiable {
  case general, switching, peripherals, devices, network, notifications, shortcuts, advanced
  case activity, about

  var id: String { rawValue }

  var title: String {
    switch self {
    case .general: return "General"
    case .switching: return "Switching"
    case .peripherals: return "Peripherals"
    case .devices: return "Macs"
    case .network: return "Network"
    case .notifications: return "Notifications"
    case .shortcuts: return "Shortcuts"
    case .advanced: return "Advanced"
    case .activity: return "Activity Log"
    case .about: return "About"
    }
  }

  var subtitle: String {
    switch self {
    case .general: return "Startup, menu bar, appearance and updates"
    case .switching: return "How peripherals move between Macs"
    case .peripherals: return "Magic Keyboard, Trackpad and other Bluetooth devices"
    case .devices: return "Other Macs running BlueSwitch"
    case .network: return "Discovery, ports, timeouts and security"
    case .notifications: return "Which events alert you, and how"
    case .shortcuts: return "System-wide keyboard shortcuts"
    case .advanced: return "Logging, diagnostics, backup and reset"
    case .activity: return "Live log of what BlueSwitch is doing"
    case .about: return "Version, credits and license"
    }
  }

  var symbol: String {
    switch self {
    case .general: return "gearshape.fill"
    case .switching: return "arrow.left.arrow.right"
    case .peripherals: return "keyboard"
    case .devices: return "desktopcomputer"
    case .network: return "network"
    case .notifications: return "bell.badge.fill"
    case .shortcuts: return "command"
    case .advanced: return "wrench.and.screwdriver.fill"
    case .activity: return "list.bullet.rectangle.fill"
    case .about: return "info.circle.fill"
    }
  }

  var tint: Color {
    switch self {
    case .general: return .gray
    case .switching: return Theme.blue
    case .peripherals: return Theme.indigo
    case .devices: return Theme.cyan
    case .network: return Theme.green
    case .notifications: return Theme.red
    case .shortcuts: return .purple
    case .advanced: return .orange
    case .activity: return .teal
    case .about: return Theme.blue
    }
  }

  static let groups: [(String, [SettingsPane])] = [
    ("Setup", [.peripherals, .devices]),
    ("Preferences", [.general, .switching, .network, .notifications, .shortcuts]),
    ("Support", [.advanced, .activity, .about]),
  ]
}

final class SettingsNavigation: ObservableObject {
  static let shared = SettingsNavigation()
  @Published var selection: SettingsPane = .general
}

struct SettingsRootView: View {
  @ObservedObject private var nav = SettingsNavigation.shared
  @ObservedObject private var bt = BluetoothService.shared
  @ObservedObject private var net = NetworkService.shared
  @ObservedObject private var demo = DemoMode.shared

  var body: some View {
    NavigationSplitView {
      List(selection: Binding(get: { nav.selection }, set: { if let v = $0 { nav.selection = v } })) {
        sidebarHeader
          .listRowSeparator(.hidden)
        ForEach(SettingsPane.groups, id: \.0) { group in
          Section(group.0) {
            ForEach(group.1) { pane in
              NavigationLink(value: pane) { sidebarRow(pane) }
            }
          }
        }
      }
      .listStyle(.sidebar)
      .navigationSplitViewColumnWidth(min: 210, ideal: 230, max: 280)
    } detail: {
      detail(for: nav.selection)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
  }

  private var sidebarHeader: some View {
    HStack(spacing: 10) {
      ZStack {
        RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Theme.brandGradient)
          .frame(width: 34, height: 34)
        Image(systemName: "staroflife.fill").foregroundStyle(.white).font(.system(size: 16, weight: .bold))
      }
      VStack(alignment: .leading, spacing: 0) {
        HStack(spacing: 5) {
          Text("BlueSwitch").font(.headline)
          if demo.isEnabled {
            Text("DEMO")
              .font(.system(size: 8, weight: .black))
              .padding(.horizontal, 4).padding(.vertical, 1)
              .background(Capsule().fill(Theme.amber))
              .foregroundStyle(.black)
          }
        }
        Text(demo.effectiveConnectionState.label).font(.caption)
          .foregroundStyle(demo.effectiveConnectionState.color)
      }
    }
    .padding(.vertical, 6)
  }

  private func sidebarRow(_ pane: SettingsPane) -> some View {
    HStack(spacing: 8) {
      Image(systemName: pane.symbol)
        .font(.system(size: 11, weight: .semibold))
        .foregroundStyle(.white)
        .frame(width: 22, height: 22)
        .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Theme.paneGradient(pane.tint)))
      Text(pane.title)
      Spacer()
      if pane == .peripherals, !demo.effectivePeripherals.isEmpty {
        badge("\(demo.effectivePeripherals.count)")
      } else if pane == .devices, !demo.effectivePeers.isEmpty {
        badge("\(demo.effectivePeers.count)")
      }
    }
  }

  private func badge(_ text: String) -> some View {
    Text(text).font(.caption2.weight(.bold)).padding(.horizontal, 6).padding(.vertical, 1)
      .background(Capsule().fill(Color.primary.opacity(0.1)))
  }

  @ViewBuilder private func detail(for pane: SettingsPane) -> some View {
    switch pane {
    case .general: GeneralPane()
    case .switching: SwitchingPane()
    case .peripherals: PeripheralsPane()
    case .devices: DevicesPane()
    case .network: NetworkPane()
    case .notifications: NotificationsPane()
    case .shortcuts: ShortcutsPane()
    case .advanced: AdvancedPane()
    case .activity: ActivityPane()
    case .about: AboutPane()
    }
  }
}

/// Standard pane layout: gradient header + grouped form.
struct PaneContainer<Content: View>: View {
  let pane: SettingsPane
  @ViewBuilder var content: Content

  var body: some View {
    VStack(spacing: 0) {
      PaneHeader(pane: pane)
      Form { content }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
    }
  }
}
