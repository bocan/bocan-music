import Foundation

/// Phase 1 audit #19/#20/#21 + #6/#8: anti-pop fades and default-output-device
/// wiring, factored out of `AudioEngine.swift` to keep that file under the
/// SwiftLint length cap.
///
/// All members are `internal` and live in an `extension AudioEngine` so they
/// share the actor's isolation domain and have access to the private graph.
extension AudioEngine {
    // MARK: - Fade helpers (anti-pop)

    /// Ramp the player node's `volume` from its current value to `target`
    /// over ~`durationMs` ms in `steps` linear segments.  Used before any
    /// operation that is known to truncate playback mid-cycle (`stop`,
    /// `pause`, track change, seek).
    ///
    /// 10 ms is short enough to be inaudible as a "fade" but long enough to
    /// hide the discontinuity click at every sample rate up to 192 kHz.
    func fadePlayerNode(to target: Float, durationMs: Int = 10, steps: Int = 5) async {
        let node = self.graph.playerNode
        let from = node.volume
        guard from != target, steps > 0 else {
            node.volume = target
            return
        }
        let stepNanos = UInt64(durationMs) * 1_000_000 / UInt64(steps)
        for i in 1 ... steps {
            let progress = Float(i) / Float(steps)
            node.volume = from + (target - from) * progress
            try? await Task.sleep(nanoseconds: stepNanos)
        }
        node.volume = target
    }

    // MARK: - Device-change wiring

    /// Begin observing default-output-device changes.  Called by the App
    /// once after construction.  On change, the engine is reset and
    /// reconnected at the new hardware sample rate.
    public func startObservingOutputDeviceChanges() async {
        await self.deviceRouter.startObserving { [weak self] device in
            guard let self else { return }
            Task { await self.handleDefaultDeviceChange(device) }
        }
    }

    /// Stop observing device changes.  Symmetric with `startObserving…`.
    public func stopObservingOutputDeviceChanges() async {
        await self.deviceRouter.stopObserving()
    }

    /// Reconfigure the graph for a new default output device.  Runs on the
    /// engine actor — the CoreAudio listener fires on a HAL thread, so the
    /// hop onto this actor is mandatory before mutating AVFoundation state.
    func handleDefaultDeviceChange(_ device: DeviceInfo? = nil) async {
        let resumeAfter = self.isPlaying
        self.log.notice("audio.device.reconfigure.start", [
            "device": device?.name ?? "unknown",
            "wasPlaying": resumeAfter,
        ])
        await self.fadePlayerNode(to: 0)
        self.graph.playerNode.stop()
        await self.pump?.stop()
        self.pump = nil
        self.graph.reset()
        if resumeAfter {
            // Best-effort resume; if the new device fails to open, swallow
            // the error here (the public state stream will surface .failed).
            do {
                try await self.play()
                self.log.notice("audio.device.reconfigure.resumed", ["device": device?.name ?? "unknown"])
            } catch {
                self.log.error("audio.device.reconfigure.resume.failed", ["error": String(reflecting: error)])
            }
        } else {
            self.log.notice("audio.device.reconfigure.end", ["device": device?.name ?? "unknown"])
        }
    }
}
