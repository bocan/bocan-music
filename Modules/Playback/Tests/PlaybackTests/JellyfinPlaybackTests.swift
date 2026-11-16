import AudioEngine
import Foundation
import Persistence
import Testing
@testable import Playback

// MARK: - Stubs

/// Records every resolver call and returns a canned URL or error.
private actor StubJellyfinResolver: JellyfinStreamResolving {
    private let result: Result<URL, URLError>
    private(set) var resolveCalls: [(serverID: UUID, itemID: String)] = []

    init(result: Result<URL, URLError>) {
        self.result = result
    }

    func localFileURL(serverID: UUID, itemID: String) async throws -> URL {
        self.resolveCalls.append((serverID, itemID))
        return try self.result.get()
    }

    func precache(serverID _: UUID, itemID _: String) async {}
}

/// Captures what the history recorder sends.
private actor NowPlayingSink: ScrobbleSink {
    private(set) var nowPlayingTrackIDs: [Int64] = []
    private(set) var recordedTrackIDs: [Int64] = []
    private(set) var nowPlayingJellyfin: [JellyfinPlayContext] = []
    private(set) var recordedJellyfin: [(context: JellyfinPlayContext, played: TimeInterval)] = []

    func recordPlay(trackID: Int64, playedAt _: Date, durationPlayed _: TimeInterval) async {
        self.recordedTrackIDs.append(trackID)
    }

    func nowPlaying(trackID: Int64) async {
        self.nowPlayingTrackIDs.append(trackID)
    }

    func recordJellyfinPlay(context: JellyfinPlayContext, playedAt _: Date, durationPlayed: TimeInterval) async {
        self.recordedJellyfin.append((context, durationPlayed))
    }

    func nowPlayingJellyfin(context: JellyfinPlayContext) async {
        self.nowPlayingJellyfin.append(context)
    }
}

private func makeFormat() -> AudioSourceFormat {
    AudioSourceFormat(sampleRate: 44100, bitDepth: 16, channelCount: 2, isInterleaved: false, codec: "jellyfin")
}

private func makeJellyfinItem(serverID: UUID, itemID: String) -> QueueItem {
    QueueItem(
        trackID: -1,
        bookmark: nil,
        fileURL: "jellyfin://\(serverID.uuidString)/\(itemID)",
        duration: 200,
        sourceFormat: makeFormat(),
        title: "Song",
        artistName: "Artist",
        playableSource: .jellyfin(serverID: serverID, itemID: itemID)
    )
}

// MARK: - PlayableSource.jellyfin

@Suite("PlayableSource.jellyfin (ADR-097)")
struct JellyfinPlayableSourceTests {
    @Test("a Jellyfin source is remote and finite")
    func remoteAndFinite() {
        let source = PlayableSource.jellyfin(serverID: UUID(), itemID: "0a1b2c")
        #expect(source.isRemote)
        #expect(!source.isLiveStream)
    }

    @Test("the Jellyfin accessors answer only for a Jellyfin source")
    func accessors() {
        let id = UUID()
        let source = PlayableSource.jellyfin(serverID: id, itemID: "abc123")
        #expect(source.jellyfinServerID == id)
        #expect(source.jellyfinItemID == "abc123")
        #expect(source.subsonicServerID == nil)
        #expect(source.subsonicSongID == nil)
        let subsonic = PlayableSource.subsonic(serverID: id, songID: "abc123")
        #expect(subsonic.jellyfinServerID == nil)
        #expect(subsonic.jellyfinItemID == nil)
        #expect(PlayableSource.localBookmark(Data()).jellyfinItemID == nil)
    }

    @Test("a Jellyfin source survives a Codable round trip, item id unchanged")
    func roundTrip() throws {
        // Upper case and no dashes: the id is opaque and must come back as it went in.
        let value = PlayableSource.jellyfin(serverID: UUID(), itemID: "4F2A9C0D1E2B3A4C5D6E7F8091A2B3C4")
        let data = try JSONEncoder().encode(value)
        #expect(try JSONDecoder().decode(PlayableSource.self, from: data) == value)
    }

