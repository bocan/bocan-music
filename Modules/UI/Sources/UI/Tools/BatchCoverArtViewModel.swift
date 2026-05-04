import CryptoKit
import Foundation
import Library
import Observability
import Persistence

// MARK: - BatchCoverArtViewModel

/// Drives the "Fetch Missing Cover Art" batch operation.
///
/// Queries the library for albums with no `cover_art_hash`, then searches
/// MusicBrainz / Cover Art Archive for a front image for each album —
/// one album at a time to respect the 1 req/sec rate limit.
@MainActor
public final class BatchCoverArtViewModel: ObservableObject, Identifiable {
    // MARK: - Published state

    /// Total number of albums without cover art found at start.
    @Published public private(set) var total = 0

    /// Albums processed so far.
    @Published public private(set) var processed = 0

    /// Albums for which an image was successfully saved.
    @Published public private(set) var found = 0

    /// Title of the album currently being searched.
    @Published public private(set) var currentAlbumTitle = ""

    /// `true` while the background task is running.
    @Published public private(set) var isRunning = false

    /// `true` once the task has finished or been cancelled.
    @Published public private(set) var isDone = false

    /// Human-readable description of the last top-level error, if any.
    @Published public var lastError: String?

    // MARK: - Identifiable

    /// Stable identity for use as a sheet item.
    public let id = UUID()

    // MARK: - Dependencies

    private let database: Database
    private let albumRepo: AlbumRepository
    private let artistRepo: ArtistRepository
    private let coverArtRepo: CoverArtRepository
    private let fetcher: CoverArtSearchService
    private let rateLimiter = RateLimiter(maxRequests: 1, per: 1.0)
    private let log = AppLogger.make(.ui)
    private var runTask: Task<Void, Never>?

    // MARK: - Init

    /// Creates a new view-model backed by the provided repositories.
    public init(
        database: Database,
        albumRepo: AlbumRepository,
        artistRepo: ArtistRepository
    ) {
        self.database = database
        self.albumRepo = albumRepo
        self.artistRepo = artistRepo
        self.coverArtRepo = CoverArtRepository(database: database)
        self.fetcher = CoverArtSearchService()
    }

    // MARK: - Public API

    /// Starts the background fetch operation.
    public func start() {
        guard !self.isRunning else { return }
        self.isRunning = true
        self.isDone = false
        self.processed = 0
        self.found = 0
        self.lastError = nil
        self.runTask = Task { await self.run() }
    }

    /// Cancels the running operation.
    public func cancel() {
        self.runTask?.cancel()
        self.runTask = nil
        self.isRunning = false
        self.isDone = true
    }

    // MARK: - Private

    private func run() async {
        let startTime = Date()
        self.log.debug("batch_cover_art.start")
        do {
            let albums = try await self.albumRepo.fetchAll()
            let missing = albums.filter { $0.coverArtHash == nil }
            self.total = missing.count
            self.log.debug("batch_cover_art.found_missing", ["count": missing.count])
            for album in missing {
                try Task.checkCancellation()
                self.currentAlbumTitle = album.title
                await self.rateLimiter.wait()
                try Task.checkCancellation()
                await self.processAlbum(album)
                self.processed += 1
            }
        } catch is CancellationError {
            self.log.debug("batch_cover_art.cancelled")
        } catch {
            self.lastError = error.localizedDescription
            self.log.error("batch_cover_art.failed", ["error": String(reflecting: error)])
        }
        let ms = Int(Date().timeIntervalSince(startTime) * 1000)
        self.log.debug("batch_cover_art.end", ["found": self.found, "ms": ms])
        self.isRunning = false
        self.isDone = true
    }

    private func processAlbum(_ album: Album) async {
        guard let albumID = album.id else { return }
        let artistName: String = if let artistID = album.albumArtistID,
                                    let artist = try? await self.artistRepo.fetch(id: artistID) {
            artist.name
        } else {
            ""
        }
        do {
            let candidates = try await self.fetcher.search(artist: artistName, album: album.title)
            guard let first = candidates.first else { return }
            let imageData = try await self.fetcher.image(for: first, size: .full)
            let hash = Self.sha256Hex(imageData)
            let path = try Self.saveToArtCache(data: imageData, hash: hash)
            let record = CoverArt(
                hash: hash,
                path: path,
                byteSize: imageData.count,
                source: "musicbrainz"
            )
            _ = try await self.coverArtRepo.save(record)
            try await self.albumRepo.setCoverArt(albumID: albumID, hash: hash, path: path)
            self.found += 1
            self.log.debug("batch_cover_art.album_done", ["album": album.title, "hash": hash])
        } catch is CancellationError {
            // Swallow — outer loop will see cancellation
        } catch {
            self.log.warning(
                "batch_cover_art.album_skip",
                ["album": album.title, "error": error.localizedDescription]
            )
        }
    }

    private static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func saveToArtCache(data: Data, hash: String) throws -> String {
        let prefix = String(hash.prefix(2))
        let dir = LibraryLocation.coverArtCacheDirectory
            .appendingPathComponent(prefix, isDirectory: true)
        let fileURL = dir.appendingPathComponent("\(hash).jpg")
        if !FileManager.default.fileExists(atPath: fileURL.path) {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try data.write(to: fileURL, options: .atomic)
        }
        return fileURL.path
    }
}
