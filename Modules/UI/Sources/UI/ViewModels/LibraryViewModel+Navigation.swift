import Persistence

// MARK: - LibraryViewModel + Navigation

extension LibraryViewModel {
    func loadDestination(_ destination: SidebarDestination) async {
        let query = self.searchQuery.trimmingCharacters(in: .whitespaces)
        switch destination {
        case .songs:
            if query.isEmpty {
                await self.tracks.load()
            } else {
                await self.tracks.search(query: query)
            }

        case .albums:
            if query.isEmpty {
                await self.albums.load()
            } else {
                await self.albums.search(query: query)
            }

        case .artists:
            if query.isEmpty {
                await self.artists.load()
            } else {
                await self.artists.search(query: query)
            }

        case .genres, .composers:
            await self.tracks.load()

        case .recentlyAdded:
            let trackRepo = TrackRepository(database: database)
            let result = await (try? trackRepo.recentlyAdded()) ?? []
            self.tracks.setTracks(result)

        case .recentlyPlayed:
            let trackRepo = TrackRepository(database: database)
            let result = await (try? trackRepo.recentlyPlayed()) ?? []
            self.tracks.setTracks(result)

        case .mostPlayed:
            let trackRepo = TrackRepository(database: database)
            let result = await (try? trackRepo.mostPlayed()) ?? []
            self.tracks.setTracks(result)

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

        case .playlist, .smartPlaylist:
            // TODO(phase-6): wire playlist loading
            break

        case .upNext:
            break // QueueView reads directly from QueuePlayer.queue

        case let .search(searchQuery):
            // Set the query; the Combine subscription will trigger a reload.
            // Directly load filtered songs here so the result is immediate.
            self.searchQuery = searchQuery
            let trimmed = searchQuery.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty {
                await self.tracks.load()
            } else {
                await self.tracks.search(query: trimmed)
            }
        }
    }
}