    @Test("the wire form uses its own kind and the serverID and itemID keys")
    func wireForm() throws {
        let serverID = try #require(UUID(uuidString: "6F9619FF-8B86-D011-B42D-00C04FC964FF"))
        let json = Data(#"{"kind":"jellyfin","serverID":"6F9619FF-8B86-D011-B42D-00C04FC964FF","itemID":"i-9"}"#.utf8)
        let decoded = try JSONDecoder().decode(PlayableSource.self, from: json)
        #expect(decoded == .jellyfin(serverID: serverID, itemID: "i-9"))

        let encoded = try JSONEncoder().encode(PlayableSource.jellyfin(serverID: serverID, itemID: "i-9"))
        let object = try #require(try JSONSerialization.jsonObject(with: encoded) as? [String: String])
        #expect(object["kind"] == "jellyfin")
        #expect(object["itemID"] == "i-9")
        #expect(object["songID"] == nil)
    }

    @Test("a Subsonic blob still decodes as Subsonic")
    func subsonicUnchanged() throws {
        let json = Data(#"{"kind":"subsonic","serverID":"6F9619FF-8B86-D011-B42D-00C04FC964FF","songID":"tr-1"}"#.utf8)
        let decoded = try JSONDecoder().decode(PlayableSource.self, from: json)
        #expect(decoded.subsonicSongID == "tr-1")
        #expect(decoded.jellyfinItemID == nil)
    }
}

// MARK: - QueuePlayer resolution

@Suite("QueuePlayer Jellyfin resolution (ADR-097)")
struct JellyfinQueuePlayerTests {
    @Test("a Jellyfin item resolves through the Jellyfin resolver")
    func resolvesThroughResolver() async throws {
        let db = try await Database(location: .inMemory)
        let cached = URL(filePath: "/tmp/jellyfin-cache/song.flac")
        let stub = StubJellyfinResolver(result: .success(cached))
        let player = QueuePlayer(engine: AudioEngine(), database: db, jellyfinResolver: stub)
        let serverID = UUID()

        let resolved = try await player.resolvePlayableURL(for: makeJellyfinItem(serverID: serverID, itemID: "item-7"))

        #expect(resolved.url == cached)
        #expect(!resolved.resolvedFromPerFileBookmark)
        let calls = await stub.resolveCalls
        #expect(calls.count == 1)
        #expect(calls.first?.serverID == serverID)
        #expect(calls.first?.itemID == "item-7")
    }

    @Test("with no resolver, a Jellyfin item fails with a PlaybackError")
    func noResolver() async throws {
        let db = try await Database(location: .inMemory)
        let player = QueuePlayer(engine: AudioEngine(), database: db)
        await #expect(throws: PlaybackError.self) {
            _ = try await player.resolvePlayableURL(for: makeJellyfinItem(serverID: UUID(), itemID: "x"))
        }
    }

    @Test("a resolver failure becomes a PlaybackError")
    func resolverFailure() async throws {
        let db = try await Database(location: .inMemory)
        let stub = StubJellyfinResolver(result: .failure(URLError(.notConnectedToInternet)))
        let player = QueuePlayer(engine: AudioEngine(), database: db, jellyfinResolver: stub)
        await #expect(throws: PlaybackError.self) {
            _ = try await player.resolvePlayableURL(for: makeJellyfinItem(serverID: UUID(), itemID: "x"))
        }
    }

