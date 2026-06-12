import Foundation
import Testing
@testable import UI

// MARK: - FrameRateMonitorTests

/// Guards the frame-rate watchdog: it ignores the first tick and outliers, holds
/// steady at healthy frame rates, trips exactly once after a sustained slow
/// stretch, and recovers when frames speed back up.
@Suite("FrameRateMonitor")
struct FrameRateMonitorTests {
    /// Feeds frames at a fixed interval and returns how many times the monitor
    /// tripped over the run.
    private func run(monitor: inout FrameRateMonitor, interval: TimeInterval, seconds: TimeInterval) -> Int {
        var trips = 0
        var time: TimeInterval = 0
        while time <= seconds {
            if monitor.record(time: time) { trips += 1 }
            time += interval
        }
        return trips
    }

    @Test("60 fps never trips")
    func healthyNeverTrips() {
        var monitor = FrameRateMonitor()
        let trips = self.run(monitor: &monitor, interval: 1.0 / 60, seconds: 10)
        #expect(trips == 0)
        #expect(!monitor.hasTripped)
    }

    @Test("Sustained 20 fps trips exactly once after the threshold")
    func sustainedSlowTripsOnce() {
        var monitor = FrameRateMonitor()
        // 50 ms frames = 20 fps, below the 30 fps floor. Over 10 s it crosses the
        // 3 s sustained threshold once and must not re-trip.
        let trips = self.run(monitor: &monitor, interval: 0.05, seconds: 10)
        #expect(trips == 1)
        #expect(monitor.hasTripped)
    }

    @Test("The first tick never trips (no previous timestamp)")
    func firstTickIsNeutral() {
        var monitor = FrameRateMonitor()
        #expect(monitor.record(time: 0) == false)
    }

    @Test("An outlier gap resets the slow accumulator instead of tripping")
    func outlierResets() {
        var monitor = FrameRateMonitor()
        // Accumulate a little slow time, then a >1 s gap (resume from sleep).
        _ = monitor.record(time: 0)
        _ = monitor.record(time: 0.05)
        _ = monitor.record(time: 0.10)
        let trippedOnGap = monitor.record(time: 5.0) // 4.9 s gap, ignored
        #expect(trippedOnGap == false)
        #expect(!monitor.hasTripped)
    }

    @Test("Recovering to a healthy rate clears the accumulator")
    func recoveryClearsAccumulator() {
        var monitor = FrameRateMonitor()
        // ~2 s of slow frames (under the 3 s threshold), then healthy frames.
        var time: TimeInterval = 0
        while time < 2.0 {
            #expect(monitor.record(time: time) == false)
            time += 0.05
        }
        // Now 60 fps for 5 s: the earlier slow time must not carry over and trip.
        let trips = self.run(monitor: &monitor, interval: 1.0 / 60, seconds: time + 5)
        #expect(trips == 0)
    }
}
