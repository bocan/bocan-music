import Foundation
import Persistence

// MARK: - LibraryViewModel + Navigation

extension LibraryViewModel {
    func loadDestination(_ destination: SidebarDestination) async {
        let query = self.searchQuery.trimmingCharacters(in: .whitespaces)
        switch destination {
        case .songs:
            await self.loadSongsDestination(query: query)

        case .albums:
            await self.loadAlbumsDestination(query: query)

        case .artists:
            await self.loadArtistsDestination(query: query)

        case .genres, .composers:
            await self.tracks.load()

        case .recentlyAdded:
            await self.loadSmartFolder { try await $0.recentlyAdded() }

        case .recentlyPlayed:
            await self.loadSmartFolder { try await $0.recentlyPlayed() }

        case .mostPlayed:
            await self.loadSmartFolder { try await $0.mostPlayed() }

        case let .artist(id):
            await self.artists.load()
            await self.tracks.load(artistID: id)
            await self.albums.load(albumArtistID: id)

        case let .album(id):
            await self.tracks.load(albumID: id)

        case let .genre(genre):
            await self.tracks.load(genre: genre)

        case let .composer(c):
            await self.tracks.load(composer: c)

        case .playlist, .folder, .smartPlaylist, .upNext, .radio:
            break // each destination manages its own loading

        case let .search(searchQuery):
            self.searchQuery = searchQuery
            let trimmed = searchQuery.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty {
                await self.tracks.load()
            } else {
                await self.tracks.search(query: trimmed)
            }

        case .subsonicRoot, .subsonicSongs, .subsonicAlbums, .subsonicArtists, .subsonicGenres,
             .subsonicPlaylists, .subsonicPlaylist, .subsonicStarred,
             .subsonicRandom, .subsonicRecentlyAdded, .subsonicMostPlayed,
             .subsonicInternetRadio, .subsonicPodcasts, .subsonicBookmarks,
             .subsonicArtist, .subsonicAlbum:
            // Per-server Subsonic destinations manage their own loading via
            // dedicated view models. Nothing to fan out here.
            break

        case .podcasts:
            await self.podcasts.loadSubscribed()

        case let .podcastShow(id):
            await self.podcasts.loadShow(id)
        }
    }

    /// The structural parent of a drill-down destination (#378): where Esc
    /// backs out to. Nil for section roots and for destinations whose parent
    /// cannot be derived from the destination alone (playlist folders nest,
    /// so their parent lives in the sidebar tree, not the destination).
    nonisolated static func parentDestination(of destination: SidebarDestination) -> SidebarDestination? {
        switch destination {
        case .artist:
            .artists

        case .album:
            .albums

        case .genre:
            .genres

        case .composer:
            .composers

        case .podcastShow:
            .podcasts

        case let .subsonicArtist(server, _):
            .subsonicArtists(server)

        case let .subsonicAlbum(server, _):
            .subsonicAlbums(server)

        case let .subsonicPlaylist(server, _):
            .subsonicPlaylists(server)

        default:
            nil
        }
    }

    /// Whether `candidate` is a view the user plausibly opened `destination`
    /// from: the containers a drill-down legitimately belongs to. An album's
    /// containers include any artist, genre, or composer page as well as the
    /// Albums root; the Subsonic drill-downs require the same server. Esc
    /// follows history only when it passes this check, so an implausible
    /// previous entry (Podcasts behind an album, say) can never make Esc
    /// teleport across sidebar sections.
    nonisolated static func isPlausibleContainer(
        _ candidate: SidebarDestination,
        of destination: SidebarDestination
    ) -> Bool {
        switch destination {
        case .album:
            self.isAlbumContainer(candidate)

        case .artist:
            candidate == .artists

        case .genre:
            candidate == .genres

        case .composer:
            candidate == .composers

        case .podcastShow:
            candidate == .podcasts

        case let .subsonicAlbum(server, _):
            self.isSubsonicAlbumContainer(candidate, server: server)

        case let .subsonicArtist(server, _):
            candidate == .subsonicArtists(server)

        case let .subsonicPlaylist(server, _):
            candidate == .subsonicPlaylists(server)

        default:
            false
        }
    }

    private nonisolated static func isAlbumContainer(_ candidate: SidebarDestination) -> Bool {
        switch candidate {
        case .albums, .artist, .genre, .composer:
            true

        default:
            false
        }
    }

    private nonisolated static func isSubsonicAlbumContainer(
        _ candidate: SidebarDestination,
        server: UUID
    ) -> Bool {
        switch candidate {
        case .subsonicAlbums(server), .subsonicArtist(server, _):
            true

        default:
            false
        }
    }

    /// Esc drill-out (#378): prefers the history entry the user came from
    /// when it is a plausible container of the current drill-down (an album
    /// opened from its artist returns to that artist, popping history so
    /// mouse-forward still returns to the album), and falls back to the
    /// structural parent otherwise. At a section root with an active search,
    /// Esc clears the filter instead — the field's own Esc handling only
    /// works while it has focus, and a filter you can't dismiss reads as
    /// broken. Returns false only when there is nothing left to peel, so the
    /// caller can pass the event through.
    @discardableResult
    public func drillOutToParent() -> Bool {
        let current = self.selectedDestination
        if let previous = self.lastHistoryEntry, Self.isPlausibleContainer(previous, of: current) {
            Task { await self.goBack() }
            return true
        }
        if let parent = Self.parentDestination(of: current) {
            Task { await self.selectDestination(parent) }
            return true
        }
        guard !self.searchQuery.isEmpty else { return false }
        self.searchQuery = ""
        return true
    }

    /// Jumps to a track's album, then selects and scrolls to the track: the
    /// Library Summary's reveal path, so an offender row lands the user on
    /// the exact song, not just its album. Selection survives the detail
    /// view's own reload because loads never touch `tracks.selection`.
    public func revealTrack(_ trackID: Int64, inAlbum albumID: Int64) async {
        await self.selectDestination(.album(albumID))
        self.tracks.selection = [trackID]
        self.tracks.requestScroll(to: trackID)
    }

    // MARK: - Destination helpers

    private func loadSongsDestination(query: String) async {
        if query.isEmpty {
            await self.tracks.load()
        } else {
            await self.tracks.search(query: query)
        }
    }

    private func loadAlbumsDestination(query: String) async {
        if query.isEmpty {
            await self.albums.load()
        } else {
            await self.albums.search(query: query)
        }
    }

    private func loadArtistsDestination(query: String) async {
        if query.isEmpty {
            await self.artists.load()
        } else {
            await self.artists.search(query: query)
        }
    }

    private func loadSmartFolder(_ fetch: (TrackRepository) async throws -> [Track]) async {
        let trackRepo = TrackRepository(database: database)
        let result = await (try? fetch(trackRepo)) ?? []
        self.tracks.setTracks(result)
    }
}
