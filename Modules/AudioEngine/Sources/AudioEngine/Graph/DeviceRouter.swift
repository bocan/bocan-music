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

    /// Returns all current CoreAudio output devices.
    public static func outputDevices() -> [DeviceInfo] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &dataSize
        ) == noErr, dataSize > 0 else { return [] }

        let count = Int(dataSize) / MemoryLayout<AudioDeviceID>.size
        var deviceIDs = [AudioDeviceID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &dataSize,
            &deviceIDs
        ) == noErr else { return [] }

        return deviceIDs.compactMap { deviceID -> DeviceInfo? in
            guard self.isOutputDevice(deviceID) else { return nil }
            let name = self.stringProperty(deviceID, kAudioDevicePropertyDeviceNameCFString) ?? "Unknown"
            let uid = self.stringProperty(deviceID, kAudioDevicePropertyDeviceUID) ?? "\(deviceID)"
            return DeviceInfo(id: deviceID, name: name, uid: uid)
        }
    }

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

    private static func isOutputDevice(_ deviceID: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            deviceID,
            &address,
            0,
            nil,
            &dataSize
        ) == noErr, dataSize > 0 else { return false }

        let bufferList = UnsafeMutablePointer<AudioBufferList>.allocate(capacity: Int(dataSize))
        defer { bufferList.deallocate() }
        guard AudioObjectGetPropertyData(
            deviceID,
            &address,
            0,
            nil,
            &dataSize,
            bufferList
        ) == noErr else { return false }

        return bufferList.pointee.mNumberBuffers > 0
    }

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

    /// Set the system-wide default output device.
    ///
    /// Returns `true` on success.  Used both as the spec-mandated `set(_:)`
    /// API and as the underlying mechanism behind any "select output device"
    /// preference in the UI.  Per-app routing (changing only this app's
    /// destination without affecting the rest of the system) is intentionally
    /// out of scope for v1: the macOS HAL story for that requires a private
    /// `kAudioOutputUnitProperty_CurrentDevice` dance against the engine's
    /// output unit, and shipping it without a way to reset on crash is risky.
    @discardableResult
    public static func setDefaultOutputDevice(_ id: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var deviceID = id
        let size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectSetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            size,
            &deviceID
        )
        return status == noErr
    }
}
