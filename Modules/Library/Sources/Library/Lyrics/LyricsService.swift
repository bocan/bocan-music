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

    /// Resolves the best available lyrics for `trackID` using the priority
    /// stored in `UserDefaults` under `"lyrics.sourcePriority"`.
    ///
    /// **preferSynced** (default): user → sidecar .lrc → embedded synced → lrclib → embedded unsynced
    /// **preferEmbedded / preferUser**: user → embedded synced → sidecar .lrc → embedded unsynced → lrclib
    public func lyrics(for trackID: Int64) async throws -> LyricsDocument? {
        let row = try await lyricsRepo.fetch(trackID: trackID)

        // User edits always win regardless of priority.
        if let row, row.source == "user" {
            return self.parse(row: row)
        }

        let priority = LyricsSourcePriority(
            rawValue: UserDefaults.standard.string(forKey: "lyrics.sourcePriority") ?? ""
        ) ?? .preferSynced

        switch priority {
        case .preferSynced:
            if let sidecar = try await self.loadSidecar(for: trackID) { return sidecar }
            if let row, row.source == "embedded", row.isSynced { return self.parse(row: row) }
            if let row, row.source == "lrclib" { return self.parse(row: row) }
            if let row, row.source == "embedded", !row.isSynced { return self.parse(row: row) }

        case .preferEmbedded, .preferUser:
            if let row, row.source == "embedded", row.isSynced { return self.parse(row: row) }
            if let sidecar = try await self.loadSidecar(for: trackID) { return sidecar }
            if let row, row.source == "embedded", !row.isSynced { return self.parse(row: row) }
            if let row, row.source == "lrclib" { return self.parse(row: row) }
        }

        return nil
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
        guard let track = try? await trackRepo.fetch(id: trackID) else { return }
        let url = URL(fileURLWithPath: track.fileURL)
        let lyricsText: String = switch doc {
        case let .unsynced(text):
            text
        case .synced:
            doc.toLRC()
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
