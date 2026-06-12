import AudioEngine
import Foundation
import Testing
@testable import UI

// MARK: - OnsetEnvelopeTests

/// Guards the shared attack/decay envelope: arming on a new onset, exponential
/// decay, frameIndex edge-detection (one fire per analysis frame), and the dt
/// clamp that protects against a pause/resume gap.
@Suite("OnsetEnvelope")
@MainActor
struct OnsetEnvelopeTests {
    private func analysis(onset: Bool, frameIndex: UInt64) -> Analysis {
        Analysis(
            bands: [Float](repeating: 0, count: 32),
            rms: 0,
            peak: 0,
            onset: onset,
            frameIndex: frameIndex
        )
    }

    @Test("An onset arms the envelope to 1.0")
    func onsetArms() {
        var envelope = OnsetEnvelope(tau: 0.3)
        envelope.update(analysis: self.analysis(onset: true, frameIndex: 1), time: 0)
        #expect(abs(envelope.value - 1.0) < 1e-9)
    }

    @Test("After one time constant the value is within 5% of 1/e")
    func decaysToOneOverE() {
        var envelope = OnsetEnvelope(tau: 0.3)
        envelope.update(analysis: self.analysis(onset: true, frameIndex: 1), time: 0)
        var frame: UInt64 = 2
        var time = 0.05
        while time <= 0.3 + 1e-9 {
            envelope.update(analysis: self.analysis(onset: false, frameIndex: frame), time: time)
            frame += 1
            time += 0.05
        }
        let expected = 1.0 / M_E
        #expect(abs(envelope.value - expected) < 0.05 * expected, "value \(envelope.value) vs \(expected)")
    }

    @Test("The same analysis frame seen three times fires once")
    func firesOncePerFrame() {
        var envelope = OnsetEnvelope(tau: 0.3)
        let frame = self.analysis(onset: true, frameIndex: 7)
        envelope.update(analysis: frame, time: 0.0)
        envelope.update(analysis: frame, time: 0.01)
        envelope.update(analysis: frame, time: 0.02)
        // Re-rendering the same frame only decays it; it never re-arms to 1.0.
        #expect(envelope.value < 1.0)
        #expect(envelope.value > 0.9) // but barely decayed over 20 ms
    }

    @Test("A new frame without an onset does not arm")
    func newFrameNoOnsetDoesNotArm() {
        var envelope = OnsetEnvelope(tau: 0.3)
        envelope.update(analysis: self.analysis(onset: false, frameIndex: 1), time: 0)
        #expect(envelope.value == 0)
    }

    @Test("Two onsets in quick succession re-arm to 1.0, never above")
    func reArmsWithoutStacking() {
        var envelope = OnsetEnvelope(tau: 0.3)
        envelope.update(analysis: self.analysis(onset: true, frameIndex: 1), time: 0.0)
        envelope.update(analysis: self.analysis(onset: true, frameIndex: 2), time: 0.1)
        #expect(abs(envelope.value - 1.0) < 1e-9)
    }

    @Test("The dt clamp keeps a large time gap from zeroing the envelope")
    func dtClampSurvivesGap() {
        var envelope = OnsetEnvelope(tau: 0.3)
        envelope.update(analysis: self.analysis(onset: true, frameIndex: 1), time: 0.0)
        // A 5 s gap clamps to 0.1 s, so the value decays by only one small step.
        envelope.update(analysis: self.analysis(onset: false, frameIndex: 2), time: 5.0)
        let expected = exp(-0.1 / 0.3)
        #expect(abs(envelope.value - expected) < 1e-6)
        #expect(envelope.value > 0.5)
    }
}
