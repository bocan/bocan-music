import Foundation
import Metadata
import Observability

// MARK: - BackupRing

/// On-disk ring buffer storing the original `TrackTags` for the last N edits.
///
/// Each entry is keyed by `{fileURL}:{editID}` and stored as a JSON file in the
/// ring directory.  When the buffer is full the oldest entry is evicted.
///
/// - Thread safety: all operations are actor-isolated.
public actor BackupRing {
    // MARK: - Types

    /// A single backup entry.
    public struct Entry: Sendable, Codable {
        /// Stable identifier for this edit (UUID string).
        public let editID: String
        /// The file URL string of the track that was edited.
        public let fileURL: String
        /// The tags as they existed before the edit was applied.
        public let originalTags: TagsSnapshot
        /// When the backup was created (Unix epoch seconds).
        public let createdAt: Int64
    }

    // MARK: - Properties

    private let ringDir: URL
    private let capacity: Int
    private var order: [String] = [] // editIDs, oldest first
    private let log = AppLogger.make(.library)

    // MARK: - Init

    public init(directory: URL, capacity: Int = 50) throws {
        self.ringDir = directory
        self.capacity = capacity
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        // Rebuild order from existing entries on disk.
        self.order = Self.loadOrder(from: directory)
    }

    // MARK: - Public API

    /// Saves a backup entry and returns the `editID` for later retrieval.
    @discardableResult
    public func save(fileURL: String, tags: TagsSnapshot) throws -> String {
        let editID = UUID().uuidString
        let entry = Entry(
            editID: editID,
            fileURL: fileURL,
            originalTags: tags,
            createdAt: Int64(Date().timeIntervalSince1970)
        )
        let data = try JSONEncoder().encode(entry)
        let entryURL = self.ringDir.appendingPathComponent("\(editID).json")
        try data.write(to: entryURL, options: .atomic)

        self.order.append(editID)
        self.log.debug("backup_ring.save", ["editID": editID, "file": fileURL])

        if self.order.count > self.capacity {
            self.evictOldest()
        }
        return editID
    }

    /// Loads the backup entry for `editID`, or `nil` if it has been evicted.
    public func load(editID: String) throws -> Entry? {
        let entryURL = self.ringDir.appendingPathComponent("\(editID).json")
        guard FileManager.default.fileExists(atPath: entryURL.path) else { return nil }
        let data = try Data(contentsOf: entryURL)
        return try JSONDecoder().decode(Entry.self, from: data)
    }

    /// Returns the most recent entry for `fileURL`, or `nil` if none.
    public func lastEntry(forFileURL fileURL: String) throws -> Entry? {
        for editID in self.order.reversed() {
            if let entry = try self.load(editID: editID), entry.fileURL == fileURL {
                return entry
            }
        }
        return nil
    }

    /// Removes the entry for `editID` from disk.
    public func delete(editID: String) {
        let entryURL = self.ringDir.appendingPathComponent("\(editID).json")
        try? FileManager.default.removeItem(at: entryURL)
        self.order.removeAll { $0 == editID }
    }

    // MARK: - Private helpers

    private func evictOldest() {
        guard let oldest = self.order.first else { return }
        self.delete(editID: oldest)
        self.log.debug("backup_ring.evict", ["editID": oldest])
    }

    private static func loadOrder(from dir: URL) -> [String] {
        guard let items = try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.creationDateKey], options: []
        ) else { return [] }
        return items
            .filter { $0.pathExtension == "json" }
            .sorted { lhs, rhs in
                let ld = (try? lhs.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
                let rd = (try? rhs.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
                return ld < rd
            }
            .map { $0.deletingPathExtension().lastPathComponent }
    }
}

// MARK: - TagsSnapshot

/// A Codable snapshot of `TrackTags` suitable for JSON persistence.
///
/// We deliberately flatten to plain optionals rather than embedding `TrackTags`
/// directly, to keep the serialisation stable even if `TrackTags` gains fields.
public struct TagsSnapshot: Sendable, Codable, Equatable {
    public var title: String?
    public var artist: String?
    public var albumArtist: String?
    public var album: String?
    public var genre: String?
    public var composer: String?
    public var comment: String?
    public var year: Int?
    public var trackNumber: Int?
    public var trackTotal: Int?
    public var discNumber: Int?
    public var discTotal: Int?
    public var sortArtist: String?
    public var sortAlbumArtist: String?
    public var sortAlbum: String?
    public var lyrics: String?
    public var bpm: Double?
    public var key: String?
    public var isrc: String?
    public var replaygainTrackGain: Double?
    public var replaygainTrackPeak: Double?
    public var replaygainAlbumGain: Double?
    public var replaygainAlbumPeak: Double?
    // Cover art is omitted (too large; callers re-read from file on undo)

    public init(from tags: TrackTags) {
        self.title = tags.title
        self.artist = tags.artist
        self.albumArtist = tags.albumArtist
        self.album = tags.album
        self.genre = tags.genre
        self.composer = tags.composer
        self.comment = tags.comment
        self.year = tags.year
        self.trackNumber = tags.trackNumber
        self.trackTotal = tags.trackTotal
        self.discNumber = tags.discNumber
        self.discTotal = tags.discTotal
        self.sortArtist = tags.sortArtist
        self.sortAlbumArtist = tags.sortAlbumArtist
        self.sortAlbum = tags.sortAlbum
        self.lyrics = tags.lyrics
        self.bpm = tags.bpm
        self.key = tags.key
        self.isrc = tags.isrc
        self.replaygainTrackGain = tags.replayGain.trackGain
        self.replaygainTrackPeak = tags.replayGain.trackPeak
        self.replaygainAlbumGain = tags.replayGain.albumGain
        self.replaygainAlbumPeak = tags.replayGain.albumPeak
    }

    /// Converts back to a `TrackTags` for writing.
    public func toTrackTags() -> TrackTags {
        var tags = TrackTags()
        tags.title = self.title
        tags.artist = self.artist
        tags.albumArtist = self.albumArtist
        tags.album = self.album
        tags.genre = self.genre
        tags.composer = self.composer
        tags.comment = self.comment
        tags.year = self.year
        tags.trackNumber = self.trackNumber
        tags.trackTotal = self.trackTotal
        tags.discNumber = self.discNumber
        tags.discTotal = self.discTotal
        tags.sortArtist = self.sortArtist
        tags.sortAlbumArtist = self.sortAlbumArtist
        tags.sortAlbum = self.sortAlbum
        tags.lyrics = self.lyrics
        tags.bpm = self.bpm
        tags.key = self.key
        tags.isrc = self.isrc
        tags.replayGain = ReplayGain(
            trackGain: self.replaygainTrackGain,
            trackPeak: self.replaygainTrackPeak,
            albumGain: self.replaygainAlbumGain,
            albumPeak: self.replaygainAlbumPeak
        )
        return tags
    }
}
