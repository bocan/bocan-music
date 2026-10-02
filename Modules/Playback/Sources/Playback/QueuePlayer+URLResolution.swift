import AudioEngine
import Foundation
import Observability
import Persistence

// MARK: - ResolvedPlaybackURL

/// A URL the engine can open, with the security scopes that were started to
/// reach it. The caller releases them once the decoder has opened the file.
struct ResolvedPlaybackURL {
    /// The URL to hand to the engine.
    let url: URL
    /// True when `url` came from the item's own bookmark, so the caller must
    /// call `stopAccessingSecurityScopedResource()` on it.
    var resolvedFromPerFileBookmark = false
    /// The library root's scope, held while it is set.
    var rootScope: RootScopeHandle?
}

// MARK: - QueuePlayer + URL resolution

extension QueuePlayer {
    // MARK: Playable URL for a load

    /// Resolve a playable URL.
    ///
    /// Priority order:
    ///  1. Remote `.subsonic` source — resolved via `SubsonicStreamResolving`
    ///     to a local file URL backed by `SubsonicStreamCache`.
    ///  2. Per-file security-scoped bookmark (stored at scan time).
    ///  3. Root-folder security-scoped bookmark (covers all files under the root).
    ///
    /// We go directly to the root scope when the per-file bookmark is absent (nil)
    /// because the raw file:// URL is inaccessible in the sandbox without a scope.
    func resolvePlayableURL(for item: QueueItem) async throws -> ResolvedPlaybackURL {
        if case let .internetRadio(streamURL) = item.playableSource {
            // Live HTTP radio bypasses bookmarks and the Subsonic stream
            // cache. Hand the URL straight to the engine; FFmpeg decodes
            // the stream directly.
            self.log.debug("queueplayer.internetRadio.start", ["url": streamURL.absoluteString])
            return ResolvedPlaybackURL(url: streamURL)
        } else if case let .podcast(feedURL, guid) = item.playableSource {
            return try await ResolvedPlaybackURL(url: self.resolvePodcastURL(feedURL: feedURL, guid: guid, item: item))
        } else if case let .subsonic(serverID, songID) = item.playableSource {
            return try await ResolvedPlaybackURL(url: self.resolveSubsonicURL(serverID: serverID, songID: songID, item: item))
        }
        return try await self.resolveLocalURL(for: item)
    }

    /// Podcast episode: the resolver returns a remote https:// enclosure
    /// (DecoderFactory routes http(s) to FFmpegDecoder) or a local
    /// file:// download. No bookmark, no Subsonic cache.
    private func resolvePodcastURL(feedURL: URL, guid: String, item: QueueItem) async throws -> URL {
        guard let resolver = self.podcastResolver else {
            self.log.error("queueplayer.podcast.no_resolver", ["guid": guid])
            throw PlaybackError.incompatibleFormat(reason: "No podcast resolver configured")
        }
        self.log.debug("queueplayer.podcast.resolve.start", ["guid": guid])
        do {
            return try await resolver.audioURL(feedURL: feedURL, episodeGUID: guid)
        } catch {
            self.log.error(
                "queueplayer.podcast.resolve.failed",
                ["guid": guid, "error": String(reflecting: error)]
            )
            throw PlaybackError.bookmarkResolutionFailed(trackID: item.trackID, underlying: error)
        }
    }

    /// Subsonic song: the resolver returns a local file URL backed by the
    /// stream cache.
    private func resolveSubsonicURL(serverID: UUID, songID: String, item: QueueItem) async throws -> URL {
        guard let resolver = self.subsonicResolver else {
            self.log.error("queueplayer.subsonic.no_resolver", ["songID": songID])
            throw PlaybackError.bookmarkResolutionFailed(
                trackID: item.trackID,
                underlying: URLError(.unsupportedURL)
            )
        }
        self.log.debug("queueplayer.subsonic.resolve.start", ["serverID": serverID, "songID": songID])
        do {
            return try await resolver.localFileURL(serverID: serverID, songID: songID)
        } catch {
            self.log.error(
                "queueplayer.subsonic.resolve.failed",
                ["serverID": serverID, "songID": songID, "error": String(reflecting: error)]
            )
            throw PlaybackError.bookmarkResolutionFailed(trackID: item.trackID, underlying: error)
        }
    }

    /// Local file: the per-file bookmark first, then the library root's scope.
    private func resolveLocalURL(for item: QueueItem) async throws -> ResolvedPlaybackURL {
        var resolvedFromPerFileBookmark = false
        var rootScope: RootScopeHandle?
        let url: URL

        if item.bookmark != nil {
            // Attempt per-file bookmark first.
            do {
                url = try item.resolvedURL()
                resolvedFromPerFileBookmark = true
            } catch {
                self.log.warning(
                    "queueplayer.url.bookmark_failed",
                    ["trackID": item.trackID, "error": String(reflecting: error)]
                )
                // Per-file bookmark stale/invalid — fall back to root scope.
                guard let rawURL = URL(string: item.fileURL) else {
                    self.log.error("queueplayer.url.bad_file_url", ["trackID": item.trackID, "url": item.fileURL])
                    throw PlaybackError.bookmarkResolutionFailed(trackID: item.trackID, underlying: error)
                }
                if let scope = try await self.acquireRootScope(for: item.fileURL) {
                    rootScope = scope
                } else {
                    // No root scope found — attempt raw URL anyway, matching the
                    // behaviour of the no-per-file-bookmark path (works in dev / non-sandboxed).
                    self.log.warning("queueplayer.url.no_root", ["trackID": item.trackID])
                }
                url = rawURL
            }
        } else {
            // No per-file bookmark — use root scope directly to stay within sandbox.
            self.log.debug("queueplayer.url.no_per_file_bookmark", ["trackID": item.trackID])
            guard let rawURL = URL(string: item.fileURL) else {
                self.log.error("queueplayer.url.bad_file_url", ["trackID": item.trackID, "url": item.fileURL])
                throw PlaybackError.bookmarkResolutionFailed(
                    trackID: item.trackID,
                    underlying: URLError(.badURL)
                )
            }
            if let scope = try await self.acquireRootScope(for: item.fileURL) {
                rootScope = scope
            } else {
                // No root scope found — attempt raw URL anyway (works outside sandbox).
                self.log.warning("queueplayer.url.no_root_scope", ["trackID": item.trackID])
            }
            url = rawURL
        }
        return ResolvedPlaybackURL(
            url: url,
            resolvedFromPerFileBookmark: resolvedFromPerFileBookmark,
            rootScope: rootScope
        )
    }

