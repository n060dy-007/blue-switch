import AppKit
import Carbon.HIToolbox

/// System-wide hotkeys via Carbon `RegisterEventHotKey` (no Accessibility permission needed).
final class HotKeyManager {
  static let shared = HotKeyManager()

  enum Action: UInt32, CaseIterable {
    case switchDevices = 1, sendToPeer, takeFromPeer, muteMic, muteSpeakers
  }

  var handler: ((Action) -> Void)?
  private var refs: [Action: EventHotKeyRef] = [:]
  private var eventHandler: EventHandlerRef?

  private init() {}

  func reload() {
    unregisterAll()
    let s = AppSettings.shared
    guard s.hotkeysEnabled else { return }
    installHandlerIfNeeded()
    register(s.hotkeySwitch, for: .switchDevices)
    register(s.hotkeySendToPeer, for: .sendToPeer)
    register(s.hotkeyTakeFromPeer, for: .takeFromPeer)
    register(s.hotkeyMuteMic, for: .muteMic)
    register(s.hotkeyMuteSpeakers, for: .muteSpeakers)
  }

  private func installHandlerIfNeeded() {
    guard eventHandler == nil else { return }
    var spec = EventTypeSpec(
      eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
    InstallEventHandler(
      GetApplicationEventTarget(),
      { _, event, _ -> OSStatus in
        var hk = EventHotKeyID()
        GetEventParameter(
          event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
          MemoryLayout<EventHotKeyID>.size, nil, &hk)
        if let action = HotKeyManager.Action(rawValue: hk.id) {
          DispatchQueue.main.async { HotKeyManager.shared.handler?(action) }
        }
        return noErr
      }, 1, &spec, nil, &eventHandler)
  }

  private func register(_ combo: KeyCombo, for action: Action) {
    guard !combo.isEmpty else { return }
    var ref: EventHotKeyRef?
    let id = EventHotKeyID(signature: OSType(0x4253_5754), id: action.rawValue)  // 'BSWT'
    let status = RegisterEventHotKey(
      UInt32(combo.keyCode), Self.carbonModifiers(combo.modifiers), id,
      GetApplicationEventTarget(), 0, &ref)
    if status == noErr, let ref {
      refs[action] = ref
      Log.debug("Registered hotkey \(Self.describe(combo)) for \(action)", "Hotkey")
    } else {
      Log.warn("Could not register hotkey \(Self.describe(combo)) (in use?)", "Hotkey")
    }
  }

  private func unregisterAll() {
    refs.values.forEach { UnregisterEventHotKey($0) }
    refs.removeAll()
  }

  static func carbonModifiers(_ cocoa: Int) -> UInt32 {
    let f = NSEvent.ModifierFlags(rawValue: UInt(cocoa))
    var m: UInt32 = 0
    if f.contains(.command) { m |= UInt32(cmdKey) }
    if f.contains(.option) { m |= UInt32(optionKey) }
    if f.contains(.control) { m |= UInt32(controlKey) }
    if f.contains(.shift) { m |= UInt32(shiftKey) }
    return m
  }

  static func describe(_ combo: KeyCombo) -> String {
    guard !combo.isEmpty else { return "None" }
    let f = NSEvent.ModifierFlags(rawValue: UInt(combo.modifiers))
    var s = ""
    if f.contains(.control) { s += "⌃" }
    if f.contains(.option) { s += "⌥" }
    if f.contains(.shift) { s += "⇧" }
    if f.contains(.command) { s += "⌘" }
    return s + keyName(combo.keyCode)
  }

  private static func keyName(_ code: Int) -> String {
    let special: [Int: String] = [
      kVK_Return: "↩", kVK_Tab: "⇥", kVK_Space: "Space", kVK_Delete: "⌫", kVK_Escape: "⎋",
      kVK_LeftArrow: "←", kVK_RightArrow: "→", kVK_UpArrow: "↑", kVK_DownArrow: "↓",
      kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5", kVK_F6: "F6",
      kVK_F7: "F7", kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12",
      kVK_F13: "F13", kVK_F14: "F14", kVK_F15: "F15", kVK_Home: "↖", kVK_End: "↘",
      kVK_PageUp: "⇞", kVK_PageDown: "⇟", kVK_ForwardDelete: "⌦",
    ]
    if let s = special[code] { return s }
    // Translate via current keyboard layout.
    guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
      let ptr = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData)
    else { return "#\(code)" }
    let data = Unmanaged<CFData>.fromOpaque(ptr).takeUnretainedValue() as Data
    var deadKeys: UInt32 = 0
    var chars = [UniChar](repeating: 0, count: 4)
    var length = 0
    let result = data.withUnsafeBytes { raw -> OSStatus in
      guard let layout = raw.baseAddress?.assumingMemoryBound(to: UCKeyboardLayout.self) else {
        return -1
      }
      return UCKeyTranslate(
        layout, UInt16(code), UInt16(kUCKeyActionDisplay), 0, UInt32(LMGetKbdType()),
        OptionBits(kUCKeyTranslateNoDeadKeysBit), &deadKeys, 4, &length, &chars)
    }
    guard result == noErr, length > 0 else { return "#\(code)" }
    return String(utf16CodeUnits: chars, count: length).uppercased()
  }
}
