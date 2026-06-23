import Foundation

// MARK: - AudioEngine + Reconnect (streamed-source recovery)

/// Recovery for a decoder that dies mid-playback. The proximate trigger is a
/// streamed podcast / internet-radio source whose HTTP connection drops: FFmpeg
/// returns an I/O error from its read, the `BufferPump` feed loop aborts, and
/// without this path the pump would die unseen while the player node's sample
/// clock kept advancing — silence with a still-moving position slider and a
/// transport stuck at `.playing`.
///
/// FFmpeg's own per-decoder reconnect (`FFmpegDecoder.openOptions`) heals
/// transient blips first and invisibly. This is the backstop for when that gives
/// up: rebuild the stream from a fresh decoder a few times, then fail cleanly.
extension AudioEngine {
    /// Max consecutive app-level reconnect attempts before a streamed source is
    /// declared dead and surfaced as `.failed`. FFmpeg's own per-decoder reconnect
    /// (`FFmpegDecoder.openOptions`) heals transient blips first; this is the
    /// backstop for when that gives up entirely.
    static var maxReconnectAttempts: Int {
        3
    }

    /// How long a reconnected stream must play cleanly before its retry budget is
    /// restored, so a long flaky stream is not capped for its whole length.
    static var reconnectStabilizeWindow: TimeInterval {
        20
    }

    /// Called by a `BufferPump` when its feed loop aborts on a real decode error
    /// (cancellation is never reported here). Attempts an app-level reconnect for
    /// streamed sources, else surfaces a terminal `.failed` state.
    func handlePumpError(_ error: Error, firedBy pumpID: String) async {
        // Ignore a failure from a pump that is no longer active: a load or seek
        // already replaced it, so its error is moot.
        guard pumpID == self.pump?.id else {
            self.log.debug("engine.pump.error.stale", [
                "firedBy": pumpID, "current": self.pump?.id ?? "nil",
            ])
            return
        }

        // Serialize the recovery against user transport actions (play/pause/seek/
        // load), exactly as those paths serialize against each other.
        await self.acquireTransport()
        defer { self.releaseTransport() }

        // A transport action may have swapped the pump while we waited for the gate.
        guard pumpID == self.pump?.id else { return }

        self.cancelReconnectStabilize()
        let position = await self.currentTime

        // Only streamed (HTTP/HTTPS) sources are worth rebuilding. A local-file
        // decode error is permanent (corrupt or removed file), so fail it at once.
        let isStream = (self.currentURL?.scheme?.lowercased()).map {
            $0 == "http" || $0 == "https"
        } ?? false

        if isStream, let url = self.currentURL, self.reconnectAttempts < Self.maxReconnectAttempts {
            self.reconnectAttempts += 1
            self.log.warning("engine.stream.reconnect.start", [
                "attempt": self.reconnectAttempts,
                "max": Self.maxReconnectAttempts,
                "position": position,
                "error": String(reflecting: error),
            ])
            do {
                try await self.rebuildStream(url: url, at: position)
                self.log.info("engine.stream.reconnect.ok", ["attempt": self.reconnectAttempts])
                // Healthy again: start the clock that restores the retry budget if
                // the stream now holds for a while.
                self.scheduleReconnectStabilize()
                return
            } catch {
                self.log.error("engine.stream.reconnect.failed", [
                    "attempt": self.reconnectAttempts,
                    "error": String(reflecting: error),
                ])
                // Fall through to terminal failure.
            }
        }

        // Freeze the playhead at the failure point: once `.failed` is emitted,
        // `currentTime` stops deriving from the (now stale) node clock and returns
        // `_currentTime`, so bank the live position into it first.
        self._currentTime = position
        self._playerTimeOffset = 0
        await self.failPlayback(error)
    }

    /// Tear down the dead decoder/pump and rebuild playback for `url` from
    /// `position`, resuming play. Mirrors `load` + seek-before-play and reuses
    /// `performPlay` to build the fresh pump. Throws if the new decoder cannot be
    /// opened or sought, in which case the caller surfaces `.failed`.
    private func rebuildStream(url: URL, at position: TimeInterval) async throws {
        self.graph.playerNode.stop()
        await self.pump?.stop()
        self.pump = nil
        if let prev = self.decoder { await prev.close() }
        self.decoder = nil

        let dec = try DecoderFactory.make(for: url)
        try await dec.seek(to: position)
        self.decoder = dec
        self._duration = dec.duration
        self._currentTime = position
        self._playerTimeOffset = 0
        // performPlay (pump == nil) cold-starts a new pump from the fresh decoder.
        try await self.performPlay()
    }

    /// Stop the node, drop the pump, and emit a terminal `.failed`. Position then
    /// freezes (it advances only while `_state == .playing`) and the UI stops
    /// reporting playback.
    private func failPlayback(_ error: Error) async {
        self.graph.playerNode.stop()
        await self.pump?.stop()
        self.pump = nil
        let ae = error as? AudioEngineError ?? .decoderFailure(codec: "stream", underlying: error)
        self.emit(.failed(ae))
        self.log.error("engine.playback.failed", ["error": String(reflecting: ae)])
    }

    /// Restore the reconnect budget after the stream has been healthy long enough.
    func scheduleReconnectStabilize() {
        self.reconnectStabilizeTask?.cancel()
        self.reconnectStabilizeTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.reconnectStabilizeWindow))
            guard let self, !Task.isCancelled else { return }
            await self.resetReconnectAttempts()
        }
    }

    /// Cancel a pending stabilize reset (on error, load, or stop).
    func cancelReconnectStabilize() {
        self.reconnectStabilizeTask?.cancel()
        self.reconnectStabilizeTask = nil
    }

    private func resetReconnectAttempts() {
        self.reconnectAttempts = 0
    }
}
