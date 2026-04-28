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
    private let fetcher: (any LRClibClientProtocol)?
    private let log = AppLogger.make(.library)

    // MARK: - Init

    /// - Parameters:
    ///   - database: The shared application database.
    ///   - fetcher: Optional LRClib client; pass `nil` when opt-in fetch is disabled.
    public init(database: Database, fetcher: (any LRClibClientProtocol)?) {
        self.database = database
        self.lyricsRepo = LyricsRepository(database: database)
        self.trackRepo = TrackRepository(database: database)
        self.artistRepo = ArtistRepository(database: database)
        self.fetcher = fetcher
    }

    // MARK: - Public API

    /// Resolves the best available lyrics for `trackID` using the configured priority.
    ///
    /// Resolution order (default / `preferEmbedded`):
    /// 1. User-edited DB row (`source = "user"`).
    /// 2. Embedded synced (DB row with `source = "embedded"` + `is_synced = true`).
    /// 3. Sidecar `.lrc` file adjacent to the audio file.
    /// 4. Embedded unsynced (DB row with `source = "embedded"`).
    /// 5. Fetched from LRClib (`source = "lrclib"`).
    public func lyrics(for trackID: Int64) async throws -> LyricsDocument? {
        let row = try await lyricsRepo.fetch(trackID: trackID)

        // 1. User-edited row has the highest priority.
        if let row, row.source == "user" {
            return self.parse(row: row)
        }

        // 2. Embedded synced.
        if let row, row.source == "embedded", row.isSynced {
            return self.parse(row: row)
        }

        // 3. Sidecar .lrc.
        if let sidecar = try await self.loadSidecar(for: trackID) {
            return sidecar
        }

        // 4. Embedded unsynced.
        if let row, row.source == "embedded", !row.isSynced {
            return self.parse(row: row)
        }

        // 5. Fetched.
        if let row, row.source == "lrclib" {
            return self.parse(row: row)
        }

        return nil
    }

    /// Saves `doc` as the lyrics for `trackID`.
    ///
    /// - Parameters:
    ///   - doc: Pass `nil` to delete existing lyrics.
    ///   - source: The source string to record (e.g. `"user"`, `"lrclib"`). Defaults to `"user"`.
    ///   - persistToFile: Reserved for Phase 8's write path; currently a no-op.
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
            self.log.notice("lyrics.fileWrite.skipped", ["reason": "Phase 8 write path not yet wired"])
        }
    }

    /// If no lyrics exist for `trackID`, the user has enabled LRClib fetch, and a
    /// `fetcher` is configured, attempts to retrieve lyrics and saves the result.
    ///
    /// Returns the fetched document, or `nil` when nothing is available, consent
    /// is absent, or the fetcher is `nil`.
    public func autoFetchIfMissing(for trackID: Int64) async throws -> LyricsDocument? {
        guard let fetcher,
              UserDefaults.standard.bool(forKey: "lyrics.lrclibEnabled") else { return nil }

        let existing = try await lyrics(for: trackID)
        guard existing == nil else { return existing }

        guard let track = try? await trackRepo.fetch(id: trackID) else { return nil }

        self.log.debug("lrclib.fetch.start", ["track": trackID])

        let artistName: String = if let aid = track.artistID, let artist = try? await artistRepo.fetch(id: aid) {
            artist.name
        } else {
            ""
        }
        let doc = try await fetcher.get(
            artist: artistName,
            title: track.title ?? "",
            album: nil, // album resolved via a separate join; not available on the base Track record
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
    /// underlying DB row changes.
    ///
    /// Note: sidecar files are not watched; the stream reflects DB state only.
    public func observe(_ trackID: Int64) -> AsyncThrowingStream<LyricsDocument?, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let inner = await self.lyricsRepo.observe(trackID: trackID)
                    for try await row in inner {
                        try Task.checkCancellation()
                        let doc: LyricsDocument? = row.flatMap { self.parse(row: $0) }
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

    private func loadSidecar(for trackID: Int64) async throws -> LyricsDocument? {
        guard let track = try? await trackRepo.fetch(id: trackID) else { return nil }
        let fileURL = URL(fileURLWithPath: track.fileURL)
        let lrcURL = fileURL.deletingPathExtension().appendingPathExtension("lrc")

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
}
