@preconcurrency import AVFoundation
import Foundation
import Testing
@testable import AudioEngine

// MARK: - Gain curves

@Suite("CrossfadeMix - equal-power gains")
struct CrossfadeMixGainTests {
    @Test("The overlap starts all outgoing and ends all incoming")
    func endpoints() {
        let start = CrossfadeMix.gains(atFrame: 0, of: 1000)
        #expect(start.outgoing == 1)
        #expect(start.incoming == 0)
        let end = CrossfadeMix.gains(atFrame: 1000, of: 1000)
        #expect(end.outgoing == 0)
        #expect(end.incoming == 1)
    }

    @Test("At the midpoint both tracks sit at -3 dB")
    func midpoint() {
        let mid = CrossfadeMix.gains(atFrame: 500, of: 1000)
        #expect(abs(mid.outgoing - 0.70710678) < 1e-4)
        #expect(abs(mid.incoming - 0.70710678) < 1e-4)
    }

    @Test("Summed power is constant on every frame of a one-second overlap")
    func constantPower() {
        let length = 44100
        for frame in 0 ... length {
            let pair = CrossfadeMix.gains(atFrame: frame, of: length)
            let power = pair.outgoing * pair.outgoing + pair.incoming * pair.incoming
            #expect(abs(power - 1) < 1e-6, "power \(power) at frame \(frame)")
        }
    }

    @Test("Outside the overlap the gains clamp, and no overlap means all incoming")
    func clamping() {
        #expect(CrossfadeMix.gains(atFrame: -5, of: 100) == (1, 0))
        #expect(CrossfadeMix.gains(atFrame: 250, of: 100) == (0, 1))
        #expect(CrossfadeMix.gains(atFrame: 0, of: 0) == (0, 1))
        #expect(CrossfadeMix.gains(atFrame: 3, of: -1) == (0, 1))
    }

    @Test("The outgoing gain only falls and the incoming gain only rises")
    func monotonic() {
        let length = 4410
        var previous = CrossfadeMix.gains(atFrame: 0, of: length)
        for frame in 1 ... length {
            let pair = CrossfadeMix.gains(atFrame: frame, of: length)
            #expect(pair.outgoing <= previous.outgoing)
            #expect(pair.incoming >= previous.incoming)
            previous = pair
        }
    }
}

// MARK: - Overlap length

@Suite("CrossfadeMix - overlap length")
struct CrossfadeMixOverlapLengthTests {
    @Test(
        "The overlap is the setting, capped at half of either track, and nil under one second",
        arguments: [
            // (setting, outgoing, incoming, expected)
            (6.0, 240.0, 200.0, 6.0 as TimeInterval?),
            (10.0, 12.0, 300.0, 6.0),
            (10.0, 300.0, 9.0, 4.5),
            (2.0, 2.0, 2.0, 1.0),
            (3.0, 1.5, 100.0, nil),
            (0.5, 240.0, 240.0, nil),
            (0.0, 240.0, 240.0, nil),
        ]
    )
    func lengthRule(setting: TimeInterval, outgoing: TimeInterval, incoming: TimeInterval, expected: TimeInterval?) {
        #expect(CrossfadeMix.overlapSeconds(setting: setting, outgoing: outgoing, incoming: incoming) == expected)
    }

    @Test("A duration that is not finite never crossfades")
    func nonFinite() {
        #expect(CrossfadeMix.overlapSeconds(setting: 6, outgoing: .nan, incoming: 200) == nil)
        #expect(CrossfadeMix.overlapSeconds(setting: 6, outgoing: 200, incoming: .infinity) == nil)
        #expect(CrossfadeMix.overlapSeconds(setting: .infinity, outgoing: 200, incoming: 200) == nil)
    }
}

// MARK: - Mixing

@Suite("CrossfadeMix - mixing buffers")
struct CrossfadeMixBufferTests {
    @Test("A constant 1.0 outgoing over a silent incoming reproduces the outgoing curve")
    func outgoingCurve() throws {
        let format = try PCMBuffers.stereo()
        let length = 1000
        let outgoing = try PCMBuffers.constant(1, frames: length, format: format)
        let incoming = try PCMBuffers.constant(0, frames: length, format: format)
        let output = try PCMBuffers.empty(capacity: length, format: format)

        try CrossfadeMix.mix(outgoing: outgoing, incoming: incoming, into: output, startFrame: 0, length: length)

        for channel in 0 ..< 2 {
            let samples = try PCMBuffers.samples(output, channel: channel)
            #expect(samples.count == length)
            for (frame, sample) in samples.enumerated() {
                #expect(sample == CrossfadeMix.gains(atFrame: frame, of: length).outgoing)
            }
        }
    }

    @Test("A silent outgoing under a constant 1.0 incoming reproduces the incoming curve")
    func incomingCurve() throws {
        let format = try PCMBuffers.stereo()
        let length = 1000
        let outgoing = try PCMBuffers.constant(0, frames: length, format: format)
        let incoming = try PCMBuffers.constant(1, frames: length, format: format)
        let output = try PCMBuffers.empty(capacity: length, format: format)

        try CrossfadeMix.mix(outgoing: outgoing, incoming: incoming, into: output, startFrame: 0, length: length)

        let samples = try PCMBuffers.samples(output, channel: 1)
        for (frame, sample) in samples.enumerated() {
            #expect(sample == CrossfadeMix.gains(atFrame: frame, of: length).incoming)
        }
    }

