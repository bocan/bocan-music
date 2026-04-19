import Persistence

// MARK: - LibraryViewModel + Navigation

extension LibraryViewModel {
    func loadDestination(_ destination: SidebarDestination) async {
        switch destination {
        case .songs:
            await self.tracks.load()

        case .albums:
            await self.albums.load()

        case .artists:
            await self.artists.load()

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
            self.search.query = searchQuery
            self.search.queryChanged()
        }
    }
}
