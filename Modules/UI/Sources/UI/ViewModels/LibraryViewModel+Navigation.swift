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

    /// Esc drill-out (#378): navigates to the structural parent of the
    /// current drill-down. Returns false at section roots so the caller can
    /// pass the event through. Deliberately not history-back: history can
    /// cross sidebar sections, and Esc teleporting across the sidebar would
    /// feel broken.
    @discardableResult
    public func drillOutToParent() -> Bool {
        guard let parent = Self.parentDestination(of: self.selectedDestination) else { return false }
        Task { await self.selectDestination(parent) }
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
