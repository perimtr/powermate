import CoreAudio
import Foundation

/// System output volume/mute via CoreAudio - needs no special permissions and
/// works with the default output device, following it when the user switches.
enum SystemAudio {
    /// Elements to try, in order: the main (master) element, then stereo channels.
    fileprivate static let elements: [AudioObjectPropertyElement] = [kAudioObjectPropertyElementMain, 1, 2]

    // Software-mute fallback for output devices without a hardware mute control.
    private static var softwareMuted = false
    private static var restoreVolume: Float32 = 0.5

    static func defaultOutputDevice() -> AudioDeviceID? {
        var deviceID = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceID)
        guard status == noErr, deviceID != kAudioObjectUnknown else { return nil }
        return deviceID
    }

    private static func address(
        _ selector: AudioObjectPropertySelector,
        element: AudioObjectPropertyElement
    ) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: element)
    }

    // MARK: - Volume

    static func volume(of device: AudioDeviceID) -> Float32? {
        for element in elements {
            var addr = address(kAudioDevicePropertyVolumeScalar, element: element)
            guard AudioObjectHasProperty(device, &addr) else { continue }
            var value = Float32(0)
            var size = UInt32(MemoryLayout<Float32>.size)
            if AudioObjectGetPropertyData(device, &addr, 0, nil, &size, &value) == noErr {
                return value
            }
        }
        return nil
    }

    static func setVolume(_ volume: Float32, of device: AudioDeviceID) {
        var value = min(1, max(0, volume))
        for element in elements {
            var addr = address(kAudioDevicePropertyVolumeScalar, element: element)
            var settable = DarwinBoolean(false)
            guard AudioObjectHasProperty(device, &addr),
                  AudioObjectIsPropertySettable(device, &addr, &settable) == noErr,
                  settable.boolValue
            else { continue }
            let status = AudioObjectSetPropertyData(
                device, &addr, 0, nil, UInt32(MemoryLayout<Float32>.size), &value)
            // Setting the main element covers all channels; stop there.
            if status == noErr && element == kAudioObjectPropertyElementMain { return }
        }
    }

    // MARK: - Mute

    static func isMuted(_ device: AudioDeviceID) -> Bool {
        if let hardware = hardwareMute(device) { return hardware }
        return softwareMuted
    }

    static func setMuted(_ muted: Bool, of device: AudioDeviceID) {
        if setHardwareMute(muted, device) {
            softwareMuted = false
            return
        }
        if muted {
            restoreVolume = volume(of: device) ?? 0.5
            setVolume(0, of: device)
            softwareMuted = true
        } else {
            if softwareMuted { setVolume(restoreVolume, of: device) }
            softwareMuted = false
        }
    }

    private static func hardwareMute(_ device: AudioDeviceID) -> Bool? {
        for element in elements {
            var addr = address(kAudioDevicePropertyMute, element: element)
            guard AudioObjectHasProperty(device, &addr) else { continue }
            var value = UInt32(0)
            var size = UInt32(MemoryLayout<UInt32>.size)
            if AudioObjectGetPropertyData(device, &addr, 0, nil, &size, &value) == noErr {
                return value != 0
            }
        }
        return nil
    }

    // MARK: - Output devices

    /// Every device that can play audio, sorted by name so cycling through
    /// them is deterministic.
    static func outputDevices() -> [(id: AudioDeviceID, name: String)] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr,
            size > 0
        else { return [] }
        var ids = [AudioDeviceID](
            repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &ids) == noErr
        else { return [] }
        return ids.filter(hasOutputStreams)
            .compactMap { id in name(of: id).map { (id: id, name: $0) } }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private static func hasOutputStreams(_ device: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        return AudioObjectGetPropertyDataSize(device, &address, 0, nil, &size) == noErr
            && size > 0
    }

    static func name(of device: AudioDeviceID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyName,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectHasProperty(device, &address) else { return nil }
        var nameRef: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &nameRef) == noErr,
              let nameRef else { return nil }
        return nameRef.takeRetainedValue() as String
    }

    @discardableResult
    static func setDefaultOutputDevice(_ device: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var id = device
        return AudioObjectSetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil,
            UInt32(MemoryLayout<AudioDeviceID>.size), &id) == noErr
    }

    private static func setHardwareMute(_ muted: Bool, _ device: AudioDeviceID) -> Bool {
        var succeeded = false
        for element in elements {
            var addr = address(kAudioDevicePropertyMute, element: element)
            var settable = DarwinBoolean(false)
            guard AudioObjectHasProperty(device, &addr),
                  AudioObjectIsPropertySettable(device, &addr, &settable) == noErr,
                  settable.boolValue
            else { continue }
            var value: UInt32 = muted ? 1 : 0
            let status = AudioObjectSetPropertyData(
                device, &addr, 0, nil, UInt32(MemoryLayout<UInt32>.size), &value)
            if status == noErr {
                succeeded = true
                if element == kAudioObjectPropertyElementMain { break }
            }
        }
        return succeeded
    }
}

/// Watches the default output device and its volume/mute so the app can
/// react to changes made anywhere (keyboard volume keys, other apps, the
/// menu bar sound slider), not only to its own knob actions. Listeners are
/// re-attached whenever the default device itself changes.
final class SystemAudioObserver {
    /// Called on the main queue after any volume, mute, or device change.
    var onChange: (() -> Void)?

    private var observedDevice = AudioDeviceID(kAudioObjectUnknown)
    private var observedAddresses: [AudioObjectPropertyAddress] = []
    private var deviceListener: AudioObjectPropertyListenerBlock?
    private var valueListener: AudioObjectPropertyListenerBlock?

    func start() {
        deviceListener = { [weak self] _, _ in
            self?.attachToDefaultDevice()
            self?.onChange?()
        }
        valueListener = { [weak self] _, _ in
            self?.onChange?()
        }
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &address, .main, deviceListener!)
        attachToDefaultDevice()
    }

    private func attachToDefaultDevice() {
        guard let valueListener else { return }
        if observedDevice != kAudioObjectUnknown {
            for var address in observedAddresses {
                AudioObjectRemovePropertyListenerBlock(
                    observedDevice, &address, .main, valueListener)
            }
            observedAddresses.removeAll()
            observedDevice = AudioDeviceID(kAudioObjectUnknown)
        }
        guard let device = SystemAudio.defaultOutputDevice() else { return }
        observedDevice = device
        for selector in [kAudioDevicePropertyVolumeScalar, kAudioDevicePropertyMute] {
            for element in SystemAudio.elements {
                var address = AudioObjectPropertyAddress(
                    mSelector: selector,
                    mScope: kAudioDevicePropertyScopeOutput,
                    mElement: element)
                guard AudioObjectHasProperty(device, &address),
                      AudioObjectAddPropertyListenerBlock(
                          device, &address, .main, valueListener) == noErr
                else { continue }
                observedAddresses.append(address)
            }
        }
    }
}
