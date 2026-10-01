import AudioToolbox
import Foundation
import RenderProbe
import Testing
@testable import AudioEngine

// MARK: - RenderKernelTests

/// The crossfeed and stereo-width units run on the real-time audio thread on
/// every render cycle, switched on or not. That thread must not allocate or
/// take a lock. These tests run in the unoptimized build, which is where a
/// Swift render block breaks that rule without anyone noticing.
@Suite("DSP render kernels")
struct RenderKernelTests {
    private func expander(width: Float) throws -> StereoExpanderAudioUnit {
        let unit = try StereoExpanderAudioUnit(componentDescription: StereoExpanderAudioUnit.componentDescription)
        unit.parameterTree?.parameter(withAddress: 0)?.value = width
        return unit
    }

    private func crossfeed(amount: Float) throws -> CrossfeedAudioUnit {
        let unit = try CrossfeedAudioUnit(componentDescription: CrossfeedAudioUnit.componentDescription)
        try unit.allocateRenderResources()
        unit.parameterTree?.parameter(withAddress: 0)?.value = amount
        return unit
    }

    // MARK: Real-time safety

    @Test("The stereo-width render makes no heap allocation", arguments: [Float(1.0), 1.5])
    func expanderDoesNotAllocate(width: Float) throws {
        let allocations = try BocanCountRenderAllocations(self.expander(width: width), 512, 200)
        #expect(allocations == 0)
    }

    @Test("The crossfeed render makes no heap allocation", arguments: [Float(0.0), 0.7])
    func crossfeedDoesNotAllocate(amount: Float) throws {
        let allocations = try BocanCountRenderAllocations(self.crossfeed(amount: amount), 512, 200)
        #expect(allocations == 0)
    }

    // MARK: Stereo width

    @Test("Unity width passes the signal through unchanged")
    func unityWidthIsIdentity() throws {
        var left: [Float] = [0.5, -0.25, 1.0, 0.0]
        var right: [Float] = [0.1, 0.75, -1.0, 0.3]
        #expect(try BocanRenderInPlace(self.expander(width: 1.0), &left, &right, 4) == noErr)
        #expect(left == [0.5, -0.25, 1.0, 0.0])
        #expect(right == [0.1, 0.75, -1.0, 0.3])
    }

    @Test("Width scales the side signal and keeps the mid signal")
    func widthScalesSide() throws {
        var left: [Float] = [1.0, 0.5]
        var right: [Float] = [0.0, 0.5]
        #expect(try BocanRenderInPlace(self.expander(width: 2.0), &left, &right, 2) == noErr)
        // Frame 0: mid 0.5, side 0.5 doubled to 1.0. Frame 1 is mono, so it does not move.
        #expect(left == [1.5, 0.5])
        #expect(right == [-0.5, 0.5])
    }

    // MARK: Crossfeed

    @Test("Zero amount passes the signal through unchanged")
    func zeroAmountIsIdentity() throws {
        var left: [Float] = [1.0, 1.0, 1.0]
        var right: [Float] = [0.0, 0.0, 0.0]
        #expect(try BocanRenderInPlace(self.crossfeed(amount: 0), &left, &right, 3) == noErr)
        #expect(left == [1.0, 1.0, 1.0])
        #expect(right == [0.0, 0.0, 0.0])
    }

    @Test("Crossfeed bleeds the low-passed left channel into the right, and keeps its filter state")
    func crossfeedBleeds() throws {
        let unit = try self.crossfeed(amount: 1.0)
        let alpha = Float(exp(-2.0 * .pi * 700.0 / 44100.0))
        let level: Float = 0.333

        var left = [Float](repeating: 1.0, count: 4)
        var right = [Float](repeating: 0.0, count: 4)
        #expect(BocanRenderInPlace(unit, &left, &right, 4) == noErr)

        // The low-pass of a unit step: s[n] = alpha * s[n-1] + (1 - alpha).
        var state: Float = 0
        var expected: [Float] = []
        for _ in 0 ..< 4 {
            state = alpha * state + (1 - alpha)
            expected.append(level * state)
        }
        #expect(left == [1.0, 1.0, 1.0, 1.0])
        for (got, want) in zip(right, expected) {
            #expect(abs(got - want) < 1e-6)
        }

        // A second cycle continues from the stored filter state.
        var nextLeft: [Float] = [1.0]
        var nextRight: [Float] = [0.0]
        #expect(BocanRenderInPlace(unit, &nextLeft, &nextRight, 1) == noErr)
        state = alpha * state + (1 - alpha)
        #expect(abs(nextRight[0] - level * state) < 1e-6)
    }
}
