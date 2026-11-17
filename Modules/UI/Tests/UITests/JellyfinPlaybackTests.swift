import AppKit
import AudioEngine
import Foundation
import Jellyfin
import Persistence
import Playback
import Testing
@testable import UI

// MARK: - JellyfinPlaybackTests

/// ADR-097 slice 5 on the UI side: a Jellyfin song becomes a `.jellyfin` queue
/// item, the drag payload round-trips, and the play methods reach the player.
@Suite("Jellyfin playback (UI)")
@MainActor
struct JellyfinPlaybackTests {
    private let serverID = UUID()

    private func song(_ id: String, title: String = "Song") -> JellyfinSong {
        JellyfinSong(
            id: id,
            title: title,
            artistName: "Artist",
            albumTitle: "Album",
            genre: "Jazz",
            durationSeconds: 212.7
        )
    }

    // MARK: Payload and queue item

    @Test("the payload takes its fields from the song, and a missing field is empty")
    func payloadFromSong() {
        let full = JellyfinSongDragPayload(song: self.song("a1", title: "Blue"), serverID: self.serverID)
        #expect(full.serverID == self.serverID)
        #expect(full.songID == "a1")
        #expect(full.title == "Blue")
        #expect(full.artist == "Artist")
        #expect(full.album == "Album")
        #expect(full.genre == "Jazz")
        #expect(full.durationSeconds == 212)

        let bare = JellyfinSongDragPayload(song: JellyfinSong(id: "b2", title: "Bare"), serverID: self.serverID)
        #expect(bare.artist.isEmpty)
        #expect(bare.album.isEmpty)
        #expect(bare.genre.isEmpty)
        #expect(bare.durationSeconds == 0)
    }

    @Test("makeJellyfin builds a .jellyfin queue item with no tracks row")
    func makesJellyfinQueueItem() {
        let payload = JellyfinSongDragPayload(song: self.song("item-42", title: "Faded"), serverID: self.serverID)
        let item = QueueItem.makeJellyfin(from: payload)
        #expect(item.trackID == -1)
        #expect(item.title == "Faded")
        #expect(item.artistName == "Artist")
        #expect(item.albumName == "Album")
        #expect(item.duration == 212)
        #expect(item.playableSource == .jellyfin(serverID: self.serverID, itemID: "item-42"))
        #expect(item.playableSource.subsonicSongID == nil)
    }

    @Test("the drag payload round-trips through the pasteboard, and other items are ignored")
    func pasteboardRoundTrip() throws {
        let first = JellyfinSongDragPayload(song: self.song("a"), serverID: self.serverID)
        let second = JellyfinSongDragPayload(song: self.song("b"), serverID: self.serverID)
        let item = try #require(JellyfinSongDrag.pasteboardItem(for: [first, second]))
        #expect(JellyfinSongDrag.payloads(from: [item]) == [first, second])

        let foreign = NSPasteboardItem()
        foreign.setString("42", forType: .string)
        #expect(JellyfinSongDrag.payloads(from: [foreign]).isEmpty)
    }

    // MARK: Play methods

    @Test("with no player, playing says the engine is not available")
    func noPlayer() async throws {
        let vm = try await LibraryViewModel(database: Database(location: .inMemory), engine: MockTransport())
        await vm.play(jellyfinSongs: [self.song("a")], serverID: self.serverID)
        #expect(vm.playbackErrorMessage == L10n.string("Playback engine isn't available."))
    }

    @Test("playing a server's songs queues them as .jellyfin items from that server")
    func playQueuesJellyfinItems() async throws {
        let db = try await Database(location: .inMemory)
        // No resolver: the queue is built, then the first load fails, which
        // proves the items went through the player and not around it.
        let player = QueuePlayer(engine: AudioEngine(), database: db)
        let vm = LibraryViewModel(database: db, engine: player)

        await vm.play(jellyfinSongs: [self.song("a"), self.song("b", title: "Second")], serverID: self.serverID, startingAt: 1)

        let sources = await player.queue.items.map(\.playableSource)
        #expect(sources == [
            .jellyfin(serverID: self.serverID, itemID: "a"),
            .jellyfin(serverID: self.serverID, itemID: "b"),
        ])
        #expect(vm.playbackErrorMessage == L10n.string("Could not play \"Second\" from this server."))
    }

    @Test("search hits keep each hit's own server")
    func multiSourceKeepsServers() async throws {
        let db = try await Database(location: .inMemory)
        let player = QueuePlayer(engine: AudioEngine(), database: db)
        let vm = LibraryViewModel(database: db, engine: player)
        let other = UUID()
        let hits = [
            JellyfinSongHit(serverID: self.serverID, serverName: "One", song: self.song("a")),
            JellyfinSongHit(serverID: other, serverName: "Two", song: self.song("b")),
        ]

        await vm.play(jellyfinMultiSource: hits)

        let sources = await player.queue.items.map(\.playableSource)
        #expect(sources == [
            .jellyfin(serverID: self.serverID, itemID: "a"),
            .jellyfin(serverID: other, itemID: "b"),
        ])
    }

    @Test("a drop appends .jellyfin items to Up Next")
    func dropAppends() async throws {
        let db = try await Database(location: .inMemory)
        let player = QueuePlayer(engine: AudioEngine(), database: db)
        let vm = LibraryViewModel(database: db, engine: player)
        let payload = JellyfinSongDragPayload(song: self.song("x"), serverID: self.serverID)

        await vm.addJellyfinSongsToQueue([payload])

        let sources = await player.queue.items.map(\.playableSource)
        #expect(sources == [.jellyfin(serverID: self.serverID, itemID: "x")])
    }
}
