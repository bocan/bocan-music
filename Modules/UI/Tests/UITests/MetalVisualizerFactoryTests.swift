import Testing
@testable import UI

// MARK: - MetalVisualizerFactoryTests

/// Guards the factory contract the host depends on: no mode claims Metal support
/// in the foundations phase, and the throwing-initializer wrapper turns a failure
/// into a logged `nil` (Canvas fallback) rather than a crash.
@Suite("MetalVisualizerFactory")
@MainActor
struct MetalVisualizerFactoryTests {
    private enum BuildFailure: Error { case boom }

    @Test("No mode reports Metal support in the foundations phase", arguments: VisualizerMode.allCases)
    func noModeSupportedYet(mode: VisualizerMode) {
        #expect(MetalVisualizerFactory.supports(mode) == false)
    }

    @Test("instantiate returns nil when the renderer initializer throws")
    func instantiateSwallowsFailure() {
        let result = MetalVisualizerFactory.instantiate(mode: .halo) {
            throw BuildFailure.boom
        }
        #expect(result == nil)
    }
}
