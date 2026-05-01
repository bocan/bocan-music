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

        case .playlist:
            break // PlaylistDetailView handles its own loading

        case .folder:
            break // PlaylistFolderView reads directly from PlaylistSidebarViewModel.nodes

        case .smartPlaylist:
            break // SmartPlaylistDetailView handles its own loading

        case .upNext:
            break // QueueView reads directly from QueuePlayer.queue

        case let .search(searchQuery):
            self.searchQuery = searchQuery
            let trimmed = searchQuery.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty {
                await self.tracks.load()
            } else {
                await self.tracks.search(query: trimmed)
            }
        }
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
