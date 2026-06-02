import AVFoundation
import CoreAudio
import Foundation
import Observability

// MARK: - DeviceInfo

/// Lightweight, `Sendable` description of a CoreAudio output device.
public struct DeviceInfo: Sendable, Equatable, Identifiable {
    public let id: AudioDeviceID
    public let name: String
    public let uid: String
}

// MARK: - DeviceRouter

/// Enumerates CoreAudio output devices and handles default-device changes.
///
/// Listens for `kAudioHardwarePropertyDefaultOutputDevice` changes and calls
/// `onDeviceChange` when the default output changes.
public actor DeviceRouter {
    private let log = AppLogger.make(.audio)
    private var listenerBlock: AudioObjectPropertyListenerBlock?

    /// The current default output device. Returns `nil` if none is set.
    public static func defaultOutputDevice() -> DeviceInfo? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var deviceID: AudioDeviceID = kAudioDeviceUnknown
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &size,
            &deviceID
        ) == noErr, deviceID != kAudioDeviceUnknown else { return nil }

        let name = self.stringProperty(deviceID, kAudioDevicePropertyDeviceNameCFString) ?? "Unknown"
        let uid = self.stringProperty(deviceID, kAudioDevicePropertyDeviceUID) ?? "\(deviceID)"
        return DeviceInfo(id: deviceID, name: name, uid: uid)
    }

    // MARK: - Private helpers

    private static func stringProperty(
        _ deviceID: AudioDeviceID,
        _ selector: AudioObjectPropertySelector
    ) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize = UInt32(MemoryLayout<CFString>.size)
        var result: Unmanaged<CFString>?
        guard AudioObjectGetPropertyData(
            deviceID,
            &address,
            0,
            nil,
            &dataSize,
            &result
        ) == noErr else { return nil }
        return result?.takeRetainedValue() as String?
    }

    // MARK: - Instance methods

    /// Observe default-device changes, invoking `handler` on each change.
    /// Returns the prior listener registration (call `stopObserving()` to cancel).
    public func startObserving(handler: @Sendable @escaping (DeviceInfo?) -> Void) {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        let log = self.log
        let block: AudioObjectPropertyListenerBlock = { _, _ in
            let device = DeviceRouter.defaultOutputDevice()
            handler(device)
            log.notice("audio.device.changed", ["device": device?.name ?? "none"])
        }

        AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            DispatchQueue.main,
            block
        )
        self.listenerBlock = block
    }

    /// Remove the registered listener.
    public func stopObserving() {
        guard let block = listenerBlock else { return }
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectRemovePropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            DispatchQueue.main,
            block
        )
        self.listenerBlock = nil
    }
}
