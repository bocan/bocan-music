import Acoustics
import Foundation
import Observability
import Persistence

/// Assembles Deep Dive reports (#413) from the shared MusicBrainz client,
/// Wikipedia, and the local library, with disk caching and stale-if-offline.
///
/// Every MusicBrainz request goes through the app-wide 1 req/s limiter, so a
/// report costs a few seconds the first time and is instant afterwards.
public actor DeepDiveService {
    /// Minimum MusicBrainz search score to accept a name match as the artist.
    public static let guessScoreThreshold = 90

    private let artists: ArtistRepository
    private let albums: AlbumRepository
    private let tracks: TrackRepository
    private let musicBrainz: MusicBrainzClient
    private let wikipedia: WikipediaClient
    private let cache: DeepDiveCache
    private let now: @Sendable () -> Date
    private let log = AppLogger.make(.library)

    public init(
        database: Database,
        musicBrainz: MusicBrainzClient = MusicBrainzClient(),
        wikipedia: WikipediaClient = WikipediaClient(),
        cache: DeepDiveCache = DeepDiveCache(),
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.artists = ArtistRepository(database: database)
        self.albums = AlbumRepository(database: database)
        self.tracks = TrackRepository(database: database)
        self.musicBrainz = musicBrainz
        self.wikipedia = wikipedia
        self.cache = cache
        self.now = now
    }

    // MARK: - Artist

    /// The report for an artist row. Uses the stored MBID, or guesses one by
    /// name when the tags supplied none (flagged `mbidGuessed`).
    public func artistReport(artistID: Int64, forceRefresh: Bool = false) async throws -> ArtistReport {
        let artist = try await self.artists.fetch(id: artistID)
        let (mbid, guessed) = try await self.resolveArtistMBID(artist)
        let key = "artist-\(mbid)"
        let cached: (value: ArtistReport, fresh: Bool)? = await self.cache.load(ArtistReport.self, key: key)
        if let cached, cached.fresh, !forceRefresh, cached.value.artistID == artistID { return cached.value }

        do {
            let report = try await self.buildArtistReport(artist: artist, mbid: mbid, guessed: guessed)
            await self.cache.store(report, key: key)
            return report
        } catch let error as DeepDiveError where error == .offline || error == .rateLimited {
            if let cached { return cached.value }
            throw error
        }
    }

    private func resolveArtistMBID(_ artist: Artist) async throws -> (String, Bool) {
        if let mbid = artist.musicbrainzArtistID { return (mbid, false) }
        let results = try await self.mapErrors { try await self.musicBrainz.searchArtists(name: artist.name, limit: 5) }
        guard let best = results.first, (best.score ?? 0) >= Self.guessScoreThreshold else {
            throw DeepDiveError.noIdentifier
        }
        self.log.info("deepdive.artist.guessed", ["artist": artist.name, "mbid": best.id, "score": best.score ?? 0])
        return (best.id, true)
    }

    private func buildArtistReport(artist: Artist, mbid: String, guessed: Bool) async throws -> ArtistReport {
        let detail = try await self.mapErrors { try await self.musicBrainz.fetchArtist(mbid: mbid) }
        let groups = try await self.mapErrors { try await self.musicBrainz.browseReleaseGroups(artistMBID: mbid, limit: 100) }
        var bio: ArtistReport.Bio?
        if let wikidataID = detail.wikidataID {
            // A missing bio must never sink the report.
            if let summary = try? await self.wikipedia.summary(wikidataID: wikidataID) {
                bio = ArtistReport.Bio(
                    extract: summary.extract, pageURL: summary.pageURL, thumbnailURL: summary.thumbnailURL,
                    attribution: "Wikipedia, CC BY-SA 4.0"
                )
            }
        }
        // Stamp the enrichment columns opportunistically: this is the same lookup.
        if !guessed {
            try? await self.artists.setEnrichment(
                mbid: mbid, disambiguation: detail.disambiguation, sortName: detail.sortName,
                fetchedAt: Int64(self.now().timeIntervalSince1970)
            )
        }

        let owned = try await self.ownedReleaseKeys(artistID: artist.id ?? 0)
        let discography = groups.releaseGroups.map { group in
            ArtistReport.Release(
                title: group.title ?? "",
                mbid: group.id,
                primaryType: group.primaryType,
                secondaryTypes: group.secondaryTypes ?? [],
                year: group.year,
                owned: owned.groupIDs.contains(group.id) || owned.titles.contains((group.title ?? "").lowercased())
            )
        }.sorted { ($0.year ?? Int.max, $0.title) < ($1.year ?? Int.max, $1.title) }

        return ArtistReport(
            artistID: artist.id ?? 0,
            mbid: mbid,
            mbidGuessed: guessed,
            name: detail.name,
            sortName: detail.sortName,
            disambiguation: detail.disambiguation.flatMap { $0.isEmpty ? nil : $0 },
            type: detail.type,
            country: detail.country,
            activeFrom: detail.lifeSpan?.begin,
            activeUntil: detail.lifeSpan?.end,
            ended: detail.lifeSpan?.ended ?? false,
            bio: bio,
            members: detail.members.map {
                ArtistReport.Member(
                    name: $0.artist.name,
                    mbid: $0.artist.id,
                    begin: $0.begin,
                    end: $0.end,
                    ended: $0.ended,
                    roles: $0.attributes
                )
            },
            links: detail.links.map { ArtistReport.Link(type: $0.key, url: $0.value) }.sorted { $0.type < $1.type },
            discography: discography,
            fetchedAt: self.now()
        )
    }

    private func ownedReleaseKeys(artistID: Int64) async throws -> (groupIDs: Set<String>, titles: Set<String>) {
        let mine = try await self.albums.fetchAll().filter { $0.albumArtistID == artistID }
        return (Set(mine.compactMap(\.musicbrainzReleaseGroupID)), Set(mine.map { $0.title.lowercased() }))
    }

    // MARK: - Track

    /// The recording report for a track. Requires a recording MBID on the row.
    public func trackReport(trackID: Int64, forceRefresh: Bool = false) async throws -> TrackReport {
        let track = try await self.tracks.fetch(id: trackID)
        guard let mbid = track.musicbrainzRecordingID, !mbid.isEmpty else { throw DeepDiveError.noIdentifier }
        let key = "recording-\(mbid)"
        let cached: (value: TrackReport, fresh: Bool)? = await self.cache.load(TrackReport.self, key: key)
        if let cached, cached.fresh, !forceRefresh { return cached.value }
        do {
            let recording = try await self.mapErrors { try await self.musicBrainz.fetchRecording(mbid: mbid) }
            let appearances = (recording.releases ?? []).map { release in
                TrackReport.Appearance(
                    releaseTitle: release.title, releaseMBID: release.id, year: release.year,
                    country: release.country, status: release.status,
                    primaryType: release.releaseGroup?.primaryType, secondaryTypes: release.releaseGroup?.secondaryTypes ?? []
                )
            }.sorted { ($0.year ?? Int.max, $0.releaseTitle) < ($1.year ?? Int.max, $1.releaseTitle) }
            let report = TrackReport(
                trackID: trackID,
                recordingMBID: mbid,
                title: recording.title,
                artistCredit: recording.artistName,
                length: recording.length,
                isrcs: recording.isrcs ?? [],
                firstReleaseYear: appearances.compactMap(\.year).min(),
                tags: (recording.tags ?? []).sorted { $0.count > $1.count }.prefix(5).map(\.name),
                appearances: appearances,
                fetchedAt: self.now()
            )
            await self.cache.store(report, key: key)
            return report
        } catch let error as DeepDiveError where error == .offline || error == .rateLimited {
            if let cached { return cached.value }
            throw error
        }
    }

    // MARK: - Errors

    private func mapErrors<T>(_ body: () async throws -> T) async throws -> T {
        do {
            return try await body()
        } catch AcousticsError.networkError {
            throw DeepDiveError.offline
        } catch AcousticsError.rateLimitExceeded {
            throw DeepDiveError.rateLimited
        } catch AcousticsError.invalidResponse {
            throw DeepDiveError.notFound
        }
    }
}
