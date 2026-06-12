import Testing
@testable import UI

// MARK: - MetalVisualizerFactoryTests

/// Guards the factory contract the host depends on: each mode reports Metal
/// support only once its renderer exists, and the throwing-initializer wrapper
/// turns a failure into a logged `nil` (Canvas fallback) rather than a crash.
@Suite("MetalVisualizerFactory")
@MainActor
struct MetalVisualizerFactoryTests {
    private enum BuildFailure: Error { case boom }

    /// Modes converted to Metal so far. Extend as each conversion phase lands.
    private static let metalModes: Set<VisualizerMode> = [.oscilloscope, .cascade, .spectrumBars]

    @Test("supports() is true exactly for the converted modes", arguments: VisualizerMode.allCases)
    func supportsMatchesConvertedModes(mode: VisualizerMode) {
        #expect(MetalVisualizerFactory.supports(mode) == Self.metalModes.contains(mode))
    }

    @Test("instantiate returns nil when the renderer initializer throws")
    func instantiateSwallowsFailure() {
        let result = MetalVisualizerFactory.instantiate(mode: .halo) {
            throw BuildFailure.boom
        }
        #expect(result == nil)
    }
}
