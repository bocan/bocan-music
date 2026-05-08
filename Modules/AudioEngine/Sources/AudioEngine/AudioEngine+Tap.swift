// MARK: - AudioEngine + Tap

/// Tap API — install/remove the audio tap for visualizer sample delivery.
public extension AudioEngine {
    // MARK: - Tap public API

    /// Install a new `AudioTap` on the main mixer and return its sample stream.
    ///
    /// Calling this when a tap is already installed is a no-op; the existing stream
    /// is returned.  The stream ends when `stopTap()` is called.
    func startTap() -> AsyncStream<AudioSamples> {
        if let existing = tap {
            return existing.samples
        }
        let newTap = AudioTap(bufferSize: 1024)
        self.tap = newTap
        // Install on the main mixer; format:nil → hardware format.
        newTap.install(on: self.graph.mixer)
        self.log.debug("tap.started")
        return newTap.samples
    }

    /// Remove the current tap from the mixer.  The stream returned by ``startTap()``
    /// will finish naturally on the consumer side after this call.
    func stopTap() {
        guard let current = tap else { return }
        current.remove(from: self.graph.mixer)
        self.tap = nil
        self.log.debug("tap.stopped")
    }
}
