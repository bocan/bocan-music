#include <metal_stdlib>
using namespace metal;

// Mirror of the Swift `StarInstance` (same field order; 48-byte stride via the
// trailing `SIMD4` alignment). One instance is either a star (a capsule: a
// circle when endA == endB, a streak when they differ) or the central core glow
// (a radial-gradient disc), selected by `shape`.
struct StarInstance {
    float2 endA;  // pixel pos this frame (capsule endpoint A / glow centre)
    float2 endB;  // pixel pos previous frame (== endA for a circle)
    float4 color; // sRGB, alpha already pre-applied on the CPU
    float radius; // pixels: circle radius, half streak width, or glow radius
    float shape;  // 0 = star capsule, 1 = core-glow radial disc
    float2 pad;   // unused, keeps the 48-byte stride explicit
};

struct VertexOut {
    float4 position [[position]];
    float2 pixelPos; // interpolated, for the SDF
    float2 endA;     // per-instance, constant across the quad
    float2 endB;
    float radius;
    float shape;
    float4 color;
};

// Capsule (rounded line segment) signed distance. With endA == endB this is a
// plain circle, so a single SDF renders both the circle stars and the streak
// stars with no shader branch on a mode flag.
static float sd_capsule(float2 p, float2 a, float2 b, float r) {
    float2 pa = p - a;
    float2 ba = b - a;
    float denom = max(dot(ba, ba), 1e-6);
    float h = clamp(dot(pa, ba) / denom, 0.0, 1.0);
    return length(pa - ba * h) - r;
}

// Two triangles, six vertices, from vertex_id. Each instance computes its own
// bounding box from both endpoints plus the radius plus one pixel of AA slack,
// so a fast streak is never clipped to one endpoint's quad.
vertex VertexOut starfield_vertex(
    uint vid [[vertex_id]],
    uint iid [[instance_id]],
    constant StarInstance *instances [[buffer(0)]],
    constant float2 &drawableSize [[buffer(1)]]
) {
    const float2 corners[6] = {
        float2(0, 0), float2(1, 0), float2(0, 1),
        float2(1, 0), float2(1, 1), float2(0, 1)
    };
    StarInstance inst = instances[iid];
    // Bounding box covers both endpoints, padded by radius + 1 px for the soft
    // edge. The glow disc (a == b) collapses this to a square around the centre.
    float pad = inst.radius + 1.0;
    float2 lo = min(inst.endA, inst.endB) - pad;
    float2 hi = max(inst.endA, inst.endB) + pad;
    float2 unit = corners[vid % 6];
    float2 pixel = mix(lo, hi, unit);
    // Pixel (y down) to NDC (y up): one flip here.
    float2 ndc = float2(pixel.x / drawableSize.x * 2.0 - 1.0, 1.0 - pixel.y / drawableSize.y * 2.0);

    VertexOut out;
    out.position = float4(ndc, 0.0, 1.0);
    out.pixelPos = pixel;
    out.endA = inst.endA;
    out.endB = inst.endB;
    out.radius = inst.radius;
    out.shape = inst.shape;
    out.color = inst.color;
    return out;
}

fragment float4 starfield_fragment(VertexOut in [[stage_in]]) {
    if (in.shape > 0.5) {
        // Core glow: a soft radial disc whose alpha falls linearly to the edge,
        // matching the Canvas radial gradient (centre alpha -> clear at radius).
        float dist = length(in.pixelPos - in.endA);
        float t = clamp(1.0 - dist / max(in.radius, 1e-4), 0.0, 1.0);
        return float4(in.color.rgb, in.color.a * t);
    }
    // Star: one capsule SDF for both circles (endA == endB) and streaks.
    float dist = sd_capsule(in.pixelPos, in.endA, in.endB, in.radius);
    // One pixel of analytic anti-aliasing, matching Core Graphics' soft edges.
    float aa = max(fwidth(dist), 1e-4);
    float coverage = 1.0 - smoothstep(-aa, aa, dist);
    return float4(in.color.rgb, in.color.a * coverage);
}
