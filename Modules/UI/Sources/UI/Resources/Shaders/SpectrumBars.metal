#include <metal_stdlib>
using namespace metal;

// Mirror of the Swift `BarInstance` (same field order; 48-byte stride via the
// trailing alignment padding after `cornerRadius`).
struct BarInstance {
    float2 rectMin; // pixel space, top-left (y grows downward)
    float2 rectMax; // pixel space, bottom-right
    float4 color;   // sRGB, alpha already pre-applied on the CPU
    float cornerRadius;
};

struct VertexOut {
    float4 position [[position]];
    float2 pixelPos; // interpolated, for the SDF
    float2 center;   // per-instance, constant across the quad
    float2 halfSize;
    float radius;
    float4 color;
};

// Two triangles, six vertices, from vertex_id. Each instance is one rounded bar
// (or a flat peak marker). rectMin/rectMax come from the instance buffer; the
// vertex shader converts pixel space to NDC with the drawable size uniform.
vertex VertexOut spectrum_vertex(
    uint vid [[vertex_id]],
    uint iid [[instance_id]],
    constant BarInstance *instances [[buffer(0)]],
    constant float2 &drawableSize [[buffer(1)]]
) {
    const float2 corners[6] = {
        float2(0, 0), float2(1, 0), float2(0, 1),
        float2(1, 0), float2(1, 1), float2(0, 1)
    };
    BarInstance inst = instances[iid];
    float2 unit = corners[vid % 6];
    float2 pixel = mix(inst.rectMin, inst.rectMax, unit);
    // Pixel (y down) to NDC (y up): one flip here.
    float2 ndc = float2(pixel.x / drawableSize.x * 2.0 - 1.0, 1.0 - pixel.y / drawableSize.y * 2.0);

    VertexOut out;
    out.position = float4(ndc, 0.0, 1.0);
    out.pixelPos = pixel;
    out.center = (inst.rectMin + inst.rectMax) * 0.5;
    out.halfSize = (inst.rectMax - inst.rectMin) * 0.5;
    out.radius = inst.cornerRadius;
    out.color = inst.color;
    return out;
}

fragment float4 spectrum_fragment(VertexOut in [[stage_in]]) {
    // Full Inigo Quilez rounded-box SDF. The interior `min(max(d.x, d.y), 0)`
    // term is required: the simplified form gives distance 0 across the whole
    // interior when the radius is 0 (the peak markers), which would render them
    // at 50% coverage everywhere.
    float2 p = in.pixelPos - in.center;
    float2 d = abs(p) - in.halfSize + in.radius;
    float dist = length(max(d, 0.0)) + min(max(d.x, d.y), 0.0) - in.radius;

    // One pixel of analytic anti-aliasing, matching Core Graphics' soft edges.
    float aa = max(fwidth(dist), 1e-4);
    float coverage = 1.0 - smoothstep(-aa, aa, dist);
    // Alpha is pre-applied on the CPU; the fragment only multiplies by coverage.
    return float4(in.color.rgb, in.color.a * coverage);
}
