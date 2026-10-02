import Foundation
import Metadata
import Persistence
@testable import Library

/// Fixture builders shared by the `TrackImporter` suites. A suite conforms to
/// get them as `self.makeDB()`, `self.makeTags()` and so on.
protocol TrackImporterFixtures {}

extension TrackImporterFixtures {
    func makeDB() async throws -> Database {
        try await Database(location: .inMemory)
    }

    func makeTags(title: String = "Test Track") -> TrackTags {
        var tags = TrackTags()
        tags.title = title
        tags.artist = "Test Artist"
        tags.album = "Test Album"
        tags.duration = 180.0
        return tags
    }

    /// Builds tags for a compilation track: same album, a distinct artist,
    /// no album-artist, compilation flag set.
    func compilationTags(artist: String, compilation: Bool = true) -> TrackTags {
        var tags = TrackTags()
        tags.title = "Track by \(artist)"
        tags.artist = artist
        tags.album = "Now That's What I Call Music"
        tags.isCompilation = compilation
        tags.duration = 180.0
        return tags
    }

    func makeImporter(_ db: Database) -> TrackImporter {
        TrackImporter(
            artistRepo: ArtistRepository(database: db),
            albumRepo: AlbumRepository(database: db),
            trackRepo: TrackRepository(database: db),
            lyricsRepo: LyricsRepository(database: db),
            coverArtCache: CoverArtCache.make(database: db)
        )
    }
}
