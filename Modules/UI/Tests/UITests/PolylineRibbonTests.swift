import simd
import Testing
@testable import UI

// MARK: - PolylineRibbonTests

/// Guards the polyline-to-triangle-strip expansion: vertex counts, the offset
/// geometry for a simple line, and the miter clamp at a sharp corner.
@Suite("PolylineRibbon")
struct PolylineRibbonTests {
    @Test("Fewer than two points returns empty")
    func degenerateReturnsEmpty() {
        #expect(PolylineRibbon.strip(points: [], width: 2, closed: false).isEmpty)
        #expect(PolylineRibbon.strip(points: [SIMD2(0, 0)], width: 2, closed: false).isEmpty)
    }

    @Test("A horizontal 2-point line offsets each point by +-half vertically")
    func horizontalLineOffsets() {
        let strip = PolylineRibbon.strip(points: [SIMD2(0, 0), SIMD2(1, 0)], width: 2, closed: false)
        #expect(strip.count == 4)
        // half = 1, normal is vertical, so vertices sit at y = +-1.
        #expect(self.approx(strip[0], SIMD2(0, 1)))
        #expect(self.approx(strip[1], SIMD2(0, -1)))
        #expect(self.approx(strip[2], SIMD2(1, 1)))
        #expect(self.approx(strip[3], SIMD2(1, -1)))
    }

    @Test("Open vertex count is 2 * points")
    func openVertexCount() {
        let points = [SIMD2<Float>(0, 0), SIMD2(1, 0), SIMD2(2, 1)]
        #expect(PolylineRibbon.strip(points: points, width: 2, closed: false).count == 6)
    }

    @Test("Closed vertex count is 2 * points + 2")
    func closedVertexCount() {
        let triangle = [SIMD2<Float>(0, 0), SIMD2(1, 0), SIMD2(0.5, 1)]
        #expect(PolylineRibbon.strip(points: triangle, width: 2, closed: true).count == 8)
    }

    @Test("A near-doubling-back corner clamps the miter length")
    func sharpCornerClamps() {
        let width: Float = 2
        let maxMiter = width * 2
        // The middle point turns almost 180 degrees, which would shoot an
        // unclamped miter far off-screen.
        let points = [SIMD2<Float>(0, 0), SIMD2(1, 0), SIMD2(0, 0.02)]
        let strip = PolylineRibbon.strip(points: points, width: width, closed: false)
        // Strip vertices for the middle point are indices 2 and 3.
        let offsetMagnitude = simd_length(strip[2] - points[1])
        #expect(offsetMagnitude <= maxMiter + 1e-3, "miter \(offsetMagnitude) exceeded clamp \(maxMiter)")
        // And the clamp actually engaged (a 90-degree corner would be ~1.41).
        #expect(offsetMagnitude > width, "expected the sharp corner to reach the clamp")
    }

    private func approx(_ lhs: SIMD2<Float>, _ rhs: SIMD2<Float>, tolerance: Float = 1e-5) -> Bool {
        simd_length(lhs - rhs) < tolerance
    }
}
