import CoreAudio
import Foundation
import IOKit

/// Microphones connected to this Mac, kept current as devices come and go.
@MainActor
final class AudioDevices: ObservableObject {
    static let shared = AudioDevices()

    struct Device: Identifiable, Hashable {
        let id: AudioDeviceID
        let uid: String
        let name: String
    }

    @Published private(set) var inputs: [Device] = []
    @Published private(set) var defaultInputName = ""

    private init() {
        refresh()
        for selector in [kAudioHardwarePropertyDevices, kAudioHardwarePropertyDefaultInputDevice] {
            var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                                     mElement: kAudioObjectPropertyElementMain)
            AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main) { _, _ in
                MainActor.assumeIsolated { AudioDevices.shared.refresh() }
            }
        }
    }

    func refresh() {
        inputs = Self.allDevices().filter { Self.inputChannels($0) > 0 }.compactMap { id in
            guard let uid = Self.string(id, kAudioDevicePropertyDeviceUID),
                  let name = Self.string(id, kAudioObjectPropertyName) else { return nil }
            return Device(id: id, uid: uid, name: name)
        }
        .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        defaultInputName = Self.defaultInput().flatMap { Self.string($0, kAudioObjectPropertyName) } ?? ""
    }

    /// The device to record from: the first connected microphone in `priority` ("" = the system
    /// default), otherwise the system default.
    nonisolated static func deviceID(forPriority priority: [String]) -> AudioDeviceID? {
        let connected = allDevices().filter { inputChannels($0) > 0 }
        var chosen = defaultInput()
        for uid in priority {
            if uid.isEmpty { break } // "System default" ranked here
            if let match = connected.first(where: { string($0, kAudioDevicePropertyDeviceUID) == uid }) {
                chosen = match
                break
            }
        }
        // Lid closed (external display): the built-in mic sits under the lid and hears almost
        // nothing, so use another microphone if there is one.
        if let device = chosen, isBuiltIn(device), lidClosed() {
            // Your next-ranked real microphone first, then any external one.
            let ranked = priority.compactMap { uid in connected.first { string($0, kAudioDevicePropertyDeviceUID) == uid } }
            if let next = ranked.first(where: { !isBuiltIn($0) && externalRank($0) != nil }) ?? externalMicrophone() { return next }
        }
        return chosen
    }

    /// The UID of the microphone `deviceID(forPriority:)` picks, for showing which one is in use.
    nonisolated static func uid(of device: AudioDeviceID) -> String? { string(device, kAudioDevicePropertyDeviceUID) }

    private nonisolated static func externalRank(_ id: AudioDeviceID) -> Int? { externalRanks[transportType(id)] }
    private nonisolated static let externalRanks: [UInt32: Int] = [
        kAudioDeviceTransportTypeUSB: 0, kAudioDeviceTransportTypeThunderbolt: 0,
        kAudioDeviceTransportTypeFireWire: 0, kAudioDeviceTransportTypePCI: 0,
        kAudioDeviceTransportTypeBluetooth: 1, kAudioDeviceTransportTypeBluetoothLE: 1,
        kAudioDeviceTransportTypeContinuityCaptureWired: 2, kAudioDeviceTransportTypeContinuityCaptureWireless: 2]

    /// A real external microphone, preferring wired ones. Never a virtual or aggregate device
    /// (Zoom, Teams, BlackHole, Loopback…), which would record silence or app audio.
    private nonisolated static func externalMicrophone() -> AudioDeviceID? {
        allDevices()
            .filter { inputChannels($0) > 0 }
            .compactMap { id -> (AudioDeviceID, Int)? in externalRank(id).map { (id, $0) } }
            .min { $0.1 < $1.1 }?.0
    }

    nonisolated static func transportType(_ id: AudioDeviceID) -> UInt32 {
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyTransportType, mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var transport = UInt32(0)
        var size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectGetPropertyData(id, &address, 0, nil, &size, &transport) == noErr ? transport : 0
    }

    nonisolated static func isBuiltIn(_ id: AudioDeviceID) -> Bool {
        transportType(id) == kAudioDeviceTransportTypeBuiltIn
    }

    /// MacBook lid state from the power-management root domain.
    nonisolated static func lidClosed() -> Bool {
        let root = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        guard root != 0 else { return false }
        defer { IOObjectRelease(root) }
        let value = IORegistryEntryCreateCFProperty(root, "AppleClamshellState" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
        return (value as? Bool) ?? false
    }

    /// An output device by UID (for restoring volume after a crash).
    nonisolated static func deviceID(forOutputUID uid: String) -> AudioDeviceID? {
        allDevices().first { string($0, kAudioDevicePropertyDeviceUID) == uid }
    }

    // MARK: CoreAudio

    private nonisolated static func allDevices() -> [AudioDeviceID] {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices, mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &ids) == noErr else { return [] }
        return ids
    }

    private nonisolated static func defaultInput() -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultInputDevice, mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &id)
        return status == noErr && id != 0 ? id : nil
    }

    private nonisolated static func inputChannels(_ id: AudioDeviceID) -> Int {
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreamConfiguration, mScope: kAudioDevicePropertyScopeInput,
                                                 mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr, size > 0 else { return 0 }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, raw) == noErr else { return 0 }
        let list = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        return list.reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    private nonisolated static func string(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr, let value else { return nil }
        return value.takeRetainedValue() as String
    }
}
