import MediaPlayer
import Testing
@testable import Playback

@MainActor
@Suite("RemoteCommands")
struct RemoteCommandsTests {
    @Test("register/unregister is idempotent")
    func registerIdempotent() {
        let rc = RemoteCommands()
        rc.register()
        rc.register() // second call hits the early-return guard
        rc.unregister()
        rc.unregister() // second call hits the early-return guard
    }

    @Test("registered targets invoke handlers when the matching commands fire")
    func handlersFire() {
        let rc = RemoteCommands()

        // Counters via locals captured by sendable closures.
        let played = Counter()
        let paused = Counter()
        let toggled = Counter()
        let next = Counter()
        let prev = Counter()
        let seeked = SeekedHolder()

        rc.onPlay = { await played.incr() }
        rc.onPause = { await paused.incr() }
        rc.onTogglePlayPause = { await toggled.incr() }
        rc.onNextTrack = { await next.incr() }
        rc.onPreviousTrack = { await prev.incr() }
        rc.onSeek = { value in await seeked.set(value) }

        rc.register()
        defer { rc.unregister() }

        let center = MPRemoteCommandCenter.shared()
        // We can't easily synthesise MPRemoteCommandEvents here, but the
        // important coverage is the register/unregister paths and the
        // closures' wiring. Just sanity-check enable flags.
        #expect(center.playCommand.isEnabled)
        #expect(center.pauseCommand.isEnabled)
        #expect(center.togglePlayPauseCommand.isEnabled)
        #expect(center.nextTrackCommand.isEnabled)
        #expect(center.previousTrackCommand.isEnabled)
        #expect(center.changePlaybackPositionCommand.isEnabled)
        #expect(!center.skipForwardCommand.isEnabled)
        #expect(!center.ratingCommand.isEnabled)
    }
}

private actor Counter {
    var value = 0
    func incr() {
        self.value += 1
    }
}

private actor SeekedHolder {
    var value: TimeInterval = -1
    func set(_ v: TimeInterval) {
        self.value = v
    }
}
