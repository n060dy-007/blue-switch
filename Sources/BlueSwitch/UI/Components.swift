import AppKit
import Carbon.HIToolbox
import SwiftUI

// MARK: - Theme

enum Theme {
  static let blue = Color(red: 0.16, green: 0.47, blue: 1.0)
  static let indigo = Color(red: 0.39, green: 0.33, blue: 0.98)
  static let cyan = Color(red: 0.17, green: 0.78, blue: 0.96)
  static let green = Color(red: 0.20, green: 0.80, blue: 0.48)
  static let amber = Color(red: 1.0, green: 0.70, blue: 0.20)
  static let red = Color(red: 1.0, green: 0.36, blue: 0.36)

  static let brandGradient = LinearGradient(
    colors: [cyan, blue, indigo], startPoint: .topLeading, endPoint: .bottomTrailing)

  static func paneGradient(_ c: Color) -> LinearGradient {
    LinearGradient(colors: [c.opacity(0.95), c.opacity(0.65)], startPoint: .top, endPoint: .bottom)
  }
}

// MARK: - Card

struct Card<Content: View>: View {
  var padding: CGFloat = 14
  @ViewBuilder var content: Content

  var body: some View {
    content
      .padding(padding)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(
        RoundedRectangle(cornerRadius: 14, style: .continuous)
          .fill(.regularMaterial)
      )
      .overlay(
        RoundedRectangle(cornerRadius: 14, style: .continuous)
          .strokeBorder(Color.primary.opacity(0.08))
      )
  }
}

// MARK: - Status Pill

struct StatusPill: View {
  let text: String
  let color: Color
  var pulsing = false
  @State private var pulse = false

  var body: some View {
    HStack(spacing: 6) {
      Circle()
        .fill(color)
        .frame(width: 7, height: 7)
        .scaleEffect(pulsing && pulse ? 1.4 : 1)
        .opacity(pulsing && pulse ? 0.5 : 1)
        .animation(
          pulsing ? .easeInOut(duration: 0.8).repeatForever(autoreverses: true) : .default,
          value: pulse)
      Text(text).font(.caption.weight(.semibold))
    }
    .padding(.horizontal, 9)
    .padding(.vertical, 4)
    .background(Capsule().fill(color.opacity(0.16)))
    .foregroundStyle(color)
    .onAppear { pulse = true }
  }
}

extension PeerReachability {
  var color: Color {
    switch self {
    case .online: return Theme.green
    case .offline: return Theme.red
    case .checking: return Theme.amber
    case .unknown: return .secondary
    }
  }
  var label: String {
    switch self {
    case .online: return "Online"
    case .offline: return "Offline"
    case .checking: return "Checking"
    case .unknown: return "Unknown"
    }
  }
}

extension PeripheralConnectionState {
  var color: Color {
    switch self {
    case .allConnected: return Theme.green
    case .allDisconnected: return .secondary
    case .partial: return Theme.amber
    case .none: return .secondary
    }
  }
}

// MARK: - Pane Header

struct PaneHeader: View {
  let pane: SettingsPane

  var body: some View {
    HStack(spacing: 14) {
      ZStack {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
          .fill(Theme.paneGradient(pane.tint))
          .frame(width: 46, height: 46)
          .shadow(color: pane.tint.opacity(0.35), radius: 8, y: 3)
        Image(systemName: pane.symbol)
          .font(.system(size: 21, weight: .semibold))
          .foregroundStyle(.white)
      }
      VStack(alignment: .leading, spacing: 2) {
        Text(pane.title).font(.title2.weight(.bold))
        Text(pane.subtitle).font(.callout).foregroundStyle(.secondary)
      }
      Spacer()
    }
    .padding(.horizontal, 24)
    .padding(.top, 20)
    .padding(.bottom, 4)
  }
}

// MARK: - Setting row helpers

/// Label with an explanatory caption, used inside Form rows.
struct SettingLabel: View {
  let title: String
  var caption: String? = nil

