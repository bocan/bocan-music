import Foundation
import Testing
@testable import Playback

// MARK: - Recorder (Sendable event sink for callbacks)

private actor TimerRecorder {
    var stopCount = 0
    var lastVolume: Float = 1.0

    func recordStop() {
        self.stopCount += 1
    }

    func recordVolume(_ vol: Float) {
        self.lastVolume = vol
    }
}

// MARK: - SleepTimerTests

@Suite("SleepTimer", .serialized)
struct SleepTimerTests {
    // MARK: - Helpers

    private func makeTimer(recorder: TimerRecorder) -> SleepTimer {
        SleepTimer(
            onStop: { await recorder.recordStop() },
            onSetVolume: { vol in await recorder.recordVolume(vol) }
        )
    }

    // MARK: - Preset minutes

    @Test("SleepTimerPreset.minutes returns correct values")
    func presetMinutes() {
        #expect(SleepTimerPreset.off.minutes == nil)
        #expect(SleepTimerPreset.minutes15.minutes == 15)
        #expect(SleepTimerPreset.minutes30.minutes == 30)
        #expect(SleepTimerPreset.minutes45.minutes == 45)
        #expect(SleepTimerPreset.minutes60.minutes == 60)
        #expect(SleepTimerPreset.minutes90.minutes == 90)
        #expect(SleepTimerPreset.minutes120.minutes == 120)
        #expect(SleepTimerPreset.custom(minutes: 7).minutes == 7)
    }

    @Test("SleepTimerPreset.displayName returns non-empty strings")
    func presetDisplayNames() {
        for preset in SleepTimerPreset.allCases {
            #expect(!preset.displayName.isEmpty)
        }
        #expect(SleepTimerPreset.custom(minutes: 25).displayName == "25 min")
    }

    // MARK: - Set / cancel

    @Test("Setting nil minutes clears remaining")
    func setNilCancels() async {
        let recorder = TimerRecorder()
        let timer = self.makeTimer(recorder: recorder)
        await timer.set(minutes: 30)
        let remainingBefore = await timer.remaining
        #expect(remainingBefore != nil)

        await timer.set(minutes: nil)
        let remainingAfter = await timer.remaining
        let stops = await recorder.stopCount
        #expect(remainingAfter == nil)
        #expect(stops == 0) // cancel ≠ stop
    }

    @Test("Setting 0 minutes clears remaining without stopping")
    func setZeroMinutes() async {
        let recorder = TimerRecorder()
        let timer = self.makeTimer(recorder: recorder)
        await timer.set(minutes: 0)
        let remaining = await timer.remaining
        let stops = await recorder.stopCount
        #expect(remaining == nil)
        #expect(stops == 0)
    }

    @Test("Remaining is approximately the requested duration")
    func remainingApproximation() async throws {
        let recorder = TimerRecorder()
        let timer = self.makeTimer(recorder: recorder)
        await timer.set(minutes: 10)
        let remaining = await timer.remaining
        // Allow 2 s of slack for init overhead
        #expect(remaining != nil)
        #expect(try #require(remaining) >= TimeInterval(10 * 60) - 2)
        #expect(try #require(remaining) <= TimeInterval(10 * 60))
        await timer.set(minutes: nil)
    }

    // MARK: - Fade out flag

    @Test("fadeOut flag is stored when set")
    func fadeOutStored() async {
        let recorder = TimerRecorder()
        let timer = self.makeTimer(recorder: recorder)
        await timer.set(minutes: 60, fadeOut: true)
        let fo = await timer.fadeOut
        #expect(fo == true)
        await timer.set(minutes: nil)
    }

    @Test("fadeOut is false after cancel")
    func fadeOutClearedOnCancel() async {
        let recorder = TimerRecorder()
        let timer = self.makeTimer(recorder: recorder)
        await timer.set(minutes: 60, fadeOut: true)
        await timer.set(minutes: nil)
        let fo = await timer.fadeOut
        #expect(fo == false)
    }

    // MARK: - System wake (expired timer)

    @Test("restoreIfNeeded clears persisted state when timer already expired")
    func wakeWithExpiredTimer() async {
        let key = "playback.sleepTimer.expiresAt"
        UserDefaults.standard.set(Date(timeIntervalSinceNow: -10), forKey: key)
        defer { UserDefaults.standard.removeObject(forKey: key) }

        let recorder = TimerRecorder()
        let timer = self.makeTimer(recorder: recorder)
        // restoreIfNeeded should clear persisted state (timer already expired).
        await timer.restoreIfNeeded()
        let remaining = await timer.remaining
        #expect(remaining == nil)
    }

    // MARK: - Restore

    @Test("restoreIfNeeded resumes a future timer")
    func restoreResumesTimer() async throws {
        let expiresKey = "playback.sleepTimer.expiresAt"
        let fadeKey = "playback.sleepTimer.fadeOut"
        let future = Date(timeIntervalSinceNow: 600) // 10 min from now
        UserDefaults.standard.set(future, forKey: expiresKey)
        UserDefaults.standard.set(false, forKey: fadeKey)
        defer {
            UserDefaults.standard.removeObject(forKey: expiresKey)
            UserDefaults.standard.removeObject(forKey: fadeKey)
        }

        let recorder = TimerRecorder()
        let timer = self.makeTimer(recorder: recorder)
        await timer.restoreIfNeeded()
        let remaining = await timer.remaining
        #expect(remaining != nil)
        #expect(try #require(remaining) > 0)
        // Clean up
        await timer.set(minutes: nil)
    }
}

// MARK: - SleepTimerPreset equality tests

@Suite("SleepTimerPreset.Equatable")
struct SleepTimerPresetEquatableTests {
    @Test("Same presets are equal")
    func equality() {
        #expect(SleepTimerPreset.minutes30 == .minutes30)
        #expect(SleepTimerPreset.custom(minutes: 7) == .custom(minutes: 7))
    }

    @Test("Different presets are not equal")
    func inequality() {
        #expect(SleepTimerPreset.minutes30 != .minutes60)
        #expect(SleepTimerPreset.custom(minutes: 7) != .custom(minutes: 8))
    }
}