    // MARK: Gapless next URL resolution

    /// Resolve the URL the same way we would for a normal load.
    func resolvePrefetchURL(for item: QueueItem) async throws -> ResolvedPlaybackURL {
        var resolvedFromPerFileBookmark = false
        var rootScope: RootScopeHandle?
        let url: URL

        if item.bookmark != nil {
            do {
                url = try item.resolvedURL()
                resolvedFromPerFileBookmark = true
            } catch {
                // Per-file bookmark stale/invalid — fall back to root scope.
                guard let rawURL = URL(string: item.fileURL) else {
                    throw PlaybackError.bookmarkResolutionFailed(trackID: item.trackID, underlying: error)
                }
                if let scope = try await self.acquireRootScope(for: item.fileURL) {
                    rootScope = scope
                }
                // No root scope — attempt raw URL anyway (mirrors loadAndPlay behaviour).
                url = rawURL
            }
        } else {
            guard let rawURL = URL(string: item.fileURL) else {
                throw PlaybackError.bookmarkResolutionFailed(
                    trackID: item.trackID,
                    underlying: URLError(.badURL)
                )
            }
            if let scope = try await self.acquireRootScope(for: item.fileURL) {
                rootScope = scope
            }
            url = rawURL
        }
        return ResolvedPlaybackURL(
            url: url,
            resolvedFromPerFileBookmark: resolvedFromPerFileBookmark,
            rootScope: rootScope
        )
    }

    // MARK: Root-scope fallback

    /// Finds the library root that contains `fileURLString`, resolves its
    /// security-scoped bookmark, starts accessing the scope, and returns an
    /// RAII handle whose `deinit` releases the scope.  Caller binds to a
    /// `let` for the duration of the operation; no manual `defer` is needed.
    ///
    /// Returns `nil` when no matching root is found or when the root bookmark
    /// cannot be resolved.
    private func acquireRootScope(for fileURLString: String) async throws -> RootScopeHandle? {
        // No roots means no scope, and the file open below then fails with a
        // permission error that names the file, never this cause (#494).
        var roots: [LibraryRoot] = []
        do {
            roots = try await self.rootRepo.fetchAll()
        } catch {
            self.log.warning("queueplayer.root.rootsUnavailable", ["error": String(reflecting: error)])
        }
        // fileURLString is stored as url.absoluteString ("file:///path/to/file.mp3")
        // while root.path is url.path ("/path/to/folder") — compare via the path component.
        guard let filePath = URL(string: fileURLString)?.path else {
            return nil
        }
        // Use a directory-boundary-safe prefix check: append "/" so that a root at
        // "/Users/chris/Music" does NOT falsely match "/Users/chris/Music2/song.mp3".
        guard let root = roots.first(where: {
            let prefix = $0.path == "/" ? "/" : $0.path + "/"
            return filePath.hasPrefix(prefix)
        }) else {
            self.log.warning("queueplayer.root.no_match", ["filePath": filePath])
            return nil
        }
        var isStale = false
        let rootURL: URL
        do {
            rootURL = try URL(
                resolvingBookmarkData: root.bookmark,
                options: .withSecurityScope,
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            )
        } catch {
            // This is the usual root cause of "that track will not play", so
            // the reason belongs beside it (#494).
            self.log.error("queueplayer.root.bookmark_unresolvable", [
                "rootPath": root.path,
                "error": String(reflecting: error),
            ])
            return nil
        }
        guard let handle = RootScopeHandle(url: rootURL) else {
            self.log.error("queueplayer.root.scope_denied", ["rootPath": root.path])
            return nil
        }
        if isStale, let rootID = root.id {
            await self.refreshStaleBookmark(of: root, rootID: rootID, using: handle)
        }
        return handle
    }

    /// Bookmark data was valid but stale — refresh it while we hold an active scope
    /// so that future launches don't need to fall back to this recovery path.
    private func refreshStaleBookmark(of root: LibraryRoot, rootID: Int64, using handle: RootScopeHandle) async {
        let freshData: Data?
        do {
            freshData = try handle.url.bookmarkData(
                options: .withSecurityScope,
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
        } catch {
            // The stale bookmark stays, so every later launch takes this
            // same recovery path (#494).
            self.log.warning("queueplayer.root.bookmark_refresh_mintFailed", [
                "rootID": rootID,
                "error": String(reflecting: error),
            ])
            freshData = nil
        }
        if let freshData {
            var updated = root
            updated.bookmark = freshData
            do {
                try await self.rootRepo.upsert(updated)
                self.log.info("queueplayer.root.bookmark_refreshed", ["rootID": rootID])
            } catch {
                self.log.warning("queueplayer.root.bookmark_refresh_failed", ["rootID": rootID, "error": String(reflecting: error)])
            }
        }
    }
}
