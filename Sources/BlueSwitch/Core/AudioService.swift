import AudioToolbox
import Combine
import CoreAudio
import Foundation

/// Independently controls and monitors Microphone (input) and Speakers (output) mute and volume on macOS.
final class AudioService: ObservableObject {
  static let shared = AudioService()

  @Published private(set) var isMicMuted: Bool = false
  @Published private(set) var isSpeakersMuted: Bool = false
  @Published private(set) var micVolume: Int = 75
  @Published private(set) var speakersVolume: Int = 50
  @Published private(set) var inputDeviceName: String = "Default Microphone"
  @Published private(set) var outputDeviceName: String = "Default Speakers"

  private let queue = DispatchQueue(label: "com.blueswitch.audio", qos: .userInitiated)
  private let savedMicVolumeKey = "audioSavedMicVolumeBeforeMute"
  private let savedSpeakersVolumeKey = "audioSavedSpeakersVolumeBeforeMute"
  private var pollTimer: Timer?

  private var savedMicVolume: Int {
    get {
      let v = UserDefaults.standard.integer(forKey: savedMicVolumeKey)
      return v > 0 ? v : 80
    }
    set {
      if newValue > 0 {
        UserDefaults.standard.set(newValue, forKey: savedMicVolumeKey)
      }
    }
  }

  private var savedSpeakersVolume: Int {
    get {
      let v = UserDefaults.standard.integer(forKey: savedSpeakersVolumeKey)
      return v > 0 ? v : 50
    }
    set {
      if newValue > 0 {
        UserDefaults.standard.set(newValue, forKey: savedSpeakersVolumeKey)
      }
    }
  }

  private init() {}

  func start() {
    refresh()
    pollTimer?.invalidate()
    pollTimer = Timer.scheduledTimer(withTimeInterval: 4.0, repeats: true) { [weak self] _ in
      self?.refresh()
    }
  }

  func stop() {
    pollTimer?.invalidate()
    pollTimer = nil
  }

  // MARK: - Independent Microphone Controls

  func toggleMicMute() {
    setMicMuted(!isMicMuted)
  }

  func setMicMuted(_ muted: Bool, reason: String = "User action") {
    // Optimistic UI update
    DispatchQueue.main.async {
      if muted && self.micVolume > 0 {
        self.savedMicVolume = self.micVolume
      }
      self.isMicMuted = muted
      if muted {
        self.micVolume = 0
      } else if self.micVolume == 0 {
        self.micVolume = self.savedMicVolume
      }
    }

    queue.async { [weak self] in
      guard let self else { return }
      if let devID = Self.defaultDeviceID(isInput: true) {
        Self.setHardwareMute(deviceID: devID, isInput: true, muted: muted)
      }
      if muted {
        _ = Self.runOsaScript("set volume input volume 0")
      } else {
        let target = max(10, min(100, self.savedMicVolume))
        _ = Self.runOsaScript("set volume input volume \(target)")
      }
      DispatchQueue.main.async {
        SecurityMonitor.shared.recordAudit(
          category: "Audio",
          message: "Microphone \(muted ? "MUTED" : "UNMUTED") (\(self.inputDeviceName)) — \(reason)",
          level: .info
        )
        self.refresh()
      }
    }
  }

  func setMicVolume(_ volume: Int) {
    let clamped = max(0, min(100, volume))
    if clamped > 0 { savedMicVolume = clamped }
    DispatchQueue.main.async {
      self.micVolume = clamped
      self.isMicMuted = (clamped == 0)
    }
    queue.async { [weak self] in
      if let devID = Self.defaultDeviceID(isInput: true) {
        Self.setHardwareMute(deviceID: devID, isInput: true, muted: clamped == 0)
      }
      _ = Self.runOsaScript("set volume input volume \(clamped)")
      DispatchQueue.main.async { self?.refresh() }
    }
  }

  // MARK: - Independent Speaker Controls

  func toggleSpeakersMute() {
    setSpeakersMuted(!isSpeakersMuted)
  }

  func setSpeakersMuted(_ muted: Bool, reason: String = "User action") {
    DispatchQueue.main.async {
      if muted && self.speakersVolume > 0 {
        self.savedSpeakersVolume = self.speakersVolume
      }
      self.isSpeakersMuted = muted
    }

    queue.async { [weak self] in
      guard let self else { return }
      if let devID = Self.defaultDeviceID(isInput: false) {
        Self.setHardwareMute(deviceID: devID, isInput: false, muted: muted)
      }
      if muted {
        _ = Self.runOsaScript("set volume output muted true")
      } else {
        let target = max(10, min(100, self.savedSpeakersVolume))
        _ = Self.runOsaScript("set volume output muted false")
        if self.speakersVolume == 0 {
          _ = Self.runOsaScript("set volume output volume \(target)")
        }
      }
      DispatchQueue.main.async {
        SecurityMonitor.shared.recordAudit(
          category: "Audio",
          message: "Speakers \(muted ? "MUTED" : "UNMUTED") (\(self.outputDeviceName)) — \(reason)",
          level: .info
        )
        self.refresh()
      }
    }
  }

  func setSpeakersVolume(_ volume: Int) {
    let clamped = max(0, min(100, volume))
    if clamped > 0 { savedSpeakersVolume = clamped }
    DispatchQueue.main.async {
      self.speakersVolume = clamped
      self.isSpeakersMuted = (clamped == 0)
    }
    queue.async { [weak self] in
      if let devID = Self.defaultDeviceID(isInput: false) {
        Self.setHardwareMute(deviceID: devID, isInput: false, muted: clamped == 0)
      }
      if clamped == 0 {
        _ = Self.runOsaScript("set volume output volume 0 with output muted")
      } else {
        _ = Self.runOsaScript("set volume output volume \(clamped) without output muted")
      }
      DispatchQueue.main.async { self?.refresh() }
    }
  }

