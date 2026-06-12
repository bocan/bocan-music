import simd

// MARK: - PolylineRibbon

/// Expands a polyline into a triangle strip of a given width, centred on the
/// line.
///
/// Metal line primitives are 1-pixel hairlines with no notion of width, so every
/// stroked path from a Canvas renderer (the oscilloscope trace, the Halo rim)
/// becomes a ribbon of two triangles per segment. Each input point yields two
/// strip vertices offset along the miter normal of its adjacent segments; the
/// miter length is clamped so a sharp corner cannot shoot a spike off-screen.
enum PolylineRibbon {
    /// Miter length is clamped to this multiple of `width` at sharp corners.
    private static let miterLimitMultiple: Float = 2

    /// Builds the strip. `closed: true` wraps the loop (every point has two
    /// adjacent segments and the first vertex pair is repeated at the end) for
    /// rings like the Halo rim; open polylines get butt ends. Fewer than two
    /// points returns empty.
    static func strip(points: [SIMD2<Float>], width: Float, closed: Bool) -> [SIMD2<Float>] {
        guard points.count >= 2 else { return [] }
        let half = width / 2
        let maxMiter = width * Self.miterLimitMultiple
        let count = points.count
        var strip = [SIMD2<Float>]()
        strip.reserveCapacity((closed ? count + 1 : count) * 2)

        for index in 0 ..< count {
            let point = points[index]
            let incoming = Self.incomingDirection(points, index: index, count: count, closed: closed)
            let outgoing = Self.outgoingDirection(points, index: index, count: count, closed: closed)
            let offset = Self.offset(incoming: incoming, outgoing: outgoing, half: half, maxMiter: maxMiter)
            strip.append(point + offset)
            strip.append(point - offset)
        }

        if closed, strip.count >= 2 {
            // Repeat the first vertex pair so the triangle strip closes the loop.
            strip.append(strip[0])
            strip.append(strip[1])
        }
        return strip
    }

    // MARK: - Private

    private static func incomingDirection(
        _ points: [SIMD2<Float>],
        index: Int,
        count: Int,
        closed: Bool
    ) -> SIMD2<Float>? {
        guard closed || index > 0 else { return nil }
        let previous = points[(index - 1 + count) % count]
        return Self.direction(points[index] - previous)
    }

    private static func outgoingDirection(
        _ points: [SIMD2<Float>],
        index: Int,
        count: Int,
        closed: Bool
    ) -> SIMD2<Float>? {
        guard closed || index < count - 1 else { return nil }
        let next = points[(index + 1) % count]
        return Self.direction(next - points[index])
    }

    /// The miter offset for a vertex from its adjacent segment directions.
    private static func offset(
        incoming: SIMD2<Float>?,
        outgoing: SIMD2<Float>?,
        half: Float,
        maxMiter: Float
    ) -> SIMD2<Float> {
        switch (incoming, outgoing) {
        case let (dirIn?, dirOut?):
            let normalIn = Self.normal(dirIn)
            let normalOut = Self.normal(dirOut)
            // Miter normal bisects the two segment normals; its length is
            // extended to keep constant stroke width, then clamped.
            guard let miter = Self.direction(normalIn + normalOut) else {
                return normalIn * half // segments double back; butt offset
            }
            let cosHalf = max(abs(simd_dot(miter, normalIn)), 0.0001)
            return miter * min(half / cosHalf, maxMiter)

        case let (dirIn?, nil):
            return Self.normal(dirIn) * half

        case let (nil, dirOut?):
            return Self.normal(dirOut) * half

        case (nil, nil):
            return SIMD2(0, half)
        }
    }

    /// Unit direction of `vector`, or `nil` when it is degenerately short.
    private static func direction(_ vector: SIMD2<Float>) -> SIMD2<Float>? {
        let length = simd_length(vector)
        return length > 1e-6 ? vector / length : nil
    }

    /// Left-hand normal of a unit direction.
    private static func normal(_ direction: SIMD2<Float>) -> SIMD2<Float> {
        SIMD2(-direction.y, direction.x)
    }
}
