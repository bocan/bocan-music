import Foundation
import Observability
import Persistence

// MARK: - DuplicateGroup

/// A set of tracks that appear to be duplicates of each other.
///
/// Tracks are grouped by normalized title, artist name, and duration bucket.
public struct DuplicateGroup: Identifiable, Sendable {
    /// Stable identity for use in SwiftUI lists.
    public let id = UUID()

    /// The tracks in this group (always ≥ 2).
    public let tracks: [Track]

    /// Display title for the group header.
    public let representativeTitle: String

    /// Display artist name for the group header.
    public let representativeArtist: String

    /// Creates a group from the given tracks and display strings.
    public init(tracks: [Track], representativeTitle: String, representativeArtist: String) {
        self.tracks = tracks
        self.representativeTitle = representativeTitle
        self.representativeArtist = representativeArtist
    }
}

// MARK: - DuplicateReviewViewModel

/// Loads all library tracks and groups them into ``DuplicateGroup`` values.
///
/// Two tracks are considered duplicates when they share the same:
/// - Normalized title (lowercased, whitespace-trimmed)
/// - Artist name (resolved via `ArtistRepository`)
/// - Duration bucket (`Int(duration)` — second-level granularity)
@MainActor
public final class DuplicateReviewViewModel: ObservableObject, Identifiable {
    // MARK: - Published state

    /// Duplicate groups found in the library, ordered by title.
    @Published public private(set) var groups: [DuplicateGroup] = []

    /// `true` while the initial load is running.
    @Published public private(set) var isLoading = false

    /// Human-readable description of any load error, or `nil`.
    @Published public var loadError: String?

    // MARK: - Identifiable

    /// Stable identity for use as a sheet item.
    public let id = UUID()

    // MARK: - Dependencies

    private let database: Database
    private let library: LibraryViewModel
    private let log = AppLogger.make(.ui)

    // MARK: - Init

    /// Creates a view-model that uses the provided database and library.
    public init(database: Database, library: LibraryViewModel) {
        self.database = database
        self.library = library
    }

    // MARK: - Public API

    /// Loads all tracks and computes duplicate groups.
    public func load() async {
        let start = Date()
        self.log.debug("duplicate_review.load.start")
        self.isLoading = true
        self.loadError = nil
        do {
            let trackRepo = TrackRepository(database: self.database)
            let artistRepo = ArtistRepository(database: self.database)
            let allTracks = try await trackRepo.fetchAll()
            let artists = try await artistRepo.fetchAll()
            let artistMap = Dictionary(uniqueKeysWithValues: artists.compactMap { artist -> (Int64, String)? in
                guard let id = artist.id else { return nil }
                return (id, artist.name)
            })
            self.groups = Self.findDuplicates(tracks: allTracks, artistNames: artistMap)
        } catch {
            self.loadError = error.localizedDescription
            self.log.error("duplicate_review.load.failed", ["error": String(reflecting: error)])
        }
        let ms = Int(Date().timeIntervalSince(start) * 1000)
        self.log.debug("duplicate_review.load.end", ["groups": self.groups.count, "ms": ms])
        self.isLoading = false
    }

    /// Soft-deletes (disables) the track with the given ID and reloads.
    public func removeTrack(id: Int64) async {
        await self.library.removeTrack(id: id)
        await self.load()
    }

    // MARK: - Private

    private static func findDuplicates(
        tracks: [Track],
        artistNames: [Int64: String]
    ) -> [DuplicateGroup] {
        typealias Key = String
        var buckets: [Key: [Track]] = [:]
        for track in tracks {
            let titleKey = (track.title ?? "").trimmingCharacters(in: .whitespaces).lowercased()
            let artistName = track.artistID.flatMap { artistNames[$0] } ?? ""
            let artistKey = artistName.lowercased()
            let durationKey = Int(track.duration)
            let key = "\(titleKey)\u{0}\(artistKey)\u{0}\(durationKey)"
            buckets[key, default: []].append(track)
        }
        return buckets
            .filter { $0.value.count >= 2 }
            .map { _, groupTracks in
                let rep = groupTracks[0]
                let title = rep.title ?? "Unknown"
                let artist = rep.artistID.flatMap { artistNames[$0] } ?? ""
                return DuplicateGroup(
                    tracks: groupTracks,
                    representativeTitle: title,
                    representativeArtist: artist
                )
            }
            .sorted { $0.representativeTitle.localizedCompare($1.representativeTitle) == .orderedAscending }
    }
}
