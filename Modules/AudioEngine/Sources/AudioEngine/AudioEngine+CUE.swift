import Foundation

// MARK: - AudioEngine + CUE segment support

/// Playback of a single CUE-defined segment [start, end) of an already-loaded file.
public extension AudioEngine {
    /// Configure the engine to play a specific segment [start, end) of the
    /// already-loaded audio file.
    ///
    /// Call this after `load(_:)` and before `play()`. The method seeks the decoder
    /// to `start`, resets `currentTime` to zero (NowPlaying shows 0-based progress
    /// within the segment), and clamps `duration` to the segment length.
    ///
    /// Passing `end: nil` means play to the decoder's natural EOF (last CUE track).
    func setSegment(start: TimeInterval, end: TimeInterval?) async throws {
        guard let dec = self.decoder else { return }
        let fileDuration = dec.duration
        try await dec.seek(to: start)
        self.segmentStart = start
        self.segmentEndTime = end
        self._currentTime = 0
        self._duration = (end ?? fileDuration) - start
        self.log.debug("engine.setSegment", [
            "start": start,
            "end": end as Any,
            "virtualDuration": self._duration,
        ])
    }
}
