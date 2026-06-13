import AudioEngine
import Foundation
import Metal
import simd
import Testing
@testable import UI

// MARK: - MetalHaloTests

/// Guards the Metal halo's CPU side: it composes the tested ``Halo`` state machine
/// rather than duplicating its math (a source-convention check), the Bezier
/// sampling is correct, the membrane fan is star-shaped, the vertex budget is
/// exact and preallocated, the state machine steps once per frame, and the vertex
/// and instance structs have the documented strides. The SDF rendering is covered
/// by the snapshot suite.
@Suite("MetalHalo")
@MainActor
struct MetalHaloTests {
    private static let size = CGSize(width: 400, height: 400)

    private func analysis(rms: Float = 0.6, bands: [Float]? = nil, onset: Bool = false) -> Analysis {
        let resolved = bands ?? Self.sineBands()
        return Analysis(bands: resolved, rms: rms, peak: 0.9, onset: onset, bassEnergy: 0.5, trebleEnergy: 0.3)
    }

    private static func sineBands() -> [Float] {
        (0 ..< FFTAnalyzer.bandCount).map { sin(Float($0) / Float(FFTAnalyzer.bandCount) * .pi) * 0.85 }
    }

    // MARK: - No math duplication (source convention)

    @Test("MetalHalo composes Halo and does not redefine its breathing math")
    func noMathDuplication() throws {
        let source = try Self.metalHaloSource()
        // Composition: drives the tested tip computation through the core instance.
        #expect(source.contains("core.computeTips"), "must reuse Halo.computeTips")
        #expect(source.contains("core.updateSmoothing"), "must reuse Halo.updateSmoothing")
        #expect(source.contains("core.updateRotation"), "must reuse Halo.updateRotation")
        #expect(source.contains("core.ripplePool"), "must read Halo's ripple pool")
        // No duplicated state constants: the breathing depth and the smoothing
        // attack rates belong to Halo, referenced via `Halo.breathingDepth` etc.
        #expect(
            !source.contains("breathingDepth: CGFloat = 0.06"),
            "must not redefine the breathing depth constant"
        )
        #expect(source.contains("Halo.breathingDepth"), "must reference Halo's breathing depth")
        #expect(source.contains("Halo.maxDeltaTime"), "must reference Halo's dt clamp")
    }

    // MARK: - Bezier sampling

    @Test("Bezier endpoints: t = 0 yields p0, t = 1 yields p3")
    func bezierEndpoints() {
        let p0 = SIMD2<Float>(1, 2)
        let p1 = SIMD2<Float>(3, 7)
        let p2 = SIMD2<Float>(8, 4)
        let p3 = SIMD2<Float>(5, 9)
        let start = MetalHalo.bezier(p0, p1, p2, p3, 0)
        let end = MetalHalo.bezier(p0, p1, p2, p3, 1)
        #expect(simd_distance(start, p0) < 1e-5)
        #expect(simd_distance(end, p3) < 1e-5)
    }

    @Test("A straight-line Bezier samples points on the line")
    func bezierStraightLine() {
        // Control points evenly spaced along a line: every sample lies on it.
        let p0 = SIMD2<Float>(0, 0)
        let p3 = SIMD2<Float>(9, 12)
        let p1 = p0 + (p3 - p0) / 3
        let p2 = p0 + (p3 - p0) * 2 / 3
        for step in 0 ... 8 {
            let t = Float(step) / 8
            let point = MetalHalo.bezier(p0, p1, p2, p3, t)
            let expected = p0 + (p3 - p0) * t
            #expect(simd_distance(point, expected) < 1e-4, "t \(t)")
        }
    }

    // MARK: - Fan validity (star-shape guard)

    @Test("Every loop point sits more than 1 pt from the centre")
    func fanIsStarShaped() throws {
        let halo = try #require(self.makeRenderer())
        // All bands at 1.0 with an awkward rotation phase: the most degenerate case.
        let bands = [Float](repeating: 1, count: FFTAnalyzer.bandCount)
        halo.core.rotationPhase = 0.123_45
        for _ in 0 ..< 60 {
            halo.core.updateSmoothing(analysis: self.analysis(bands: bands))
        }
        halo.buildFrame(analysis: self.analysis(bands: bands), time: 1000, drawableSize: Self.size)
        // Fan vertex 0 is the centre; the rest are the loop and the wrap repeat.
        let center = halo.fanVertices[0].position
        for vertex in halo.fanVertices.dropFirst() {
            #expect(simd_distance(vertex.position, center) > 1, "loop point too close to centre")
        }
    }

    // MARK: - Vertex budget

    @Test("Per frame: 514 fan vertices and 512 * 2 + 2 ribbon vertices")
    func vertexBudget() throws {
        let halo = try #require(self.makeRenderer())
        halo.buildFrame(analysis: self.analysis(), time: 1000, drawableSize: Self.size)
        #expect(MetalHalo.fanVertexCount == 514)
        #expect(MetalHalo.ribbonVertexCount == 512 * 2 + 2)
        #expect(halo.fanVertices.count == MetalHalo.fanVertexCount)
        #expect(halo.ribbonVertices.count == MetalHalo.ribbonVertexCount)
        // The fan index buffer draws one triangle per loop point.
        #expect(MetalHalo.fanIndices().count == MetalHalo.loopPointCount * 3)
    }

    @Test("Repeated frames reuse the preallocated arrays (no growth)")
    func noPerFrameGrowth() throws {
        let halo = try #require(self.makeRenderer())
        for frame in 0 ..< 5 {
            halo.buildFrame(analysis: self.analysis(), time: 1000 + Double(frame), drawableSize: Self.size)
            #expect(halo.fanVertices.count == MetalHalo.fanVertexCount)
            #expect(halo.ribbonVertices.count == MetalHalo.ribbonVertexCount)
        }
    }

    // MARK: - State delegation (steps once per frame)

    @Test("60 frames leave rmsEMA equal to 60 direct updateSmoothing calls")
    func stateSteppedOncePerFrame() throws {
        let halo = try #require(self.makeRenderer())
        let reference = Halo(palette: .mono, reduceMotion: false, reduceTransparency: false)
        let fixed = self.analysis()
        for frame in 0 ..< 60 {
            halo.buildFrame(analysis: fixed, time: 1000 + Double(frame), drawableSize: Self.size)
            reference.updateSmoothing(analysis: fixed)
        }
        #expect(halo.core.rmsEMA == reference.rmsEMA)
        #expect(halo.core.smoothedBands == reference.smoothedBands)
    }

    // MARK: - Degenerate canvas

    @Test("A zero-height pane is skipped without NaNs")
    func degenerateCanvasSkipped() throws {
        let halo = try #require(self.makeRenderer())
        halo.buildFrame(analysis: self.analysis(), time: 1000, drawableSize: CGSize(width: 400, height: 0))
        #expect(halo.fanVertices.isEmpty)
        #expect(halo.ribbonVertices.isEmpty)
        #expect(halo.shapeInstances.isEmpty)
    }

    // MARK: - Strides

    @Test("HaloVertex has the documented 32-byte stride")
    func vertexStride() {
        #expect(MemoryLayout<HaloVertex>.stride == 32)
    }

    @Test("HaloShapeInstance has the documented 48-byte stride")
    func shapeInstanceStride() {
        #expect(MemoryLayout<HaloShapeInstance>.stride == 48)
    }

    // MARK: - Helpers

    private func makeRenderer(
        palette: VisualizerPalette = .mono,
        reduceMotion: Bool = false,
        reduceTransparency: Bool = false
    ) -> MetalHalo? {
        guard let device = MetalSupport.device else { return nil }
        let halo = try? MetalHalo(
            device: device,
            pixelFormat: .bgra8Unorm,
            config: MetalRendererConfig(
                palette: palette, reduceMotion: reduceMotion, reduceTransparency: reduceTransparency
            )
        )
        halo?.pixelsPerPointOverride = 1
        return halo
    }

    private static func metalHaloSource() throws -> String {
        let url = URL(filePath: #filePath)
            .deletingLastPathComponent() // UITests/
            .deletingLastPathComponent() // Tests/
            .deletingLastPathComponent() // Modules/UI/
            .appendingPathComponent("Sources/UI/Visualizers/Metal/MetalHalo.swift")
        return try String(contentsOf: url, encoding: .utf8)
    }
}
