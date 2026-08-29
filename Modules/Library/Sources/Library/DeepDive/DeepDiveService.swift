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

    // MARK: - Album

    /// The release report for an album. Uses the album's release id, or picks
    /// the earliest official release of its release group.
    public func albumReport(albumID: Int64, forceRefresh: Bool = false) async throws -> AlbumReport {
        let album = try await self.albums.fetch(id: albumID)
        let key = "album-\(albumID)"
        let cached: (value: AlbumReport, fresh: Bool)? = await self.cache.load(AlbumReport.self, key: key)
        if let cached, cached.fresh, !forceRefresh { return cached.value }
        do {
            let report = try await self.buildAlbumReport(album)
            await self.cache.store(report, key: key)
            return report
        } catch let error as DeepDiveError where error == .offline || error == .rateLimited {
            if let cached { return cached.value }
            throw error
        }
    }

    private func buildAlbumReport(_ album: Album) async throws -> AlbumReport {
        var releaseChosen = false
        var releaseID = album.musicbrainzReleaseID
        if releaseID == nil, let groupID = album.musicbrainzReleaseGroupID {
            let group = try await self.mapErrors { try await self.musicBrainz.fetchReleaseGroup(mbid: groupID) }
            releaseID = Self.representativeRelease(group.releases ?? [])?.id
            releaseChosen = releaseID != nil
        }
        guard let releaseID else { throw DeepDiveError.noIdentifier }
        let release = try await self.mapErrors { try await self.musicBrainz.fetchRelease(mbid: releaseID) }

        var artist: Artist?
        if let artistID = album.albumArtistID {
            artist = try? await self.artists.fetch(id: artistID)
        }
        let nearby = await self.nearbyReleases(of: release, album: album, artist: artist)

        let ownedTracks = try await self.tracks.count(albumID: album.id ?? 0)
        let media = release.media ?? []
        return AlbumReport(
            albumID: album.id ?? 0,
            title: release.title,
            artistName: release.albumArtistName ?? artist?.name ?? "",
            releaseMBID: release.id,
            releaseGroupMBID: release.releaseGroup?.id ?? album.musicbrainzReleaseGroupID,
            releaseChosen: releaseChosen,
            primaryType: release.releaseGroup?.primaryType,
            secondaryTypes: release.releaseGroup?.secondaryTypes ?? [],
            date: release.date,
            country: release.country,
            status: release.status,
            barcode: release.barcode,
            labels: (release.labelInfo ?? []).compactMap { info in
                info.label.map { AlbumReport.Label(name: $0.name, catalogNumber: info.catalogNumber) }
            },
            formats: media.compactMap(\.format),
            trackCount: media.isEmpty ? nil : media.compactMap(\.trackCount).reduce(0, +),
            ownedTrackCount: ownedTracks,
            coverArtArchiveURL: URL(string: "https://coverartarchive.org/release/\(release.id)")!,
            musicBrainzURL: URL(string: "https://musicbrainz.org/release/\(release.id)")!,
            nearby: nearby,
            fetchedAt: self.now()
        )
    }

    /// The artist's other release groups within two years of `release`.
    private func nearbyReleases(of release: MBRelease, album: Album, artist: Artist?) async -> [AlbumReport.Nearby] {
        guard let artist, let artistMBID = artist.musicbrainzArtistID, let year = release.year ?? album.year else { return [] }
        guard let owned = try? await self.ownedReleaseKeys(artistID: artist.id ?? 0),
              let groups = try? await self
              .mapErrors({ try await self.musicBrainz.browseReleaseGroups(artistMBID: artistMBID, limit: 100) }) else { return [] }
        var nearby: [AlbumReport.Nearby] = []
        for group in groups.releaseGroups {
            guard group.id != release.releaseGroup?.id, let groupYear = group.year, abs(groupYear - year) <= 2 else { continue }
            let title = group.title ?? ""
            let isOwned = owned.groupIDs.contains(group.id) || owned.titles.contains(title.lowercased())
            nearby.append(AlbumReport.Nearby(title: title, mbid: group.id, primaryType: group.primaryType, year: groupYear, owned: isOwned))
        }
        return nearby.sorted { ($0.year ?? 0, $0.title) < ($1.year ?? 0, $1.title) }
    }

    /// Earliest official release, else earliest of any status.
    static func representativeRelease(_ releases: [MBRelease]) -> MBRelease? {
        let sorted = releases.sorted { ($0.date ?? "9999") < ($1.date ?? "9999") }
        return sorted.first { $0.status == "Official" } ?? sorted.first
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
            // At most two work lookups: enough for a song and its medley partner.
            var works: [TrackReport.Work] = []
            for ref in recording.works.prefix(2) {
                if let work = try? await self.mapErrors({ try await self.musicBrainz.fetchWork(mbid: ref.id) }) {
                    works.append(TrackReport.Work(
                        title: work.title ?? ref.title ?? "", mbid: work.id,
                        composers: work.composers, lyricists: work.lyricists, writers: work.writers
                    ))
                }
            }
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
                works: works,
                acoustIDURL: track.acoustidID.flatMap { URL(string: "https://acoustid.org/track/\($0)") },
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
