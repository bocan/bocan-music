import Foundation
import Testing
@testable import UI

// MARK: - MetalHostRoutingTests

/// Source-convention checks for the host's Metal routing. The live render path
/// cannot be exercised host-less, so these assert the structural wiring: the
/// host consults the factory, honours the force-canvas escape hatch, and always
/// builds the Canvas fallback.
@Suite("Metal host routing source conventions")
struct MetalHostRoutingTests {
    private func hostSource() throws -> String {
        let url = URL(filePath: #filePath)
            .deletingLastPathComponent() // UITests/
            .deletingLastPathComponent() // Tests/
            .deletingLastPathComponent() // Modules/UI/
            .appendingPathComponent("Sources/UI/Visualizers/VisualizerHost.swift")
        return try String(contentsOf: url, encoding: .utf8)
    }

    @Test("Host consults the Metal factory before falling back to Canvas")
    func consultsFactory() throws {
        let source = try self.hostSource()
        #expect(source.contains("MetalVisualizerFactory.supports"))
        #expect(source.contains("MetalVisualizerFactory.make"))
    }

    @Test("Host honours the visualizer.forceCanvas escape hatch")
    func honoursForceCanvas() throws {
        let source = try self.hostSource()
        #expect(source.contains("visualizer.forceCanvas"))
    }

    @Test("Host always builds the Canvas renderer as a fallback")
    func buildsCanvasFallback() throws {
        let source = try self.hostSource()
        #expect(source.contains("buildCanvasRenderer"))
    }
}
