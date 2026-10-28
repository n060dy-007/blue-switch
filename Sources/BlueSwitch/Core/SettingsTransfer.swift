import AppKit
import Foundation
import UniformTypeIdentifiers

/// Export / import of all settings, peripherals and peers as a single JSON file.
enum SettingsTransfer {
  static func export() {
    let panel = NSSavePanel()
    panel.allowedContentTypes = [.json]
    panel.nameFieldStringValue = "BlueSwitch-Settings.json"
    NSApp.activate(ignoringOtherApps: true)
    guard panel.runModal() == .OK, let url = panel.url else { return }

    var root: [String: Any] = [
      "format": "blueswitch-settings",
      "version": 1,
      "settings": AppSettings.shared.exportDictionary(),
    ]
    if let d = BluetoothService.shared.exportData(),
      let j = try? JSONSerialization.jsonObject(with: d)
    {
      root["peripherals"] = j
    }
    if let d = NetworkService.shared.exportData(),
      let j = try? JSONSerialization.jsonObject(with: d)
    {
      root["peers"] = j
    }
    do {
      let data = try JSONSerialization.data(
        withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
      try data.write(to: url)
      Log.info("Exported settings to \(url.path)", "Settings")
    } catch {
      Log.error("Export failed: \(error.localizedDescription)", "Settings")
    }
  }

  static func `import`() {
    let panel = NSOpenPanel()
    panel.allowedContentTypes = [.json]
    panel.allowsMultipleSelection = false
    NSApp.activate(ignoringOtherApps: true)
    guard panel.runModal() == .OK, let url = panel.url else { return }
    do {
      let data = try Data(contentsOf: url)
      guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
        root["format"] as? String == "blueswitch-settings"
      else {
        Log.error("Not a BlueSwitch settings file", "Settings")
        return
      }
      let valid = Set(AppSettings.Key.allCases.map(\.rawValue))
      if let s = root["settings"] as? [String: Any] {
        for (k, v) in s where valid.contains(k) { UserDefaults.standard.set(v, forKey: k) }
      }
      if let p = root["peripherals"],
        let d = try? JSONSerialization.data(withJSONObject: p)
      {
        UserDefaults.standard.set(d, forKey: "peripherals")
      }
      if let p = root["peers"], let d = try? JSONSerialization.data(withJSONObject: p) {
        UserDefaults.standard.set(d, forKey: "peers")
      }
      Log.info("Imported settings; relaunching", "Settings")
      relaunch()
    } catch {
      Log.error("Import failed: \(error.localizedDescription)", "Settings")
    }
  }

  static func relaunch() {
    UserDefaults.standard.synchronize()
    let path = Bundle.main.bundlePath
    let task = Process()
    task.executableURL = URL(fileURLWithPath: "/bin/sh")
    task.arguments = ["-c", "sleep 1; /usr/bin/open \"\(path)\""]
    try? task.run()
    NSApp.terminate(nil)
  }
}
