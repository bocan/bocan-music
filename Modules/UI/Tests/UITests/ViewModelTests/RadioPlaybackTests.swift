import AudioEngine
import Foundation
import Persistence
import Playback
import Testing
@testable import UI

@MainActor
@Suite("Radio playback")
struct RadioPlaybackTests {
    private static func makeStations(count: Int) -> [RadioStation] {
        (0 ..< count).map {
            RadioStation(name: "Station \($0)", streamURL: "https://\($0).example/stream", addedAt: 0)
        }
    }

    /// Polls until the engine reports `url` as playing, or `timeout` elapses
    /// (mirrors `NowPlayingRadioRestoreTests`'s pattern: `nowPlayingRadioStreamURL`
    /// populates from the queue replace itself, not from a real connection,
    /// so an unreachable stream URL is fine here).
    private static func waitForRadioStream(_ vm: LibraryViewModel, _ url: String, timeout: TimeInterval = 5) async {
        let deadline = Date().addingTimeInterval(timeout)
        while vm.nowPlaying.nowPlayingRadioStreamURL != url, Date() < deadline {
            try? await Task.sleep(nanoseconds: 25_000_000)
        }
    }

    // MARK: - Queue item factory

    @Test("makeInternetRadio keeps the live-stream conventions")
    func factoryConventions() throws {
        let url = try #require(URL(string: "https://ice2.somafm.com/deepspaceone-128-mp3"))
        let item = QueueItem.makeInternetRadio(
            name: "Deep Space One",
            streamURL: url,
            homePage: "https://somafm.com"
        )

        #expect(item.trackID == -1)
        #expect(item.bookmark == nil)
        #expect(item.duration == 0, "duration 0 is what disables the scrubber and scrobbling")
        #expect(item.fileURL == url.absoluteString)
        #expect(item.title == "Deep Space One")
        #expect(item.albumName == "https://somafm.com")
        #expect(item.sourceFormat.codec == "stream")
        #expect(item.playableSource == .internetRadio(streamURL: url))
    }

    @Test("makeInternetRadio tolerates a missing home page")
    func factoryWithoutHomePage() throws {
        let url = try #require(URL(string: "https://a.example/stream"))
        let item = QueueItem.makeInternetRadio(name: "A", streamURL: url, homePage: nil)
        #expect(item.albumName == nil)
        #expect(item.playableSource == .internetRadio(streamURL: url))
    }

    @Test("play(radioStation:) surfaces an error when the engine is unavailable")
    func playWithoutEngineSetsError() async throws {
        let db = try await Database(location: .inMemory)
        let vm = LibraryViewModel(database: db, engine: MockTransport())
        let station = RadioStation(
            name: "Deep Space One",
            streamURL: "https://ice2.somafm.com/deepspaceone-128-mp3",
            addedAt: 0
        )

        await vm.play(radioStation: station)

        #expect(vm.playbackErrorMessage != nil)
    }

    // MARK: - Adjacent-station wraparound (pure logic)