    @Test("a Subsonic item never reaches the Jellyfin resolver")
    func subsonicStaysSubsonic() async throws {
        let db = try await Database(location: .inMemory)
        let stub = StubJellyfinResolver(result: .success(URL(filePath: "/tmp/x.flac")))
        let player = QueuePlayer(engine: AudioEngine(), database: db, jellyfinResolver: stub)
        let item = QueueItem(
            trackID: -1,
            bookmark: nil,
            fileURL: "",
            duration: 1,
            sourceFormat: makeFormat(),
            playableSource: .subsonic(serverID: UUID(), songID: "s")
        )
        await #expect(throws: PlaybackError.self) {
            _ = try await player.resolvePlayableURL(for: item)
        }
        #expect(await stub.resolveCalls.isEmpty)
    }

    @Test("a remote item is never looked up in the tracks table, so no lookup failure is logged")
    func remoteItemSkipsTrackLookup() async throws {
        let db = try await Database(location: .inMemory)
        let player = QueuePlayer(engine: AudioEngine(), database: db)
        #expect(await player.nowPlayingTrack(for: makeJellyfinItem(serverID: UUID(), itemID: "x")) == nil)
        // The log line cannot be read back, so pin the guard that skips the read.
        let file = URL(filePath: #filePath)
            .deletingLastPathComponent() // PlaybackTests/
            .deletingLastPathComponent() // Tests/
            .deletingLastPathComponent() // Modules/Playback/
            .appendingPathComponent("Sources/Playback/QueuePlayer+Loading.swift")
        let source = try String(contentsOf: file, encoding: .utf8)
        #expect(source.contains("guard !item.playableSource.isRemote else { return nil }"))
    }

    @Test("a Jellyfin start sends the Jellyfin now-playing hint, never the local one")
    func jellyfinStartUsesItsOwnContext() async throws {
        let db = try await Database(location: .inMemory)
        let sink = NowPlayingSink()
        let player = QueuePlayer(engine: AudioEngine(), database: db, scrobbleSink: sink)
        let serverID = UUID()

        await player.notifyHistoryStart(for: makeJellyfinItem(serverID: serverID, itemID: "x"))

        let deadline = ContinuousClock.now + .seconds(20)
        while await sink.nowPlayingJellyfin.isEmpty, ContinuousClock.now < deadline {
            await Task.yield()
        }
        let hint = try #require(await sink.nowPlayingJellyfin.first)
        #expect(hint.serverID == serverID)
        #expect(hint.itemID == "x")
        #expect(hint.title == "Song")
        #expect(hint.duration == 200)
        #expect(await sink.nowPlayingTrackIDs.isEmpty)
    }

    @Test("jellyfinPlayContext answers only for a Jellyfin item")
    func playContextOnlyForJellyfin() {
        let serverID = UUID()
        let context = QueuePlayer.jellyfinPlayContext(for: makeJellyfinItem(serverID: serverID, itemID: "i"))
        #expect(context?.serverID == serverID)
        #expect(context?.artist == "Artist")
        let local = QueueItem(trackID: 5, bookmark: nil, fileURL: "/tmp/5.flac", duration: 1, sourceFormat: makeFormat())
        #expect(QueuePlayer.jellyfinPlayContext(for: local) == nil)
    }
}

// MARK: - History recorder, Jellyfin path

@Suite("PlayHistoryRecorder Jellyfin plays (ADR-097)")
struct JellyfinHistoryRecorderTests {
    private func context(duration: TimeInterval = 200) -> JellyfinPlayContext {
        JellyfinPlayContext(serverID: UUID(), itemID: "item-1", title: "Song", artist: "Artist", duration: duration)
    }

    @Test("a play past the threshold is handed to the sink once, with no local history")
    func countedPlayIsRecordedOnce() async throws {
        let db = try await Database(location: .inMemory)
        let sink = NowPlayingSink()
        let recorder = PlayHistoryRecorder(database: db, scrobbleSink: sink)
        let context = self.context()

        await recorder.trackDidStart(jellyfin: context)
        await recorder.update(elapsed: 120) // past half of 200 s
        await recorder.update(elapsed: 150)
        await recorder.trackDidEnd(elapsed: 200)

        let recorded = await sink.recordedJellyfin
        #expect(recorded.count == 1)
        #expect(recorded.first?.context == context)
        #expect(recorded.first?.played == 120)
        #expect(await sink.recordedTrackIDs.isEmpty)
        let historyRows = try await db.read { grdb in try Int.fetchOne(grdb, sql: "SELECT COUNT(*) FROM play_history") }
        #expect(historyRows == 0)
    }

    @Test("a skip before the threshold sends nothing")
    func earlySkipSendsNothing() async throws {
        let db = try await Database(location: .inMemory)
        let sink = NowPlayingSink()
        let recorder = PlayHistoryRecorder(database: db, scrobbleSink: sink)

        await recorder.trackDidStart(jellyfin: self.context())
        await recorder.trackSkipped(elapsed: 20)

        #expect(await sink.recordedJellyfin.isEmpty)
    }

    @Test("a local track after a Jellyfin one is recorded as local, not as the Jellyfin song")
    func contextClearsOnNextStart() async throws {
        let db = try await Database(location: .inMemory)
        let sink = NowPlayingSink()
        let recorder = PlayHistoryRecorder(database: db, scrobbleSink: sink)

        await recorder.trackDidStart(jellyfin: self.context())
        await recorder.trackDidStart(trackID: 9, duration: 100)
        await recorder.trackSkipped(elapsed: 90)

        #expect(await sink.recordedJellyfin.isEmpty)
    }
}

// MARK: - Queue restore with an unreadable item