  var body: some View {
    VStack(alignment: .leading, spacing: 2) {
      Text(title)
      if let caption {
        Text(caption).font(.caption).foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
  }
}

/// Toggle with a caption.
struct SettingToggle: View {
  let title: String
  var caption: String? = nil
  @Binding var isOn: Bool

  var body: some View {
    Toggle(isOn: $isOn) { SettingLabel(title: title, caption: caption) }
      .toggleStyle(.switch)
  }
}

/// Numeric stepper row with value display.
struct SettingStepper<V: Strideable & Comparable>: View where V.Stride: ExpressibleByIntegerLiteral {
  let title: String
  var caption: String? = nil
  @Binding var value: V
  let range: ClosedRange<V>
  let step: V.Stride
  let format: (V) -> String

  var body: some View {
    HStack {
      SettingLabel(title: title, caption: caption)
      Spacer()
      Text(format(value))
        .monospacedDigit()
        .foregroundStyle(.secondary)
        .frame(minWidth: 56, alignment: .trailing)
      Stepper("", value: $value, in: range, step: step).labelsHidden()
    }
  }
}

/// Slider row for durations in seconds.
struct SettingSlider: View {
  let title: String
  var caption: String? = nil
  @Binding var value: Double
  let range: ClosedRange<Double>
  var step: Double = 0.1
  var unit: String = "s"

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack {
        SettingLabel(title: title, caption: caption)
        Spacer()
        Text(String(format: step < 1 ? "%.1f %@" : "%.0f %@", value, unit))
          .monospacedDigit()
          .foregroundStyle(.secondary)
      }
      Slider(value: $value, in: range, step: step)
        .tint(Theme.blue)
    }
  }
}

// MARK: - Buttons

struct GradientButtonStyle: ButtonStyle {
  var gradient: LinearGradient = Theme.brandGradient
  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .font(.headline)
      .foregroundStyle(.white)
      .padding(.vertical, 11)
      .frame(maxWidth: .infinity)
      .background(
        Capsule().fill(gradient)
          .shadow(color: Theme.blue.opacity(configuration.isPressed ? 0.2 : 0.4), radius: 10, y: 4)
      )
      .scaleEffect(configuration.isPressed ? 0.97 : 1)
      .animation(.spring(response: 0.25, dampingFraction: 0.7), value: configuration.isPressed)
  }
}

struct PillButtonStyle: ButtonStyle {
  var tint: Color = Theme.blue
  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .font(.callout.weight(.semibold))
      .padding(.vertical, 7)
      .padding(.horizontal, 12)
      .frame(maxWidth: .infinity)
      .background(Capsule().fill(tint.opacity(configuration.isPressed ? 0.28 : 0.15)))
      .foregroundStyle(tint)
      .contentShape(Capsule())
  }
}

// MARK: - Shortcut Recorder

/// Click to record a global keyboard shortcut. Esc cancels, Delete clears.
struct ShortcutRecorder: View {
  @Binding var combo: KeyCombo
  @State private var recording = false
  @State private var monitor: Any?