    @Test("Both tracks are present at once: the midpoint is the weighted sum of both")
    func bothAudible() throws {
        let format = try PCMBuffers.stereo()
        let length = 1000
        let outgoing = try PCMBuffers.constant(0.5, frames: length, format: format)
        let incoming = try PCMBuffers.constant(0.25, frames: length, format: format)
        let output = try PCMBuffers.empty(capacity: length, format: format)

        try CrossfadeMix.mix(outgoing: outgoing, incoming: incoming, into: output, startFrame: 0, length: length)

        let mid = try PCMBuffers.samples(output)[500]
        #expect(abs(mid - (0.5 + 0.25) * 0.70710678) < 1e-4)
    }

    @Test("The curve continues across buffers: startFrame selects the gains used")
    func continuesAcrossBuffers() throws {
        let format = try PCMBuffers.stereo()
        let length = 4000
        let outgoing = try PCMBuffers.constant(1, frames: 500, format: format)
        let incoming = try PCMBuffers.constant(0, frames: 500, format: format)
        let output = try PCMBuffers.empty(capacity: 500, format: format)

        try CrossfadeMix.mix(outgoing: outgoing, incoming: incoming, into: output, startFrame: 1000, length: length)

        let samples = try PCMBuffers.samples(output)
        #expect(samples[0] == CrossfadeMix.gains(atFrame: 1000, of: length).outgoing)
        #expect(samples[499] == CrossfadeMix.gains(atFrame: 1499, of: length).outgoing)
    }

    @Test("A missing outgoing buffer contributes silence")
    func nilOutgoing() throws {
        let format = try PCMBuffers.stereo()
        let length = 800
        let incoming = try PCMBuffers.constant(1, frames: 400, format: format)
        let output = try PCMBuffers.empty(capacity: 400, format: format)

        try CrossfadeMix.mix(outgoing: nil, incoming: incoming, into: output, startFrame: 200, length: length)

        let samples = try PCMBuffers.samples(output)
        for (index, sample) in samples.enumerated() {
            #expect(sample == CrossfadeMix.gains(atFrame: 200 + index, of: length).incoming)
        }
    }

    @Test("A short outgoing buffer (the outgoing track ended early) is silent past its end")
    func shortOutgoing() throws {
        let format = try PCMBuffers.stereo()
        let length = 1000
        let outgoing = try PCMBuffers.constant(1, frames: 300, format: format)
        let incoming = try PCMBuffers.constant(0, frames: 600, format: format)
        let output = try PCMBuffers.empty(capacity: 600, format: format)

        try CrossfadeMix.mix(outgoing: outgoing, incoming: incoming, into: output, startFrame: 0, length: length)

        let samples = try PCMBuffers.samples(output)
        #expect(samples.count == 600)
        #expect(samples[299] == CrossfadeMix.gains(atFrame: 299, of: length).outgoing)
        #expect(samples[300 ..< 600].allSatisfy { $0 == 0 })
    }

    @Test("After the overlap the incoming samples pass through unchanged")
    func passThroughAfterOverlap() throws {
        let format = try PCMBuffers.stereo()
        let outgoing = try PCMBuffers.constant(0.9, frames: 256, format: format)
        let incoming = try PCMBuffers.constant(0.3, frames: 256, format: format)
        let output = try PCMBuffers.empty(capacity: 256, format: format)

        try CrossfadeMix.mix(outgoing: outgoing, incoming: incoming, into: output, startFrame: 1000, length: 1000)

        let samples = try PCMBuffers.samples(output)
        #expect(samples.allSatisfy { $0 == 0.3 })
    }

    @Test("An empty incoming buffer yields an empty output")
    func emptyIncoming() throws {
        let format = try PCMBuffers.stereo()
        let incoming = try PCMBuffers.empty(capacity: 16, format: format)
        let output = try PCMBuffers.empty(capacity: 16, format: format)
        output.frameLength = 16

        try CrossfadeMix.mix(outgoing: nil, incoming: incoming, into: output, startFrame: 0, length: 100)

        #expect(output.frameLength == 0)
    }
}

// MARK: - Refused inputs

@Suite("CrossfadeMix - refused inputs")
struct CrossfadeMixRefusalTests {
    @Test("Buffers at different sample rates are refused")
    func sampleRateMismatch() throws {
        let format44 = try PCMBuffers.stereo(sampleRate: 44100)
        let format48 = try PCMBuffers.stereo(sampleRate: 48000)
        let outgoing = try PCMBuffers.constant(1, frames: 64, format: format48)
        let incoming = try PCMBuffers.constant(1, frames: 64, format: format44)
        let output = try PCMBuffers.empty(capacity: 64, format: format44)

        #expect(throws: AudioEngineError.self) {
            try CrossfadeMix.mix(outgoing: outgoing, incoming: incoming, into: output, startFrame: 0, length: 64)
        }
    }

    @Test("An output that is too small is refused")
    func outputTooSmall() throws {
        let format = try PCMBuffers.stereo()
        let incoming = try PCMBuffers.constant(1, frames: 64, format: format)
        let output = try PCMBuffers.empty(capacity: 32, format: format)

        #expect(throws: AudioEngineError.self) {
            try CrossfadeMix.mix(outgoing: nil, incoming: incoming, into: output, startFrame: 0, length: 64)
        }
    }

    @Test("An interleaved format is refused")
    func interleavedRefused() throws {
        let interleaved = try #require(AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 44100,
            channels: 2,
            interleaved: true
        ))
        let incoming = try PCMBuffers.empty(capacity: 64, format: interleaved)
        incoming.frameLength = 64
        let output = try PCMBuffers.empty(capacity: 64, format: interleaved)

        #expect(throws: AudioEngineError.self) {
            try CrossfadeMix.mix(outgoing: nil, incoming: incoming, into: output, startFrame: 0, length: 64)
        }
    }
}