  // MARK: - State Refresh

  func refresh() {
    queue.async { [weak self] in
      guard let self else { return }
      let inID = Self.defaultDeviceID(isInput: true)
      let outID = Self.defaultDeviceID(isInput: false)
      let inName = inID.flatMap { Self.deviceName(for: $0) } ?? "Default Microphone"
      let outName = outID.flatMap { Self.deviceName(for: $0) } ?? "Default Speakers"
      let hwInMuted = inID.flatMap { Self.getHardwareMute(deviceID: $0, isInput: true) } ?? false
      let hwOutMuted = outID.flatMap { Self.getHardwareMute(deviceID: $0, isInput: false) } ?? false

      // Query macOS AppleScript volume settings: "output volume:50, input volume:75, alert volume:100, output muted:false"
      let raw = Self.runOsaScript("get volume settings") ?? ""
      var parsedOutVol = self.speakersVolume
      var parsedInVol = self.micVolume
      var parsedOutMuted = hwOutMuted

      for part in raw.split(separator: ",") {
        let kv = part.split(separator: ":").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard kv.count == 2 else { continue }
        switch kv[0] {
        case "output volume":
          if let v = Int(kv[1]) { parsedOutVol = v }
        case "input volume":
          if let v = Int(kv[1]) { parsedInVol = v }
        case "output muted":
          parsedOutMuted = (kv[1].lowercased() == "true") || hwOutMuted
        default:
          break
        }
      }

      let micMutedNow = hwInMuted || (parsedInVol == 0)
      let spkMutedNow = parsedOutMuted || (parsedOutVol == 0)
      if parsedInVol > 0 { self.savedMicVolume = parsedInVol }
      if parsedOutVol > 0 { self.savedSpeakersVolume = parsedOutVol }

      DispatchQueue.main.async {
        self.inputDeviceName = inName
        self.outputDeviceName = outName
        self.micVolume = parsedInVol
        self.speakersVolume = parsedOutVol
        self.isMicMuted = micMutedNow
        self.isSpeakersMuted = spkMutedNow
      }
    }
  }

  // MARK: - CoreAudio & AppleScript Helpers

  private static func defaultDeviceID(isInput: Bool) -> AudioDeviceID? {
    var address = AudioObjectPropertyAddress(
      mSelector: isInput
        ? kAudioHardwarePropertyDefaultInputDevice
        : kAudioHardwarePropertyDefaultOutputDevice,
      mScope: kAudioObjectPropertyScopeGlobal,
      mElement: kAudioObjectPropertyElementMain
    )
    var deviceID: AudioDeviceID = kAudioObjectUnknown
    var size = UInt32(MemoryLayout<AudioDeviceID>.size)
    let status = AudioObjectGetPropertyData(
      AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceID)
    guard status == noErr, deviceID != kAudioObjectUnknown else { return nil }
    return deviceID
  }

  private static func deviceName(for deviceID: AudioDeviceID) -> String? {
    var address = AudioObjectPropertyAddress(
      mSelector: kAudioObjectPropertyName,
      mScope: kAudioObjectPropertyScopeGlobal,
      mElement: kAudioObjectPropertyElementMain
    )
    var name: CFString = "" as CFString
    var size = UInt32(MemoryLayout<CFString>.size)
    let status = withUnsafeMutablePointer(to: &name) { ptr in
      AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, ptr)
    }
    guard status == noErr else { return nil }
    return name as String
  }

  private static func getHardwareMute(deviceID: AudioDeviceID, isInput: Bool) -> Bool? {
    let scope = isInput ? kAudioObjectPropertyScopeInput : kAudioObjectPropertyScopeOutput
    for element: UInt32 in [kAudioObjectPropertyElementMain, 1, 2] {
      var address = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyMute,
        mScope: scope,
        mElement: element
      )
      guard AudioObjectHasProperty(deviceID, &address) else { continue }
      var muted: UInt32 = 0
      var size = UInt32(MemoryLayout<UInt32>.size)
      if AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &muted) == noErr {
        return muted != 0
      }
    }
    return nil
  }

  private static func setHardwareMute(deviceID: AudioDeviceID, isInput: Bool, muted: Bool) {
    let scope = isInput ? kAudioObjectPropertyScopeInput : kAudioObjectPropertyScopeOutput
    var val: UInt32 = muted ? 1 : 0
    let size = UInt32(MemoryLayout<UInt32>.size)
    for element: UInt32 in [kAudioObjectPropertyElementMain, 1, 2] {
      var address = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyMute,
        mScope: scope,
        mElement: element
      )
      guard AudioObjectHasProperty(deviceID, &address) else { continue }
      var settable: DarwinBoolean = false
      if AudioObjectIsPropertySettable(deviceID, &address, &settable) == noErr, settable.boolValue {
        _ = AudioObjectSetPropertyData(deviceID, &address, 0, nil, size, &val)
      }
    }
  }

  private static func runOsaScript(_ source: String) -> String? {
    let proc = Process()
    proc.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
    proc.arguments = ["-e", source]
    let outPipe = Pipe()
    proc.standardOutput = outPipe
    proc.standardError = FileHandle.nullDevice
    do {
      try proc.run()
      proc.waitUntilExit()
      let data = outPipe.fileHandleForReading.readDataToEndOfFile()
      return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
    } catch {
      return nil
    }
  }
}

