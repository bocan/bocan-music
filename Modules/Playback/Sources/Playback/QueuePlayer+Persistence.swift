import AudioEngine
import Foundation
import Observability
import Persistence

// MARK: - QueuePlayer + Queue persistence

extension QueuePlayer {
    // MARK: Queue change subscription (for persistence)

    func subscribeToQueueChanges(stream: AsyncStream<QueueChange>) async {
        for await _ in stream {
            let items = await queue.items
            let currentIndex = await queue.currentIndex
            let repeatMode = await queue.repeatMode
            let shuffleState = await queue.shuffleState
            await self.persistence.scheduleSave(
                items: items,
                currentIndex: currentIndex,
                repeatMode: repeatMode,
                shuffleState: shuffleState
            )
        }
    }

    // MARK: Queue restore

    func restoreQueue() async {
        guard let saved = await persistence.restore() else { return }
        if let warning = saved.schemaWarning {
            self.log.warning("queueplayer.queue.schema_warning", ["message": warning])
            self.schemaWarningContinuation?.yield(warning)
            // Queue is empty on a schema mismatch — nothing more to restore.
            return
        }
        await self.queue.replace(with: saved.items, startAt: saved.currentIndex ?? 0)
        await self.queue.setRepeatMode(saved.repeatMode)
        if case let .on(seed) = saved.shuffleState {
            await self.queue.setShuffle(true, seed: seed)
        }
        self.log.debug("queueplayer.queue.restored", ["count": saved.items.count])

        // Identify items whose backing files have been moved or deleted while
        // the app was closed so the UI can render them as disabled rows.
        await self.recomputeUnavailableItems(items: saved.items)

        // If a resume position was saved on last quit, pre-load the current item
        // and seek to it (without playing) so the user can resume where they left off.
        let savedPosition = UserDefaults.standard.double(forKey: "playback.resumePosition")
        guard savedPosition > 0 else { return }
        UserDefaults.standard.removeObject(forKey: "playback.resumePosition")

        // Live radio cannot resume: there is no position to return to, and a
        // seek on a live ICY stream degrades into FFmpeg reading the stream
        // at the server's pace while the transport gate is held, wedging
        // every subsequent play (launch hang: restoreQueue -> seek ->
        // SSL_read). Restore the queue rows only; pressing play cold-starts
        // the station fresh.
        if let current = await self.queue.currentItem,
           case .internetRadio = current.playableSource {
            self.log.debug("queueplayer.position.restore.skippedLiveStream", [:])
            return
        }

        // A podcast item carries its own per-episode resume position, applied
        // inside `loadAndPlay`. The global last-position must not double-seek it
        // (gotcha: the two resume paths must not fight). Pre-load so the
        // per-episode seek runs, but skip the global seek for a podcast item.
        let currentIsPodcast = if let current = await self.queue.currentItem,
                                  case .podcast = current.playableSource {
            true
        } else {
            false
        }

        do {
            try await self.loadCurrentItem()
            if currentIsPodcast {
                self.log.debug("queueplayer.position.restore.podcastPerEpisode", [:])
            } else {
                try await self.engine.seek(to: savedPosition)
                self.log.debug("queueplayer.position.restored", ["position": savedPosition])
            }
        } catch {
            self.log.warning("queueplayer.position.restore.failed", ["error": String(reflecting: error)])
        }
    }

    // MARK: Saved state

    /// Captures the current engine position to `UserDefaults` so the next launch
    /// can seek the restored track to where the user left off.
    ///
    /// Call this from `applicationWillTerminate` (or the equivalent notification).
    /// Safe to call when nothing is playing — it is a no-op when position is zero.
    public func savePositionForSuspend() async {
        // A podcast item persists its per-episode position through the resolver,
        // independent of the global last-position key (which podcast items
        // ignore on restore). Do this first so it is not gated by the global
        // `position > 0` guard below.
        await self.persistPodcastPositionIfNeeded()

        let position = await self.engine.currentTime
        guard position > 0 else { return }
        UserDefaults.standard.set(position, forKey: "playback.resumePosition")
        self.log.debug("queueplayer.position.saved", ["position": position])
    }

