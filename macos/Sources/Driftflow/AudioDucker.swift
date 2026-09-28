import AudioToolbox
import CoreAudio
import Foundation

/// Turns other audio down while you dictate and back up afterwards, by lowering the output
/// device's volume. The original volume is written to disk first, so a crash mid-dictation is
/// undone on the next launch.
@MainActor
final class AudioDucker {
    private var saved: (device: AudioDeviceID, volume: Float32, ducked: Float32)?
    private var rampTask: Task<Void, Never>?
    /// The last volume we set, to tell our own changes from the user's.
    private var lastSet: Float32?
    private var ramping = false
    private static let restoreKey = "duckRestore"

    /// Lowers the volume to `fraction` of its current level over ~150 ms.
    func duck(to fraction: Float32 = 0.3) {
        guard saved == nil, let device = Self.defaultOutput(), let volume = Self.volume(of: device), volume > 0.05 else { return }
        let target = volume * fraction
        saved = (device, volume, target)
        UserDefaults.standard.set(["uid": Self.uid(of: device) ?? "", "volume": volume], forKey: Self.restoreKey)
        ramp(device, from: volume, to: target)
    }

    /// Puts the volume back, unless you changed it yourself in the meantime.
    func restore() {
        guard let saved else { return }
        self.saved = nil
        let wasRamping = ramping
        rampTask?.cancel()
        ramping = false
        UserDefaults.standard.removeObject(forKey: Self.restoreKey)
        // Mid-fade the volume is between the two levels by design: always put it back. After the
        // fade, a different volume means you changed it yourself (the tolerance allows for devices
        // like Bluetooth headphones that store volume in coarse steps).
        if !wasRamping, let current = Self.volume(of: saved.device), let lastSet, abs(current - lastSet) > 0.035 { return }
        Self.setVolume(saved.volume, on: saved.device)
    }

    /// Undoes a duck left behind by a crash or force-quit.
    static func restoreAfterCrash() {
        guard let info = UserDefaults.standard.dictionary(forKey: restoreKey),
              let uid = info["uid"] as? String, let volume = info["volume"] as? Float32 else { return }
        UserDefaults.standard.removeObject(forKey: restoreKey)
        guard let device = AudioDevices.deviceID(forOutputUID: uid) ?? defaultOutput() else { return }
        setVolume(volume, on: device)
    }

    private func ramp(_ device: AudioDeviceID, from: Float32, to: Float32) {
        rampTask?.cancel()
        ramping = true
        rampTask = Task {
            for step in 1...6 {
                guard !Task.isCancelled else { return }
                let level = from + (to - from) * Float32(step) / 6
                Self.setVolume(level, on: device)
                lastSet = level
                try? await Task.sleep(for: .milliseconds(25))
            }
            if !Task.isCancelled { ramping = false }
        }
    }

    /// Current output volume (for the `--duck-test` check).
    static func currentVolume() -> Float32? { defaultOutput().flatMap(volume(of:)) }

    // MARK: CoreAudio

    private static func defaultOutput() -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                                 mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        return AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &id) == noErr && id != 0 ? id : nil
    }

    private static var volumeAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
        mScope: kAudioDevicePropertyScopeOutput, mElement: kAudioObjectPropertyElementMain)

    /// nil for devices without a volume control (e.g. some HDMI outputs).
    private static func volume(of device: AudioDeviceID) -> Float32? {
        var address = volumeAddress
        guard AudioObjectHasProperty(device, &address) else { return nil }
        var volume = Float32(0)
        var size = UInt32(MemoryLayout<Float32>.size)
        return AudioObjectGetPropertyData(device, &address, 0, nil, &size, &volume) == noErr ? volume : nil
    }

    private static func setVolume(_ volume: Float32, on device: AudioDeviceID) {
        var address = volumeAddress
        var value = max(0, min(1, volume))
        AudioObjectSetPropertyData(device, &address, 0, nil, UInt32(MemoryLayout<Float32>.size), &value)
    }

    private static func uid(of device: AudioDeviceID) -> String? {
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyDeviceUID, mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value) == noErr, let value else { return nil }
        return value.takeRetainedValue() as String
    }
}
