import AVFoundation

// MARK: - AudioEngine + current-source facts (phase 27-5)

/// Read-only facts about the currently loaded source: the decoder's native
/// format, and the stream details FFmpeg-backed sources capture at open.
public extension AudioEngine {
    /// The native source format of the currently loaded track.
    ///
    /// Used by `GaplessScheduler` to determine format compatibility before
    /// scheduling the next track onto the same `AVAudioPlayerNode`.
    var sourceFormat: AVAudioFormat? {
        get async { self.decoder?.sourceFormat }
    }

    /// Stream facts from the currently audible decoder. Only FFmpeg-backed
    /// sources carry them; AVFoundation-decoded local files return nil.
    /// Served live so observed-title evidence upgrades the snapshot. Mind
    /// the gapless caveat on `decoder`: for the last ~0.8 s of a transition
    /// this describes the incoming track.
    var currentStreamDetails: StreamDetails? {
        get async {
            guard let dec = self.decoder as? FFmpegDecoder else { return nil }
            return await dec.liveDetails
        }
    }

    /// Replaces the title-forwarding task for the freshly installed decoder.
    /// Called from `load` and the reconnect rebuild; a decoder without ICY
    /// metadata yields a task that ends at its first (immediate) finish.
    internal func rewireTitleForwarding() {
        self.titleForwardTask?.cancel()
        guard let dec = self.decoder as? FFmpegDecoder else {
            self.titleForwardTask = nil
            return
        }
        let continuation = self.streamTitleContinuation
        self.titleForwardTask = Task {
            for await title in dec.titleUpdates {
                if Task.isCancelled { return }
                continuation.yield(title)
            }
        }
    }
}
