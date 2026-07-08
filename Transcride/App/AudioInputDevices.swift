import CoreAudio
import Foundation
import Observation

struct AudioInputDevice: Identifiable, Hashable, Sendable {
    /// CoreAudio persistent device UID — what settings store.
    var uid: String
    var name: String
    /// Transient CoreAudio ID for the current session.
    var deviceID: AudioDeviceID

    var id: String { uid }
}

/// Live list of audio input devices, refreshed automatically when hardware
/// appears or disappears (CoreAudio property listener on the system object).
@MainActor
@Observable
final class AudioInputDevices {
    private(set) var devices: [AudioInputDevice] = []

    init() {
        refresh()
        var address = Self.address(kAudioHardwarePropertyDevices)
        AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &address, .main
        ) { _, _ in
            Task { @MainActor [weak self] in self?.refresh() }
        }
    }

    func refresh() {
        devices = Self.allInputDevices()
    }

    func device(forUID uid: String) -> AudioInputDevice? {
        devices.first { $0.uid == uid }
    }

    // MARK: - CoreAudio queries

    static func allInputDevices() -> [AudioInputDevice] {
        var address = address(kAudioHardwarePropertyDevices)
        let system = AudioObjectID(kAudioObjectSystemObject)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr,
              size > 0 else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &ids) == noErr else {
            return []
        }
        return ids.compactMap { deviceID in
            guard inputChannelCount(of: deviceID) > 0,
                  let uid = stringProperty(of: deviceID, kAudioDevicePropertyDeviceUID),
                  let name = stringProperty(of: deviceID, kAudioObjectPropertyName) else {
                return nil
            }
            return AudioInputDevice(uid: uid, name: name, deviceID: deviceID)
        }
    }

    static func defaultInputDeviceID() -> AudioDeviceID? {
        var address = address(kAudioHardwarePropertyDefaultInputDevice)
        var deviceID = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceID
        )
        guard status == noErr, deviceID != kAudioObjectUnknown else { return nil }
        return deviceID
    }

    private static func inputChannelCount(of deviceID: AudioDeviceID) -> Int {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &size) == noErr,
              size > 0 else { return 0 }
        let raw = UnsafeMutableRawPointer.allocate(
            byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment
        )
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, raw) == noErr else {
            return 0
        }
        let list = raw.assumingMemoryBound(to: AudioBufferList.self)
        return UnsafeMutableAudioBufferListPointer(list).reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    private static func stringProperty(
        of objectID: AudioObjectID, _ selector: AudioObjectPropertySelector
    ) -> String? {
        var address = address(selector)
        var value: CFString?
        var size = UInt32(MemoryLayout<CFString?>.size)
        let status = withUnsafeMutablePointer(to: &value) { pointer in
            AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, pointer)
        }
        guard status == noErr else { return nil }
        return value as String?
    }

    private static func address(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
    }
}
