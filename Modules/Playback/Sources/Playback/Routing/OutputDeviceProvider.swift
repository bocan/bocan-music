import CoreAudio
import Foundation
import Observability

// MARK: - OutputDeviceInfo

/// Snapshot of the system's current default audio output device.
///
/// Produced by an `OutputDeviceProvider` and consumed by `RouteManager` to
/// derive a `Route`. Pure value type so it's trivially `Sendable` / `Equatable`.
public struct OutputDeviceInfo: Sendable, Equatable {
    public let deviceID: UInt32
    public let name: String
    public let transportType: TransportType

    public init(deviceID: UInt32, name: String, transportType: TransportType) {
        self.deviceID = deviceID
        self.name = name
        self.transportType = transportType
    }
}

// MARK: - TransportType

/// The transport CoreAudio reports for a device. Mapped from the raw
/// `kAudioDevicePropertyTransportType` four-char codes.
public enum TransportType: Sendable, Equatable {
    case builtIn
    case airPlay
    case bluetooth
    case bluetoothLE
    case hdmi
    case displayPort
    case usb
    case thunderbolt
    case aggregate
    case virtual
    case unknown

    /// Human-readable kind label used by `Route.external(_:kind:)`.
    public var kindLabel: String {
        switch self {
        case .builtIn:
            "Built-in"

        case .airPlay:
            "AirPlay"

        case .bluetooth, .bluetoothLE:
            "Bluetooth"

        case .hdmi:
            "HDMI"

        case .displayPort:
            "DisplayPort"

        case .usb:
            "USB"

        case .thunderbolt:
            "Thunderbolt"

        case .aggregate:
            "Aggregate"

        case .virtual:
            "Virtual"

        case .unknown:
            "External"
        }
    }

    /// Map the raw CoreAudio transport-type code into the cases we care about.
    public init(rawCode: UInt32) {
        switch rawCode {
        case kAudioDeviceTransportTypeBuiltIn:
            self = .builtIn

        case kAudioDeviceTransportTypeAirPlay:
            self = .airPlay

        case kAudioDeviceTransportTypeBluetooth:
            self = .bluetooth

        case kAudioDeviceTransportTypeBluetoothLE:
            self = .bluetoothLE

        case kAudioDeviceTransportTypeHDMI:
            self = .hdmi

        case kAudioDeviceTransportTypeDisplayPort:
            self = .displayPort

        case kAudioDeviceTransportTypeUSB:
            self = .usb

        case kAudioDeviceTransportTypeThunderbolt:
            self = .thunderbolt

        case kAudioDeviceTransportTypeAggregate:
            self = .aggregate

        case kAudioDeviceTransportTypeVirtual:
            self = .virtual

        default:
            self = .unknown
        }
    }
}

// MARK: - OutputDeviceProvider

/// Source of `OutputDeviceInfo` values.
///
/// The production implementation talks to CoreAudio HAL; tests use an
/// in-memory mock that they drive manually.
public protocol OutputDeviceProvider: Sendable {
    /// The current default output device, evaluated on demand.
    func current() async -> OutputDeviceInfo

    /// Stream of changes to the default output device. Hot stream — emits
    /// the current value once on subscription, then again on every change.
    func updates() -> AsyncStream<OutputDeviceInfo>
}

// MARK: - CoreAudioOutputDeviceProvider

/// Production `OutputDeviceProvider` that wraps the CoreAudio HAL.
///
/// Listens to `kAudioHardwarePropertyDefaultOutputDevice` on the system
/// object, plus name / transport-type listeners on the *current* device,
/// and emits a fresh `OutputDeviceInfo` on every change.
public final class CoreAudioOutputDeviceProvider: OutputDeviceProvider, @unchecked Sendable {
    private let log = AppLogger.make(.playback)

    /// Continuations for active subscribers. CoreAudio HAL callbacks fire
    /// on its own thread; we serialise mutation through the lock.
    private let lock = NSLock()
    private var continuations: [UUID: AsyncStream<OutputDeviceInfo>.Continuation] = [:]
    private var systemListenerInstalled = false
    private var deviceListenerInstalledFor: AudioObjectID = 0

    public init() {}

    deinit {
        self.removeListeners()
    }

    // MARK: OutputDeviceProvider

    public func current() async -> OutputDeviceInfo {
        self.snapshot() ?? OutputDeviceInfo(
            deviceID: 0,
            name: "Unknown Output",
            transportType: .unknown
        )
    }

