import Foundation
import Metadata
import Observability
import Persistence

// MARK: - LyricsService

/// CRUD coordinator for lyrics, resolving priority across embedded, sidecar,
/// user-edited, and network-fetched sources.
///
/// Create one instance at app-launch and pass it wherever lyrics are needed.
public actor LyricsService {
    // MARK: - Dependencies

    private let database: Database
    private let lyricsRepo: LyricsRepository
    private let trackRepo: TrackRepository
    private let artistRepo: ArtistRepository
    private let albumRepo: AlbumRepository
    private let rootRepo: LibraryRootRepository
    private let fetcher: (any LRClibClientProtocol)?
    private let editService: MetadataEditService?
    private let log = AppLogger.make(.library)

    // MARK: - Init

    /// - Parameters:
    ///   - database: The shared application database.
    ///   - fetcher: Optional LRClib client; pass `nil` when opt-in fetch is disabled.
    ///   - editService: When present, embedding lyrics into the audio file goes
    ///     through the full edit pipeline (security scoping, atomic write, backup
    ///     ring, mtime stamping). The legacy direct write is only a fallback.
    public init(
        database: Database,
        fetcher: (any LRClibClientProtocol)?,
        editService: MetadataEditService? = nil
    ) {
        self.database = database
        self.lyricsRepo = LyricsRepository(database: database)
        self.trackRepo = TrackRepository(database: database)
        self.artistRepo = ArtistRepository(database: database)
        self.albumRepo = AlbumRepository(database: database)
        self.rootRepo = LibraryRootRepository(database: database)
        self.fetcher = fetcher
        self.editService = editService
    }

    // MARK: - Public API

    /// Resolves the best available lyrics for `trackID` using the priority
    /// stored in `UserDefaults` under `"lyrics.sourcePriority"`.
    ///
    /// **preferSynced** (default): user → sidecar .lrc → embedded synced → lrclib → embedded unsynced
    /// **preferEmbedded / preferUser**: user → embedded synced → sidecar .lrc → embedded unsynced → lrclib
    public func lyrics(for trackID: Int64) async throws -> LyricsDocument? {
        try await self.lyricsWithSource(for: trackID).0
    }

    /// Resolves the best available lyrics for `trackID` and returns it paired with
    /// the winning source label (`"user"`, `"sidecar"`, `"embedded"`, `"lrclib"`, or `nil`).
    public func lyricsWithSource(for trackID: Int64) async throws -> (LyricsDocument?, String?) {
        let row = try await lyricsRepo.fetch(trackID: trackID)

        // User edits always win regardless of priority.
        if let row, row.source == "user" {
            return (self.parse(row: row), "user")
        }

        let priority = LyricsSourcePriority(
            rawValue: UserDefaults.standard.string(forKey: "lyrics.sourcePriority") ?? ""
        ) ?? .preferSynced

        switch priority {
        case .preferSynced:
            if let sidecar = try await self.loadSidecar(for: trackID) { return (sidecar, "sidecar") }
            if let row, row.source == "embedded", row.isSynced { return (self.parse(row: row), "embedded") }
            if let row, row.source == "lrclib" { return (self.parse(row: row), "lrclib") }
            if let row, row.source == "embedded", !row.isSynced { return (self.parse(row: row), "embedded") }

        case .preferEmbedded, .preferUser:
            if let row, row.source == "embedded", row.isSynced { return (self.parse(row: row), "embedded") }
            if let sidecar = try await self.loadSidecar(for: trackID) { return (sidecar, "sidecar") }
            if let row, row.source == "embedded", !row.isSynced { return (self.parse(row: row), "embedded") }
            if let row, row.source == "lrclib" { return (self.parse(row: row), "lrclib") }
        }

        return (nil, nil)
    }

    /// Saves `doc` as the lyrics for `trackID`.
    ///
    /// - Parameters:
    ///   - doc: Pass `nil` to delete existing lyrics.
    ///   - source: The source string to record (e.g. `"user"`, `"lrclib"`). Defaults to `"user"`.
    ///   - persistToFile: When `true`, also writes the lyrics text back into the audio file's tags.
    public func setLyrics(
        _ doc: LyricsDocument?,
        for trackID: Int64,
        source: String = "user",
        persistToFile: Bool = false
    ) async throws {
        guard let doc else {
            try await self.lyricsRepo.delete(trackID: trackID)
            self.log.debug("lyrics.deleted", ["track": trackID])
            return
        }

        let isSynced: Bool
        let rawText: String
        switch doc {
        case let .unsynced(text):
            isSynced = false
            rawText = text
        case let .synced(lines, _):
            isSynced = true
            rawText = doc.toLRC()
            _ = lines // silence unused warning
        }

        let record = Lyrics(
            trackID: trackID,
            lyricsText: rawText,
            isSynced: isSynced,
            source: source,
            offsetMS: doc.offsetMS
        )
        try await self.lyricsRepo.save(record)

        self.log.debug("lyrics.saved", ["track": trackID, "source": source])

        if persistToFile {
            try await self.writeToFile(doc: doc, trackID: trackID)
            // The edit pipeline writes its own lyrics DB row (source "user",
            // no offset); re-save the canonical record so source and offset
            // survive the embed.
            try await self.lyricsRepo.save(record)
        }
    }

    /// Unconditionally fetches lyrics from LRClib for `trackID`, replacing any
    /// existing record regardless of its source.  Skips only if no `fetcher` is
    /// configured.
    ///
    /// The `lyrics.lrclibEnabled` preference is intentionally **not** checked here;
    /// it is the caller's responsibility to gate the action on that preference.
    /// Likewise `embedInFile` mirrors the caller's "Embed in file" setting: an
    /// explicit fetch is a deliberate user action, so unlike the playback
    /// auto-fetch it may write the file. Defaults to `false`.
    ///
    /// Returns the fetched document, or `nil` when the fetcher is absent or no
    /// match is found on LRClib.
    public func forceFetch(for trackID: Int64, embedInFile: Bool = false) async throws -> LyricsDocument? {
        guard let fetcher else { return nil }
        guard let track = try? await trackRepo.fetch(id: trackID) else { return nil }

        self.log.debug("lrclib.forceFetch.start", ["track": trackID])

        let artistName: String = if let aid = track.artistID,
                                    let artist = try? await artistRepo.fetch(id: aid) {
            artist.name
        } else {
            ""
        }
        let albumTitle: String? = if let aid = track.albumID, let album = try? await albumRepo.fetch(id: aid) {
            album.title
        } else {
            nil
        }

        let doc = try await fetcher.get(
            artist: artistName,
            title: track.title ?? "",
            album: albumTitle,
            duration: track.duration
        )

        if let doc {
            try await self.setLyrics(doc, for: trackID, source: "lrclib", persistToFile: embedInFile)
            self.log.debug("lrclib.forceFetch.saved", ["track": trackID, "embedded": embedInFile])
        } else {
            self.log.debug("lrclib.forceFetch.notFound", ["track": trackID])
        }
        return doc
    }

    /// If no lyrics exist for `trackID`, the user has enabled LRClib fetch, and a
    /// `fetcher` is configured, attempts to retrieve lyrics and saves the result.
    ///
    /// Returns the fetched document, or `nil` when nothing is available, consent
    /// is absent, or the fetcher is `nil`.
    public func autoFetchIfMissing(for trackID: Int64) async throws -> LyricsDocument? {
        guard let fetcher,
              UserDefaults.standard.bool(forKey: "lyrics.lrclibEnabled") else { return nil }

        // Only skip fetch if the user has manually edited, we already have an LRClib
        // result, or a sidecar .lrc file is present.  Embedded (unsynced) lyrics don't
        // block the fetch — LRClib may have synced lyrics that are better.
        let row = try await lyricsRepo.fetch(trackID: trackID)
        if let row, row.source == "user" { return self.parse(row: row) }
        if let row, row.source == "lrclib" { return self.parse(row: row) }
        if let sidecar = try await self.loadSidecar(for: trackID) { return sidecar }

        guard let track = try? await trackRepo.fetch(id: trackID) else { return nil }

        self.log.debug("lrclib.fetch.start", ["track": trackID])

        let artistName: String = if let aid = track.artistID, let artist = try? await artistRepo.fetch(id: aid) {
            artist.name
        } else {
            ""
        }
        let albumTitle: String? = if let aid = track.albumID, let album = try? await albumRepo.fetch(id: aid) {
            album.title
        } else {
            nil
        }
        let doc = try await fetcher.get(
            artist: artistName,
            title: track.title ?? "",
            album: albumTitle,
            duration: track.duration
        )

        if let doc {
            try await self.setLyrics(doc, for: trackID, source: "lrclib")
            self.log.debug("lrclib.fetch.saved", ["track": trackID])
        } else {
            self.log.debug("lrclib.fetch.notFound", ["track": trackID])
        }
        return doc
    }

    /// Returns a stream that re-emits the resolved ``LyricsDocument`` whenever the
    /// underlying DB row changes.  Each emission runs the full priority resolution
    /// (including sidecar check and `lyrics.sourcePriority` setting).
    public func observe(_ trackID: Int64) -> AsyncThrowingStream<LyricsDocument?, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let inner = await self.lyricsRepo.observe(trackID: trackID)
                    for try await _ in inner {
                        try Task.checkCancellation()
                        let doc = try await self.lyrics(for: trackID)
                        continuation.yield(doc)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Like ``observe(_:)`` but also yields the winning source label alongside each document.
    ///
    /// Source labels: `"user"`, `"sidecar"`, `"embedded"`, `"lrclib"`, or `nil` when no lyrics.
    public func observeWithSource(_ trackID: Int64) -> AsyncThrowingStream<(LyricsDocument?, String?), Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let inner = await self.lyricsRepo.observe(trackID: trackID)
                    for try await _ in inner {
                        try Task.checkCancellation()
                        let result = try await self.lyricsWithSource(for: trackID)
                        continuation.yield(result)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: - Private

    private func parse(row: Lyrics) -> LyricsDocument? {
        guard let text = row.lyricsText, !text.isEmpty else { return nil }
        var doc = LRCParser.parseDocument(text)
        // Apply the stored per-track display offset on top of any in-file [offset:] tag.
        if row.offsetMS != 0 {
            switch doc {
            case let .synced(lines, existingOffset):
                doc = .synced(lines: lines, offsetMS: existingOffset + row.offsetMS)
            case .unsynced:
                break
            }
        }
        return doc
    }

    private func writeToFile(doc: LyricsDocument, trackID: Int64) async throws {
        let lyricsText: String = switch doc {
        case let .unsynced(text):
            text
        case .synced:
            doc.toLRC()
        }

        // Preferred path: the full edit pipeline. It handles root-folder and
        // per-file security scopes, writes atomically with a backup, verifies
        // by re-reading, and stamps the DB row's mtime so the next scan does
        // not raise a false "file changed on disk" conflict.
        if let editService {
            var patch = TrackTagPatch()
            switch doc {
            case .unsynced:
                patch.lyrics = .some(lyricsText)
            case .synced:
                patch.syncedLyrics = .some(lyricsText)
                patch.lyrics = .some(nil) // documented pairing: clear the plain field
            }
            do {
                try await editService.edit(trackID: trackID, patch: patch)
                self.log.debug("lyrics.fileWrite.done", ["track": trackID, "via": "editService"])
            } catch {
                self.log.error("lyrics.fileWrite.failed", ["track": trackID, "error": String(reflecting: error)])
                throw error
            }
            return
        }

        // Fallback (tests / no edit service wired): direct write via the
        // track's own bookmark. Note `track.fileURL` is a URL *string*, not a
        // path — `URL(fileURLWithPath:)` here silently produced a garbage
        // path for years, which is why embeds never worked on this branch.
        guard let track = try? await trackRepo.fetch(id: trackID) else { return }
        guard let url = Self.fileURL(from: track.fileURL) else {
            self.log.error("lyrics.fileWrite.failed", ["track": trackID, "error": "invalid fileURL"])
            throw LibraryError.invalidFileURL(track.fileURL)
        }

        do {
            if let bookmarkData = track.fileBookmark {
                try await SecurityScope.withAccess(bookmarkData) { scopedURL in
                    try await Task.detached(priority: .userInitiated) {
                        var tags = try TagReader().read(from: scopedURL)
                        tags.lyrics = lyricsText
                        try TagWriter().write(tags, to: scopedURL)
                    }.value
                }
            } else {
                try await Task.detached(priority: .userInitiated) {
                    var tags = try TagReader().read(from: url)
                    tags.lyrics = lyricsText
                    try TagWriter().write(tags, to: url)
                }.value
            }
            self.log.debug("lyrics.fileWrite.done", ["track": trackID])
        } catch {
            self.log.error("lyrics.fileWrite.failed", ["track": trackID, "error": String(reflecting: error)])
            throw error
        }
    }

    /// `tracks.file_url` holds a URL *string* ("file:///…"); passing it to
    /// `URL(fileURLWithPath:)` mangles it into a relative garbage path — the bug
    /// that silently broke sidecar loading and no-bookmark embeds since Phase 11.
    /// Plain absolute paths (legacy rows, tests) are still accepted.
    private static func fileURL(from string: String) -> URL? {
        if let url = URL(string: string), url.isFileURL { return url }
        if string.hasPrefix("/") { return URL(fileURLWithPath: string) }
        return nil
    }

    private func loadSidecar(for trackID: Int64) async throws -> LyricsDocument? {
        guard let track = try? await trackRepo.fetch(id: trackID) else { return nil }
        guard let fileURL = Self.fileURL(from: track.fileURL) else { return nil }
        let lrcURL = fileURL.deletingPathExtension().appendingPathExtension("lrc")

        // The sibling .lrc is outside the track's own security scope; the
        // (read-only) library-root bookmark covers the directory. No matching
        // root (e.g. "Add Files…" tracks) still tries the raw read, which
        // works outside the sandbox and in tests.
        let scope = await self.acquireRootScope(for: lrcURL.path)
        defer { _ = scope } // keep the scope alive until the read completes

        guard FileManager.default.fileExists(atPath: lrcURL.path) else { return nil }

        do {
            let text = try String(contentsOf: lrcURL, encoding: .utf8)
            self.log.debug("lyrics.sidecar.loaded", ["track": trackID])
            return LRCParser.parseDocument(text)
        } catch {
            self.log.error("lyrics.sidecar.failed", ["track": trackID, "error": String(reflecting: error)])
            return nil
        }
    }

    /// Resolves and starts the security scope of the library root containing
    /// `path`, returning an RAII handle (nil when no root matches or the
    /// bookmark cannot be resolved — callers then attempt the raw read).
    private func acquireRootScope(for path: String) async -> RootScopeHandle? {
        let roots = await (try? self.rootRepo.fetchAll()) ?? []
        guard let root = roots.first(where: {
            let prefix = $0.path == "/" ? "/" : $0.path + "/"
            return path.hasPrefix(prefix)
        }) else { return nil }
        var isStale = false
        guard let rootURL = try? URL(
            resolvingBookmarkData: root.bookmark,
            options: .withSecurityScope,
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        ) else { return nil }
        return RootScopeHandle(url: rootURL)
    }
}