    @Test("adjacentStation steps to the immediate neighbor without wrapping")
    func adjacentStationSteps() {
        let stations = Self.makeStations(count: 3)
        #expect(
            LibraryViewModel.adjacentStation(to: stations[0].streamURL, offset: 1, in: stations)?.streamURL
                == stations[1].streamURL
        )
        #expect(
            LibraryViewModel.adjacentStation(to: stations[2].streamURL, offset: -1, in: stations)?.streamURL
                == stations[1].streamURL
        )
    }

    @Test("adjacentStation wraps forward from the last station to the first")
    func adjacentStationWrapsForward() {
        let stations = Self.makeStations(count: 3)
        let next = LibraryViewModel.adjacentStation(to: stations[2].streamURL, offset: 1, in: stations)
        #expect(next?.streamURL == stations[0].streamURL)
    }

    @Test("adjacentStation wraps backward from the first station to the last")
    func adjacentStationWrapsBackward() {
        let stations = Self.makeStations(count: 3)
        let previous = LibraryViewModel.adjacentStation(to: stations[0].streamURL, offset: -1, in: stations)
        #expect(previous?.streamURL == stations[2].streamURL)
    }

    @Test("adjacentStation returns nil when the current URL isn't in the catalog")
    func adjacentStationReturnsNilForUnknownURL() {
        let stations = Self.makeStations(count: 2)
        let result = LibraryViewModel.adjacentStation(to: "https://unknown.example/stream", offset: 1, in: stations)
        #expect(result == nil, "an ephemeral stream outside the catalog must not guess at a neighbor")
    }

    @Test("adjacentStation returns nil for an empty catalog")
    func adjacentStationReturnsNilForEmptyCatalog() {
        let result = LibraryViewModel.adjacentStation(to: "https://a.example/stream", offset: 1, in: [])
        #expect(result == nil)
    }

    @Test("adjacentStation self-wraps a single-station catalog in both directions")
    func adjacentStationSingleStationSelfWraps() {
        let stations = Self.makeStations(count: 1)
        #expect(
            LibraryViewModel.adjacentStation(to: stations[0].streamURL, offset: 1, in: stations)?.streamURL
                == stations[0].streamURL
        )
        #expect(
            LibraryViewModel.adjacentStation(to: stations[0].streamURL, offset: -1, in: stations)?.streamURL
                == stations[0].streamURL
        )
    }

    // MARK: - Next / previous station (no radio playing)

    @Test("playNextStation is a no-op when no radio station is playing")
    func playNextStationNoOpWithoutRadio() async throws {
        let db = try await Database(location: .inMemory)
        let vm = LibraryViewModel(database: db, engine: MockTransport())

        await vm.playNextStation()

        #expect(vm.playbackErrorMessage == nil)
    }

    @Test("playPreviousStation is a no-op when no radio station is playing")
    func playPreviousStationNoOpWithoutRadio() async throws {
        let db = try await Database(location: .inMemory)
        let vm = LibraryViewModel(database: db, engine: MockTransport())

        await vm.playPreviousStation()

        #expect(vm.playbackErrorMessage == nil)
    }

    // MARK: - Next / previous station (live engine, end to end)

    @Test("playNextStation and playPreviousStation cycle through the catalog with wraparound")
    func nextAndPreviousStationsCycleWithWraparound() async throws {
        let db = try await Database(location: .inMemory)
        let player = QueuePlayer(engine: AudioEngine(), database: db)
        await player.waitUntilActivated()
        let vm = LibraryViewModel(database: db, engine: player)

        let urls = [
            "http://127.0.0.1:9/station-a",
            "http://127.0.0.1:9/station-b",
            "http://127.0.0.1:9/station-c",
        ]
        for (index, url) in urls.enumerated() {
            try await vm.radioStations.insert(RadioStation(name: "Station \(index)", streamURL: url, addedAt: 0))
        }
        let stations = try await vm.radioStations.fetchAll()
        #expect(stations.count == 3)

        await vm.play(radioStation: stations[0])
        await Self.waitForRadioStream(vm, urls[0])
        #expect(vm.nowPlaying.nowPlayingRadioStreamURL == urls[0])

        await vm.playNextStation()
        await Self.waitForRadioStream(vm, urls[1])
        #expect(vm.nowPlaying.nowPlayingRadioStreamURL == urls[1])

        await vm.playNextStation()
        await Self.waitForRadioStream(vm, urls[2])
        #expect(vm.nowPlaying.nowPlayingRadioStreamURL == urls[2])

        await vm.playNextStation()
        await Self.waitForRadioStream(vm, urls[0])
        #expect(vm.nowPlaying.nowPlayingRadioStreamURL == urls[0], "next from the last station must wrap to the first")

        await vm.playPreviousStation()
        await Self.waitForRadioStream(vm, urls[2])
        #expect(
            vm.nowPlaying.nowPlayingRadioStreamURL == urls[2],
            "previous from the first station must wrap to the last"
        )
    }

    @Test("playNextStation restarts the same station in a single-station catalog")
    func nextStationRestartsSingleStationCatalog() async throws {
        let db = try await Database(location: .inMemory)
        let player = QueuePlayer(engine: AudioEngine(), database: db)
        await player.waitUntilActivated()
        let vm = LibraryViewModel(database: db, engine: player)
        let url = "http://127.0.0.1:9/only-station"
        try await vm.radioStations.insert(RadioStation(name: "Only Station", streamURL: url, addedAt: 0))
        let station = try #require(try await vm.radioStations.fetchAll().first)

        await vm.play(radioStation: station)
        await Self.waitForRadioStream(vm, url)

        await vm.playNextStation()
        await Self.waitForRadioStream(vm, url)

        #expect(vm.nowPlaying.nowPlayingRadioStreamURL == url)
    }
}