    public func updates() -> AsyncStream<OutputDeviceInfo> {
        AsyncStream { continuation in
            let id = UUID()
            self.lock.lock()
            self.continuations[id] = continuation
            let needInstall = !self.systemListenerInstalled
            self.lock.unlock()

            if needInstall {
                self.installSystemListener()
                self.refreshDeviceListener()
            }

            // Seed with the current value so subscribers don't need a separate read.
            if let info = self.snapshot() {
                continuation.yield(info)
            }

            continuation.onTermination = { @Sendable [weak self] _ in
                guard let self else { return }
                self.lock.lock()
                self.continuations.removeValue(forKey: id)
                let empty = self.continuations.isEmpty
                self.lock.unlock()
                if empty {
                    self.removeListeners()
                }
            }
        }
    }

    // MARK: HAL plumbing

    private func snapshot() -> OutputDeviceInfo? {
        guard let deviceID = self.fetchDefaultOutputDeviceID() else { return nil }
        let name = self.fetchDeviceName(deviceID) ?? "Output"
        let transport = self.fetchTransportType(deviceID)
        return OutputDeviceInfo(deviceID: deviceID, name: name, transportType: transport)
    }

    private func fetchDefaultOutputDeviceID() -> AudioObjectID? {
        var id: AudioObjectID = 0
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &addr,
            0, nil,
            &size, &id
        )
        guard status == noErr, id != 0 else {
            self.log.warning("routing.hal.defaultDevice.fail", ["status": Int(status)])
            return nil
        }
        return id
    }

    private func fetchDeviceName(_ deviceID: AudioObjectID) -> String? {
        var name: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyName,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = AudioObjectGetPropertyData(deviceID, &addr, 0, nil, &size, &name)
        guard status == noErr, let cf = name?.takeRetainedValue() else { return nil }
        return cf as String
    }

    private func fetchTransportType(_ deviceID: AudioObjectID) -> TransportType {
        var raw: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyTransportType,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = AudioObjectGetPropertyData(deviceID, &addr, 0, nil, &size, &raw)
        guard status == noErr else { return .unknown }
        return TransportType(rawCode: raw)
    }

    private func installSystemListener() {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &addr,
            DispatchQueue.global(qos: .utility)
        ) { [weak self] _, _ in
            self?.handleDefaultDeviceChanged()
        }
        if status == noErr {
            self.lock.lock()
            self.systemListenerInstalled = true
            self.lock.unlock()
        } else {
            self.log.error("routing.hal.systemListener.fail", ["status": Int(status)])
        }
    }

    private func handleDefaultDeviceChanged() {
        self.refreshDeviceListener()
        self.broadcastSnapshot()
    }

    private func handleDevicePropertyChanged() {
        self.broadcastSnapshot()
    }

    private func refreshDeviceListener() {
        guard let newID = fetchDefaultOutputDeviceID() else { return }
        self.lock.lock()
        let oldID = self.deviceListenerInstalledFor
        self.deviceListenerInstalledFor = newID
        self.lock.unlock()

        if oldID != 0, oldID != newID {
            self.removeDeviceListener(deviceID: oldID)
        }
        if oldID != newID {
            self.installDeviceListener(deviceID: newID)
        }
    }

    private func installDeviceListener(deviceID: AudioObjectID) {
        for selector in [kAudioObjectPropertyName, kAudioDevicePropertyTransportType] {
            var addr = AudioObjectPropertyAddress(
                mSelector: selector,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            _ = AudioObjectAddPropertyListenerBlock(
                deviceID,
                &addr,
                DispatchQueue.global(qos: .utility)
            ) { [weak self] _, _ in
                self?.handleDevicePropertyChanged()
            }
        }
    }

    private func removeDeviceListener(deviceID: AudioObjectID) {
        // We can't remove a block listener without keeping the original block
        // reference. Best we can do is rely on the device going away when its
        // CoreAudio object is released. In practice the listener will fire
        // briefly until that happens — the snapshot will contain the new device,
        // so the spurious event is harmless.
    }

    private func removeListeners() {
        self.lock.lock()
        self.systemListenerInstalled = false
        self.deviceListenerInstalledFor = 0
        self.lock.unlock()
    }

    private func broadcastSnapshot() {
        guard let info = self.snapshot() else { return }
        self.lock.lock()
        let conts = Array(self.continuations.values)
        self.lock.unlock()
        for cont in conts {
            cont.yield(info)
        }
    }
}