@Suite("QueuePersistence drops only the item it cannot read (ADR-097)")
struct QueuePersistenceLenientRestoreTests {
    /// Saves a real queue of `count` Subsonic items (track ids 0 ..< count),
    /// rewrites the source kind of the items at `unknown` to one no build knows,
    /// as a newer build's queue looks to an older one, and restores it.
    private func restore(count: Int, unknown: Set<Int>, currentIndex: Int) async throws -> RestoredQueue? {
        let db = try await Database(location: .inMemory)
        let persistence = QueuePersistence(database: db, debounce: .milliseconds(1))
        let items = (0 ..< count).map { index in
            QueueItem(
                trackID: Int64(index),
                bookmark: nil,
                fileURL: "",
                duration: 60,
                sourceFormat: makeFormat(),
                playableSource: .subsonic(serverID: UUID(), songID: "s\(index)")
            )
        }
        await persistence.scheduleSave(items: items, currentIndex: currentIndex, repeatMode: .off, shuffleState: .off)
        await persistence.awaitPendingSaveForTesting()

        let repo = SettingsRepository(database: db)
        let saved = try #require(try await repo.get(AnyJSON.self, for: QueuePersistence.settingsKeyV2))
        guard case var .object(payload) = saved, case var .array(rows) = payload["items"] else {
            Issue.record("the saved queue is not the expected shape")
            return nil
        }
        for index in unknown {
            guard case var .object(row) = rows[index], case var .object(source) = row["playableSource"] else { continue }
            source["kind"] = .string("aKindFromTheFuture")
            row["playableSource"] = .object(source)
            rows[index] = .object(row)
        }
        payload["items"] = .array(rows)
        try await repo.set(AnyJSON.object(payload), for: QueuePersistence.settingsKeyV2)
        return await persistence.restore()
    }

    @Test("an unknown kind loses that one item and keeps the rest")
    func unknownKindLosesOneItem() async throws {
        let restored = try #require(try await self.restore(count: 3, unknown: [1], currentIndex: 2))
        #expect(restored.items.map(\.trackID) == [0, 2])
        #expect(restored.currentIndex == 1, "still points at the same item")
    }

    @Test("a dropped current item hands over to the next survivor")
    func droppedCurrentMovesOn() async throws {
        let restored = try #require(try await self.restore(count: 3, unknown: [1], currentIndex: 1))
        #expect(restored.currentIndex == 1)
        #expect(restored.items[1].trackID == 2)
    }

    @Test("a dropped last item that was current leaves nothing current")
    func droppedLastCurrent() async throws {
        let restored = try #require(try await self.restore(count: 2, unknown: [1], currentIndex: 1))
        #expect(restored.items.map(\.trackID) == [0])
        #expect(restored.currentIndex == nil)
    }

    @Test("a queue with a Jellyfin item round-trips in this build")
    func jellyfinRoundTrip() async throws {
        let db = try await Database(location: .inMemory)
        let persistence = QueuePersistence(database: db, debounce: .milliseconds(1))
        let serverID = UUID()
        let items = [
            QueueItem(trackID: 1, bookmark: nil, fileURL: "/tmp/1.flac", duration: 1, sourceFormat: makeFormat()),
            makeJellyfinItem(serverID: serverID, itemID: "abc"),
        ]
        await persistence.scheduleSave(items: items, currentIndex: 1, repeatMode: .off, shuffleState: .off)
        await persistence.awaitPendingSaveForTesting()

        let restored = try #require(await persistence.restore())
        #expect(restored.items.count == 2)
        #expect(restored.items[1].playableSource == .jellyfin(serverID: serverID, itemID: "abc"))
        #expect(restored.currentIndex == 1)
    }
}

// MARK: - AnyJSON

/// Any JSON value, so a hand-built blob can go through `SettingsRepository.set`.
private enum AnyJSON: Codable {
    case object([String: Self])
    case array([Self])
    case string(String)
    case number(Double)
    case bool(Bool)
    case null

    /// Reads any JSON value. `Swift.` because AudioEngine has its own `Decoder` protocol.
    init(from decoder: any Swift.Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([Self].self) {
            self = .array(value)
        } else {
            self = try .object(container.decode([String: Self].self))
        }
    }

    func encode(to encoder: any Swift.Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case let .object(value):
            try container.encode(value)

        case let .array(value):
            try container.encode(value)

        case let .string(value):
            try container.encode(value)

        case let .number(value):
            try container.encode(value)

        case let .bool(value):
            try container.encode(value)

        case .null:
            try container.encodeNil()
        }
    }
}
