import Testing
@testable import Playback

@Suite("CrossfadeScheduler")
struct CrossfadeSchedulerTests {
    @Test("default config disables crossfade")
    func defaultDisabled() async {
        let scheduler = CrossfadeScheduler()
        let enabled = await scheduler.isEnabled
        #expect(!enabled)
        let overlap = await scheduler.overlapSeconds
        #expect(overlap == 0)
    }

    @Test("setConfig updates isEnabled / overlapSeconds")
    func setConfigUpdates() async {
        let scheduler = CrossfadeScheduler()
        await scheduler.setConfig(.init(durationSeconds: 4, albumGapless: true))
        #expect(await scheduler.isEnabled)
        // The full setting: the tracks overlap for all of it, not half each.
        #expect(await scheduler.overlapSeconds == 4.0)
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
}