    /// Stops playback, clears the queue, and erases all persisted queue and
    /// position state.  Called when the user taps "Start Fresh" in the
    /// crash-recovery banner so the next launch begins with an empty queue.
    public func clearSavedState() async {
        await self.stop()
        await self.queue.clear()
        await self.persistence.scheduleSave(
            items: [],
            currentIndex: nil,
            repeatMode: .off,
            shuffleState: .off
        )
        UserDefaults.standard.removeObject(forKey: "playback.resumePosition")
        self.log.info("queueplayer.saved_state.cleared")
    }

    // MARK: - Unavailable items

    /// Internal rather than private so the fan-out can be driven directly in
    /// tests, without staging missing files on disk.
    func emitUnavailableItems(_ ids: Set<QueueItem.ID>) {
        for continuation in self.unavailableSubscribers.values {
            continuation.yield(ids)
        }
    }

    /// Internal for tests: proves `onTermination` unregisters a subscriber.
    var unavailableSubscriberCount: Int {
        self.unavailableSubscribers.count
    }

    /// Walks `items` and marks any whose `fileURL` no longer exists on disk.
    /// Acquires the matching library-root security scope once per root so the
    /// existence check works under the macOS sandbox.  Emits the resulting set
    /// to every subscriber exactly once.
    private func recomputeUnavailableItems(items: [QueueItem]) async {
        guard !items.isEmpty else {
            if !self.unavailableItemIDs().isEmpty {
                self.storeAndEmitUnavailableItems([])
            }
            return
        }

        // With no roots nothing can be scoped, so every file-backed item reads
        // as missing and the whole queue greys out unexplained (#494).
        var roots: [LibraryRoot] = []
        do {
            roots = try await self.rootRepo.fetchAll()
        } catch {
            self.log.warning("queueplayer.availability.rootsUnavailable", [
                "error": String(reflecting: error),
            ])
        }
        var handles: [String: RootScopeHandle] = [:]
        defer { handles.removeAll() } // RAII releases scopes

        var missing: Set<QueueItem.ID> = []
        for item in items {
            // Only file-backed items can go missing on disk. Remote sources
            // (internet radio, Subsonic, streamed podcasts) carry http(s)
            // URLs whose `.path` never exists locally; checking them marked
            // every restored station "(missing)" and disabled its row.
            guard let url = URL(string: item.fileURL),
                  url.scheme == nil || url.isFileURL else { continue }
            let path = url.path
            guard !path.isEmpty else {
                missing.insert(item.id)
                continue
            }

            self.memoiseRootScope(forPath: path, roots: roots, handles: &handles)

            if !FileManager.default.fileExists(atPath: path) {
                missing.insert(item.id)
            }
        }

        self.storeAndEmitUnavailableItems(missing)
        if !missing.isEmpty {
            self.log.warning("queueplayer.queue.unavailable", [
                "missing": missing.count,
                "total": items.count,
            ])
        }
    }

    /// Acquire (and memoise) the scope for the matching root so the
    /// sandbox grants `fileExists` access to files inside it.
    private func memoiseRootScope(
        forPath path: String,
        roots: [LibraryRoot],
        handles: inout [String: RootScopeHandle]
    ) {
        if let root = roots.first(where: {
            let prefix = $0.path == "/" ? "/" : $0.path + "/"
            return path.hasPrefix(prefix)
        }), handles[root.path] == nil {
            var stale = false
            do {
                let url = try URL(
                    resolvingBookmarkData: root.bookmark,
                    options: .withSecurityScope,
                    relativeTo: nil,
                    bookmarkDataIsStale: &stale
                )
                if let handle = RootScopeHandle(url: url) {
                    handles[root.path] = handle
                }
            } catch {
                // Files under this root then read as missing (#494).
                self.log.warning("queueplayer.availability.bookmarkUnresolvable", [
                    "rootPath": root.path,
                    "error": String(reflecting: error),
                ])
            }
        }
    }
}
