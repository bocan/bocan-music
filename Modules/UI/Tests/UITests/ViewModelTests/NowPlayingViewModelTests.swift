import AudioEngine
import Foundation
import Observability
import Testing
@testable import Persistence
@testable import UI

// MARK: - Mock Transport

/// Minimal in-memory Transport for ViewModel tests.
final class MockTransport: Transport, @unchecked Sendable {
    var currentTime: TimeInterval {
        self._currentTime
    }

    var duration: TimeInterval {
        self._duration
    }

    var state: AsyncStream<PlaybackState> {
        self._stream
    }

    var _currentTime: TimeInterval = 0
    var _duration: TimeInterval = 0
    var loadedURL: URL?
    var playCallCount = 0
    var pauseCallCount = 0
    var seekTarget: TimeInterval?

    private let _stream: AsyncStream<PlaybackState>
    private let _continuation: AsyncStream<PlaybackState>.Continuation

    init() {
        var cont: AsyncStream<PlaybackState>.Continuation!
        self._stream = AsyncStream<PlaybackState> { cont = $0 }
        self._continuation = cont
    }

    func emit(_ state: PlaybackState) {
        self._continuation.yield(state)
    }

    func load(_ url: URL) async throws {
        self.loadedURL = url
        self.emit(.loading)
        self.emit(.ready)
    }

    func play() async throws {
        self.playCallCount += 1
        self.emit(.playing)
    }

    func pause() async {
        self.pauseCallCount += 1
        self.emit(.paused)
    }

    func stop() async {
        self.emit(.stopped)
    }

    func seek(to time: TimeInterval) async throws {
        self.seekTarget = time
    }
}

// MARK: - NowPlayingViewModelTests

@Suite("NowPlayingViewModel Tests")
@MainActor
struct NowPlayingViewModelTests {
    private func makeDatabase() async throws -> Database {
        try await Database(location: .inMemory)
    }

    @Test("Initial state is idle/empty")
    func initialState() async throws {
        let engine = MockTransport()
        let db = try await makeDatabase()
        let vm = NowPlayingViewModel(engine: engine, database: db)
        #expect(vm.title == "")
        #expect(!vm.isPlaying)
        #expect(vm.volume == 1.0)
        #expect(vm.position == 0)
    }

    @Test("setCurrentTrack updates title")
    func setCurrentTrackUpdatesTitle() async throws {
        let engine = MockTransport()
        let db = try await makeDatabase()
        let vm = NowPlayingViewModel(engine: engine, database: db)

        let now = Int64(Date().timeIntervalSince1970)
        let track = Track(
            fileURL: "file:///tmp/test.flac",
            fileSize: 1024,
            fileMtime: now,
            fileFormat: "flac",
            duration: 240,
            title: "Golden Years",
            addedAt: now,
            updatedAt: now
        )
        vm.setCurrentTrack(track)
        #expect(vm.title == "Golden Years")
        #expect(vm.duration == 240)
    }

    @Test("playPause calls play when paused")
    func playPauseCallsPlay() async throws {
        let engine = MockTransport()
        let db = try await makeDatabase()
        let vm = NowPlayingViewModel(engine: engine, database: db)
        #expect(!vm.isPlaying)
        await vm.playPause()
        #expect(engine.playCallCount == 1)
    }

    @Test("playPause calls pause when playing")
    func playPauseCallsPause() async throws {
        let engine = MockTransport()
        let db = try await makeDatabase()
        let vm = NowPlayingViewModel(engine: engine, database: db)
        // Transition to playing state
        try await engine.play()
        // Give state subscription a moment to process
        try await Task.sleep(nanoseconds: 100_000_000)
        #expect(vm.isPlaying)
        await vm.playPause()
        #expect(engine.pauseCallCount == 1)
    }

    @Test("scrub dispatches seek to engine")
    func scrubDispatchesSsek() async throws {
        let engine = MockTransport()
        let db = try await makeDatabase()
        let vm = NowPlayingViewModel(engine: engine, database: db)
        await vm.scrub(to: 42.5)
        #expect(engine.seekTarget == 42.5)
    }

    @Test("volume is clamped to [0, 1]")
    func volumeClamped() async throws {
        let engine = MockTransport()
        let db = try await makeDatabase()
        let vm = NowPlayingViewModel(engine: engine, database: db)

        await vm.setVolume(1.5)
        #expect(vm.volume == 1.0)

        await vm.setVolume(-0.5)
        #expect(vm.volume == 0.0)

        await vm.setVolume(0.75)
        #expect(vm.volume == 0.75)
    }
}
