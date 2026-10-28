import AppKit
import SwiftUI

// MARK: - Activity Log

struct ActivityPane: View {
  @ObservedObject private var log = Log.shared
  @ObservedObject private var s = AppSettings.shared
  @State private var filter: LogLevel = .debug
  @State private var search = ""

  private var filtered: [LogEntry] {
    log.entries.reversed().filter { e in
      e.level >= filter
        && (search.isEmpty || e.message.localizedCaseInsensitiveContains(search)
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
          log.clear()
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
        Text("Recording level: \(s.logLevel.label) · change in Advanced").font(.caption).foregroundStyle(.secondary)
        Spacer()
        Text("\(log.entries.count) entries").font(.caption).foregroundStyle(.secondary)
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
      Text(e.message).font(.callout).textSelection(.enabled)
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
