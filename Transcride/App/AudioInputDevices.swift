import AudioToolbox
import AVFoundation
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
    private static let preferredMicDefaultsKey = "preferredMicUID"
    private(set) var devices: [AudioInputDevice] = []

    init() {
        Self.migrateStoredDefaultProxySelection()
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
            guard isUsableInputDevice(deviceID),
                  let uid = stringProperty(of: deviceID, kAudioDevicePropertyDeviceUID),
                  let name = stringProperty(of: deviceID, kAudioObjectPropertyName) else {
                return nil
            }
            return AudioInputDevice(uid: uid, name: name, deviceID: deviceID)
        }.filter {
            !isSystemDefaultProxy(uid: $0.uid, name: $0.name)
        }
    }

    /// Core Audio can expose its routing proxy as an ordinary input with names
    /// such as "CAdefault" or "CA Default Device". Transcride already has one
    /// user-facing System Default choice, so showing the proxy creates a
    /// duplicate technical row and persists an implementation-detail UID.
    static func isSystemDefaultProxy(uid: String, name: String) -> Bool {
        let normalizedUID = normalizedTechnicalName(uid)
        let normalizedName = normalizedTechnicalName(name)
        let aliases: Set<String> = [
            "cadefault",
            "cadefaultdevice",
            "coreaudiodefault",
            "coreaudiodefaultdevice",
        ]
        if aliases.contains(normalizedUID) || aliases.contains(normalizedName) {
            return true
        }
        return uid.lowercased().hasPrefix("com.apple.audio.coreaudio.default")
    }

    private static func migrateStoredDefaultProxySelection(
        defaults: UserDefaults = .standard
    ) {
        guard let uid = defaults.string(forKey: preferredMicDefaultsKey),
              isSystemDefaultProxy(uid: uid, name: "") else { return }
        defaults.removeObject(forKey: preferredMicDefaultsKey)
    }

    private static func normalizedTechnicalName(_ value: String) -> String {
        String(value.lowercased().filter { $0.isLetter || $0.isNumber })
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

    /// The device currently bound to an AVAudioEngine input AudioUnit.
    /// This can differ from the system default when the user picked a mic.
    static func currentInputDeviceID(for audioUnit: AudioUnit?) -> AudioDeviceID? {
        guard let audioUnit else { return nil }
        var deviceID = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioUnitGetProperty(
            audioUnit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &deviceID,
            &size
        )
        guard status == noErr, deviceID != kAudioObjectUnknown else { return nil }
        return deviceID
    }

    static func isUsableInputDevice(_ deviceID: AudioDeviceID) -> Bool {
        inputChannelCount(of: deviceID) > 0
            && boolProperty(of: deviceID, kAudioDevicePropertyDeviceIsAlive) == true
            && (doubleProperty(of: deviceID, kAudioDevicePropertyNominalSampleRate) ?? 0) > 0
    }

    /// ScreenCaptureKit expects an AVCaptureDevice unique ID rather than a
    /// transient Core Audio device ID. Refuse to guess by display name because
    /// duplicate device names are common.
    nonisolated static func captureDeviceUniqueID(forStoredUID uid: String) -> String? {
        guard !uid.isEmpty else { return nil }
        return AVCaptureDevice.DiscoverySession(
            deviceTypes: [.microphone], mediaType: .audio, position: .unspecified
        ).devices.first(where: { $0.uniqueID == uid })?.uniqueID
    }

    static func inputChannelCount(of deviceID: AudioDeviceID) -> Int {
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

    private static func boolProperty(
        of objectID: AudioObjectID, _ selector: AudioObjectPropertySelector
    ) -> Bool? {
        var address = address(selector)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        let status = AudioObjectGetPropertyData(
            objectID, &address, 0, nil, &size, &value
        )
        guard status == noErr else { return nil }
        return value != 0
    }

    static func nominalSampleRate(of deviceID: AudioDeviceID) -> Double? {
        doubleProperty(of: deviceID, kAudioDevicePropertyNominalSampleRate)
    }

    private static func doubleProperty(
        of objectID: AudioObjectID, _ selector: AudioObjectPropertySelector
    ) -> Double? {
        var address = address(selector)
        var value: Double = 0
        var size = UInt32(MemoryLayout<Double>.size)
        let status = AudioObjectGetPropertyData(
            objectID, &address, 0, nil, &size, &value
        )
        guard status == noErr, value.isFinite else { return nil }
        return value
    }

    private static func address(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
    }
}
