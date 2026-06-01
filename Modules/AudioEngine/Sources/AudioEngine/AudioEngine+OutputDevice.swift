import AudioToolbox
@preconcurrency import AVFoundation
import CoreAudio
import Foundation
import Observability

// MARK: - App-only output device routing

/// Per-app output routing: send only this app's audio to a chosen CoreAudio
/// device (an AirPlay receiver, USB DAC, etc.) without moving the rest of the
/// system's audio.
///
/// The mechanism is `kAudioOutputUnitProperty_CurrentDevice` on the
/// `AVAudioEngine` output node's underlying AUHAL unit. Setting it pins the
/// engine to a device; until the user picks one we never touch it, so the
/// default AUHAL "follow the system default" behavior is preserved verbatim.
public extension AudioEngine {
    /// Route this app's audio to `deviceID`, or pass `nil` to follow the system
    /// default output again. Tears the output path down and rebuilds it on the
    /// new device, resuming playback if it was playing.
    func setOutputDevice(_ deviceID: AudioDeviceID?) async {
        self.managesOutputDevice = true
        self.pinnedOutputDeviceID = deviceID
        let target = deviceID ?? DeviceRouter.defaultOutputDevice()?.id
        self.log.notice("cast.engine.setOutputDevice", [
            "target": target.map(Int.init) ?? -1,
            "pinned": deviceID != nil,
        ])
        await self.reconfigureOutput(target: target)
    }

    /// The device this app's audio is currently pinned to, or `nil` when
    /// following the system default.
    var currentOutputDeviceID: AudioDeviceID? {
        self.pinnedOutputDeviceID
    }
}

extension AudioEngine {
    /// React to a system-default-output change. When the user has pinned a
    /// specific device the change does not move us; otherwise we follow it.
    ///
    /// `nil`-default param keeps the legacy call sites compiling.
    func handleDefaultDeviceChange(_ device: DeviceInfo? = nil) async {
        if self.managesOutputDevice, let pinned = self.pinnedOutputDeviceID {
            // Pinned (app-only): the system default moved but our audio stays put.
            self.log.notice("audio.device.defaultChanged.ignored", [
                "pinned": Int(pinned),
                "newDefault": device?.name ?? "?",
            ])
            return
        }
        // Following the system default: either the legacy implicit path
        // (managesOutputDevice == false, target nil so AUHAL keeps auto-following)
        // or an explicit "System Default" selection (managesOutputDevice == true,
        // so we re-pin the unit to each new default).
        let target = self.managesOutputDevice ? (device?.id ?? DeviceRouter.defaultOutputDevice()?.id) : nil
        await self.reconfigureOutput(target: target, device: device)
    }

    /// Tear down and rebuild the output path. When `target` is non-nil the HAL
    /// output unit is pinned to it; when `nil` the unit keeps AUHAL's implicit
    /// default-follow (the pre-feature path). Runs on the engine actor.
    func reconfigureOutput(target: AudioDeviceID?, device: DeviceInfo? = nil) async {
        let resumeAfter = self.isPlaying
        self.log.notice("audio.device.reconfigure.start", [
            "device": device?.name ?? target.map { "id=\($0)" } ?? "default",
            "wasPlaying": resumeAfter,
        ])
        await self.fadePlayerNode(to: 0)
        self.graph.playerNode.stop()
        await self.pump?.stop()
        self.pump = nil
        // The engine must be stopped before the AUHAL unit will accept a device
        // change; reset() alone leaves it running.
        self.graph.stop()
        self.graph.reset()
        if let target {
            self.applyOutputUnitDevice(target)
        }
        if resumeAfter {
            // Best-effort resume; if the new device fails to open, swallow the
            // error here (the public state stream will surface .failed).
            do {
                try await self.play()
                self.log.notice("audio.device.reconfigure.resumed", ["device": device?.name ?? "?"])
            } catch {
                self.log.error("audio.device.reconfigure.resume.failed", ["error": String(reflecting: error)])
            }
        } else {
            self.log.notice("audio.device.reconfigure.end", ["device": device?.name ?? "?"])
        }
    }

    /// Pin the engine's AUHAL output unit to `id`. The engine should be stopped.
    @discardableResult
    func applyOutputUnitDevice(_ id: AudioDeviceID) -> Bool {
        // The output unit is realized lazily; prepare() ensures it exists before
        // we read it after a reset().
        self.graph.engine.prepare()
        guard let unit = self.graph.engine.outputNode.audioUnit else {
            self.log.error("cast.engine.outputUnit.missing", ["deviceID": Int(id)])
            return false
        }
        var deviceID = id
        let status = AudioUnitSetProperty(
            unit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &deviceID,
            UInt32(MemoryLayout<AudioDeviceID>.size)
        )
        if status == noErr {
            self.log.notice("cast.engine.outputUnit.set", ["deviceID": Int(id)])
            return true
        }
        self.log.error("cast.engine.outputUnit.fail", ["deviceID": Int(id), "status": Int(status)])
        return false
    }
}