  var body: some View {
    HStack(spacing: 6) {
      Button(action: toggle) {
        Text(recording ? "Type shortcut…" : HotKeyManager.describe(combo))
          .font(.system(.body, design: .rounded).weight(.medium))
          .frame(minWidth: 120)
          .padding(.vertical, 4)
          .padding(.horizontal, 8)
          .background(
            RoundedRectangle(cornerRadius: 7)
              .fill(recording ? Theme.blue.opacity(0.18) : Color.primary.opacity(0.06))
          )
          .overlay(
            RoundedRectangle(cornerRadius: 7)
              .strokeBorder(recording ? Theme.blue : Color.primary.opacity(0.12))
          )
      }
      .buttonStyle(.plain)
      if !combo.isEmpty {
        Button {
          combo = .none
        } label: {
          Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .help("Clear shortcut")
      }
    }
    .onDisappear(perform: stop)
  }

  private func toggle() { recording ? stop() : start() }

  private func start() {
    recording = true
    monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
      let code = Int(event.keyCode)
      if code == kVK_Escape {
        stop()
        return nil
      }
      if code == kVK_Delete || code == kVK_ForwardDelete {
        combo = .none
        stop()
        return nil
      }
      let mods = event.modifierFlags.intersection([.command, .option, .control, .shift])
      let functionKeys: Set<Int> = [
        kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F5, kVK_F6, kVK_F7, kVK_F8, kVK_F9, kVK_F10,
        kVK_F11, kVK_F12, kVK_F13, kVK_F14, kVK_F15, kVK_F16, kVK_F17, kVK_F18, kVK_F19, kVK_F20,
      ]
      let isFunctionKey = functionKeys.contains(code)
      // Require a modifier unless it's a function key, to avoid hijacking normal typing.
      guard !mods.isEmpty || isFunctionKey else {
        NSSound.beep()
        return nil
      }
      combo = KeyCombo(keyCode: code, modifiers: Int(mods.rawValue))
      stop()
      return nil
    }
  }

  private func stop() {
    recording = false
    if let monitor { NSEvent.removeMonitor(monitor) }
    monitor = nil
  }
}

// MARK: - Empty state

/// Shown when macOS hasn't granted BlueSwitch Bluetooth access.
struct BluetoothPermissionBanner: View {
  @ObservedObject private var bt = BluetoothService.shared
  var compact = false

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      Label {
        Text("Bluetooth access: \(bt.authorizationText)").font(.headline)
      } icon: {
        Image(systemName: "exclamationmark.shield.fill").foregroundStyle(Theme.amber)
      }
      if !compact {
        Text(
          bt.authorization == .notDetermined
            ? "macOS hasn't asked yet. Click Request Access and choose Allow. Without it, BlueSwitch can't see your keyboard or trackpad."
            : "Turn on BlueSwitch in System Settings → Privacy & Security → Bluetooth, then come back here."
        )
        .font(.callout).foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
      }
      HStack {
        Button("Request Access") { bt.requestAccess() }
        Button("Open Bluetooth Privacy Settings") { bt.openPrivacySettings() }
        if !compact {
          Button("Re-check") { bt.refresh() }
        }
      }
      .controlSize(compact ? .small : .regular)
      if !compact && bt.authorization == .denied {
        Text("If BlueSwitch isn't listed, run this in Terminal and relaunch BlueSwitch:\ntccutil reset BluetoothAlways com.blueswitch.app")
          .font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
      }
    }
    .padding(.vertical, 4)
  }
}

/// Shown when auto-clicking Bluetooth connection prompts is enabled but Accessibility permission isn't granted.
struct AccessibilityPermissionBanner: View {
  @ObservedObject private var clicker = BluetoothAutoClicker.shared
  var compact = false

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      Label {
        Text(
          "Accessibility access required for auto-clicking Bluetooth prompts"
        ).font(.headline)
      } icon: {
        Image(systemName: "hand.tap.fill").foregroundStyle(Theme.amber)
      }
      if !compact {
        Text(
          "To automatically click \"Connect\" on macOS Bluetooth connection requests (so peripherals can switch when you don't have a mouse connected), enable BlueSwitch in System Settings → Privacy & Security → Accessibility."
        )
        .font(.callout).foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
      }
      HStack {
        Button("Request Permission") { clicker.requestPermission() }
        Button("Open Accessibility Settings") { clicker.openAccessibilitySettings() }
        Button("Re-check") { clicker.refreshPermission() }
      }
      .controlSize(compact ? .small : .regular)
    }
    .padding(.vertical, 4)
  }
}

struct EmptyStateRow: View {
  let symbol: String
  let text: String
  var body: some View {
    HStack(spacing: 10) {
      Image(systemName: symbol).foregroundStyle(.tertiary)
      Text(text).foregroundStyle(.secondary)
    }
    .padding(.vertical, 4)
  }
}
