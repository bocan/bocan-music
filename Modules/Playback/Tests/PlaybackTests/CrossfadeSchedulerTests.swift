@preconcurrency import AVFoundation
import Testing
@testable import Playback

@Suite("CrossfadeScheduler")
struct CrossfadeSchedulerTests {
    @Test("default config disables crossfade")
    func defaultDisabled() async {
        let scheduler = CrossfadeScheduler()
        let enabled = await scheduler.isEnabled
        #expect(!enabled)
        let half = await scheduler.halfDurationSeconds
        #expect(half == 0)
    }

    @Test("setConfig updates isEnabled / halfDurationSeconds")
    func setConfigUpdates() async {
        let scheduler = CrossfadeScheduler()
        await scheduler.setConfig(.init(durationSeconds: 4, albumGapless: true))
        #expect(await scheduler.isEnabled)
        #expect(await scheduler.halfDurationSeconds == 2.0)
    }

    @Test("crossfadeAllowed is false when duration is 0")
    func notAllowedWhenZero() async {
        let scheduler = CrossfadeScheduler()
        let allowed = await scheduler.crossfadeAllowed(currentAlbumID: 1, nextAlbumID: 2)
        #expect(!allowed)
    }

    @Test("crossfadeAllowed is false when albums match and albumGapless = true")
    func notAllowedSameAlbumGapless() async {
        let scheduler = CrossfadeScheduler()
        await scheduler.setConfig(.init(durationSeconds: 4, albumGapless: true))
        let allowed = await scheduler.crossfadeAllowed(currentAlbumID: 5, nextAlbumID: 5)
        #expect(!allowed)
    }

    @Test("crossfadeAllowed is true when albums differ")
    func allowedDifferentAlbums() async {
        let scheduler = CrossfadeScheduler()
        await scheduler.setConfig(.init(durationSeconds: 4, albumGapless: true))
        let allowed = await scheduler.crossfadeAllowed(currentAlbumID: 1, nextAlbumID: 2)
        #expect(allowed)
    }

    @Test("crossfadeAllowed is true when albumGapless is false even for matching albums")
    func allowedWhenAlbumGaplessOff() async {
        let scheduler = CrossfadeScheduler()
        await scheduler.setConfig(.init(durationSeconds: 4, albumGapless: false))
        let allowed = await scheduler.crossfadeAllowed(currentAlbumID: 5, nextAlbumID: 5)
        #expect(allowed)
    }

    @Test("crossfadeAllowed is true when either album ID is nil")
    func allowedWhenAlbumNil() async {
        let scheduler = CrossfadeScheduler()
        await scheduler.setConfig(.init(durationSeconds: 4, albumGapless: true))
        #expect(await scheduler.crossfadeAllowed(currentAlbumID: nil, nextAlbumID: 1))
        #expect(await scheduler.crossfadeAllowed(currentAlbumID: 1, nextAlbumID: nil))
    }

    @Test("scheduleOutgoingFade and cancelFades restore the node to full volume")
    func scheduleAndCancel() async {
        let scheduler = CrossfadeScheduler()
        let node = await MainActor.run { AVAudioPlayerNode() }
        await scheduler.scheduleOutgoingFade(on: node, halfDuration: 0.01)
        await scheduler.cancelFades(on: node)
        let vol = await MainActor.run { node.volume }
        #expect(vol == 1.0)
    }

    @Test("scheduledIncomingFade kicks off a fade-in task")
    func scheduledIncomingFade() async {
        let scheduler = CrossfadeScheduler()
        let node = await MainActor.run { AVAudioPlayerNode() }
        await scheduler.scheduledIncomingFade(on: node, halfDuration: 0.01)
        await scheduler.cancelFades(on: node)
    }
}
