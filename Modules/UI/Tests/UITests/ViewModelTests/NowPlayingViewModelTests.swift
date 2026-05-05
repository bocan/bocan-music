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
        self.storedCurrentTime
    }

    var duration: TimeInterval {
        self.storedDuration
    }

    var state: AsyncStream<PlaybackState> {
        self._stream
    }

    var storedCurrentTime: TimeInterval = 0
    var storedDuration: TimeInterval = 0
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

    func setVolume(_ vol: Float) async {
        self.lastSetVolume = vol
    }

    var lastSetVolume: Float = 1.0
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
        #expect(vm.title.isEmpty)
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

    @Test("playPause resumes when paused")
    func playPauseCallsPlay() async throws {
        let engine = MockTransport()
        let db = try await makeDatabase()
        let vm = NowPlayingViewModel(engine: engine, database: db)
        #expect(!vm.isPlaying)
        // Put the VM into a paused state so playPause triggers resume.
        engine.emit(.paused)
        for _ in 0 ..< 100 {
            if vm.isPaused { break }
            await Task.yield()
        }
        try #require(vm.isPaused)
        await vm.playPause()
        #expect(engine.playCallCount == 1)
    }

    @Test("playPause invokes onPlayFromEmptyQueue when idle")
    func playPauseCallsEmptyQueueCallback() async throws {
        let engine = MockTransport()
        let db = try await makeDatabase()
        let vm = NowPlayingViewModel(engine: engine, database: db)
        var callbackFired = false
        vm.onPlayFromEmptyQueue = { callbackFired = true }
        #expect(!vm.isPlaying)
        #expect(!vm.isPaused)
        await vm.playPause()
        #expect(callbackFired)
        #expect(engine.playCallCount == 0)
    }

    @Test("playPause calls pause when playing")
    func playPauseCallsPause() async throws {
        let engine = MockTransport()
        let db = try await makeDatabase()
        let vm = NowPlayingViewModel(engine: engine, database: db)
        // Emit playing state directly (synchronous, no scheduling ambiguity).
        engine.emit(.playing)
        // Yield until the @MainActor stateTask processes the event.
        // A sleep is unreliable: under --enable-code-coverage, concurrent @MainActor
        // snapshot tests can hold the main actor beyond the sleep window.
        for _ in 0 ..< 100 {
            if vm.isPlaying { break }
            await Task.yield()
        }
        try #require(vm.isPlaying)
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

    // MARK: - Previous / restart threshold

    @Test("previous within first 3 seconds does not restart (delegates to qp.previous)")
    func previousWithinThresholdDoesNotRestart() async throws {
        let engine = MockTransport()
        let db = try await makeDatabase()
        let vm = NowPlayingViewModel(engine: engine, database: db)
        // 2.9 s — within the restart threshold.
        engine.storedCurrentTime = 2.9
        await vm.previous()
        // The "restart" code path calls scrub(to:0) → engine.seek(to:0).
        // It must NOT have been taken; seekTarget stays nil.
        #expect(engine.seekTarget == nil)
    }

    @Test("previous past 3 seconds restarts current track")
    func previousPastThresholdRestartsTrack() async throws {
        let engine = MockTransport()
        let db = try await makeDatabase()
        let vm = NowPlayingViewModel(engine: engine, database: db)
        // 5.0 s — past the restart threshold.
        engine.storedCurrentTime = 5.0
        await vm.previous()
        #expect(engine.seekTarget == 0.0)
    }

    @Test("restartTrack always scrubs to zero")
    func restartTrackScrubsToZero() async throws {
        let engine = MockTransport()
        let db = try await makeDatabase()
        let vm = NowPlayingViewModel(engine: engine, database: db)
        engine.storedCurrentTime = 120.0
        await vm.restartTrack()
        #expect(engine.seekTarget == 0.0)
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

    @Test("toggleMute silences engine without changing stored volume")
    func toggleMuteSilences() async throws {
        let engine = MockTransport()
        let db = try await makeDatabase()
        let vm = NowPlayingViewModel(engine: engine, database: db)
        await vm.setVolume(0.6)
        #expect(engine.lastSetVolume == 0.6)

        // Mute: engine receives 0, stored volume unchanged.
        await vm.toggleMute()
        #expect(vm.isMuted == true)
        #expect(vm.volume == 0.6)
        #expect(engine.lastSetVolume == 0.0)

        // Un-mute: engine restored to stored volume.
        await vm.toggleMute()
        #expect(vm.isMuted == false)
        #expect(vm.volume == 0.6)
        #expect(engine.lastSetVolume == 0.6)
    }

    @Test("setVolume while muted preserves mute")
    func setVolumeWhileMuted() async throws {
        let engine = MockTransport()
        let db = try await makeDatabase()
        let vm = NowPlayingViewModel(engine: engine, database: db)
        await vm.setVolume(0.8)
        await vm.toggleMute()
        #expect(vm.isMuted == true)

        // Adjusting volume while muted should update stored level but not send to engine.
        await vm.setVolume(0.5)
        #expect(vm.volume == 0.5)
        #expect(engine.lastSetVolume == 0.0) // engine still silent

        // Un-mute restores to the new stored level.
        await vm.toggleMute()
        #expect(engine.lastSetVolume == 0.5)
    }

    // MARK: - Speed

    @Test("quickRates is sorted ascending from 0.75 to 2.0")
    func quickRatesOrder() {
        let rates = NowPlayingViewModel.quickRates
        #expect(rates.first == 0.75)
        #expect(rates.last == 2.0)
        #expect(rates == rates.sorted())
        #expect(rates.contains(1.0))
    }

    @Test("increaseSpeed and decreaseSpeed are no-ops without a QueuePlayer")
    func speedStepNoOpWithoutQueuePlayer() async throws {
        let engine = MockTransport()
        let db = try await makeDatabase()
        let vm = NowPlayingViewModel(engine: engine, database: db)
        // MockTransport is not a QueuePlayer, so setRate guards early.
        // Verify calls don't crash and playbackRate remains 1.0.
        await vm.increaseSpeed()
        #expect(vm.playbackRate == 1.0)
        await vm.decreaseSpeed()
        #expect(vm.playbackRate == 1.0)
        await vm.resetSpeed()
        #expect(vm.playbackRate == 1.0)
    }

    @Test("playbackRate is restored from UserDefaults on init")
    func playbackRateRestoredFromUserDefaults() async throws {
        let db = try await makeDatabase()
        UserDefaults.standard.set(1.5, forKey: "playback.rate")
        defer { UserDefaults.standard.removeObject(forKey: "playback.rate") }
        let vm = NowPlayingViewModel(engine: MockTransport(), database: db)
        #expect(vm.playbackRate == 1.5)
    }

    @Test("playbackRate clamps out-of-range UserDefaults value on init")
    func playbackRateClampedFromUserDefaults() async throws {
        let db = try await makeDatabase()
        UserDefaults.standard.set(5.0, forKey: "playback.rate")
        defer { UserDefaults.standard.removeObject(forKey: "playback.rate") }
        let vm = NowPlayingViewModel(engine: MockTransport(), database: db)
        #expect(vm.playbackRate == 2.0)
    }

    @Test("playbackRate stays at 1.0 when no UserDefaults value is stored")
    func playbackRateDefaultsToUnityWhenAbsent() async throws {
        UserDefaults.standard.removeObject(forKey: "playback.rate")
        let vm = try await NowPlayingViewModel(engine: MockTransport(), database: makeDatabase())
        #expect(vm.playbackRate == 1.0)
    }

    // MARK: - Volume step

    @Test("increaseVolume steps up by 0.1, clamped to 1.0")
    func increaseVolumeSteps() async throws {
        let db = try await makeDatabase()
        let vm = NowPlayingViewModel(engine: MockTransport(), database: db)
        await vm.setVolume(0.8)
        await vm.increaseVolume()
        #expect(abs(vm.volume - 0.9) < 0.001)
        await vm.increaseVolume()
        #expect(vm.volume == 1.0)
        // Clamped at 1.0.
        await vm.increaseVolume()
        #expect(vm.volume == 1.0)
    }

    @Test("decreaseVolume steps down by 0.1, clamped to 0.0")
    func decreaseVolumeSteps() async throws {
        let db = try await makeDatabase()
        let vm = NowPlayingViewModel(engine: MockTransport(), database: db)
        await vm.setVolume(0.2)
        await vm.decreaseVolume()
        #expect(abs(vm.volume - 0.1) < 0.001)
        await vm.decreaseVolume()
        #expect(vm.volume == 0.0)
        // Clamped at 0.0.
        await vm.decreaseVolume()
        #expect(vm.volume == 0.0)
    }

    // MARK: - Sleep timer

    @Test("sleepPresets contains Off and all expected durations")
    func sleepPresetsContents() {
        let presets = NowPlayingViewModel.sleepPresets
        #expect(presets.contains { $0.minutes == nil }, "Off preset missing")
        #expect(presets.contains { $0.minutes == 15 })
        #expect(presets.contains { $0.minutes == 30 })
        #expect(presets.contains { $0.minutes == 60 })
        #expect(presets.contains { $0.minutes == 120 })
        // First entry should be Off so it appears at the top of the menu.
        #expect(presets.first?.minutes == nil)
    }

    @Test("sleepTimerActiveMinutes is nil initially and unchanged without QueuePlayer")
    func sleepTimerActiveMinutesNoOpWithoutQueuePlayer() async throws {
        let engine = MockTransport()
        let db = try await makeDatabase()
        let vm = NowPlayingViewModel(engine: engine, database: db)
        #expect(vm.sleepTimerActiveMinutes == nil)
        // MockTransport is not a QueuePlayer, so setSleepTimer guards early.
        await vm.setSleepTimer(minutes: 30)
        #expect(vm.sleepTimerActiveMinutes == nil)
        await vm.setSleepTimer(minutes: nil)
        #expect(vm.sleepTimerActiveMinutes == nil)
    }
}
